import Darwin
import Foundation
import Observation

// Stav jedné aplikace z pohledu Runneru
enum RunStatus: Equatable {
    // Neběží
    case stopped
    // Proces běží, ale port webového rozhraní ještě neodpovídá (instalace závislostí apod.)
    case starting
    // Proces běží a port (pokud je zadaný) odpovídá
    case running
    // Byl odeslán signál k ukončení, čeká se na konec procesu
    case stopping
    // Port odpovídá, ale proces nespustil tento Runner (Terminál, předchozí běh Runneru)
    case external
    // Spuštění selhalo nebo aplikace nečekaně skončila
    case failed(String)

    // Aplikaci lze spustit jen ze stavu „neběží“
    var canStart: Bool {
        switch self {
        case .stopped, .failed: true
        default: false
        }
    }

    // Aplikace běží (nebo se rozbíhá) a lze ji zastavit
    var canStop: Bool {
        switch self {
        case .starting, .running, .external: true
        default: false
        }
    }
}

// Řízení jedné aplikace: spuštění, zastavení, restart a sledování stavu.
// Běží na hlavním vlákně, protože jeho stav přímo zobrazuje SwiftUI.
@MainActor
@Observable
final class AppRunner: Identifiable {
    let id: UUID
    private(set) var definition: AppDefinition
    private(set) var status: RunStatus = .stopped
    // PID procesu spuštěného Runnerem (zároveň PGID jeho skupiny procesů)
    private(set) var pid: pid_t?
    private(set) var startedAt: Date?
    // Poslední zjištěný stav portu webového rozhraní
    private(set) var portOpen = false
    // Log posledního běhu – zůstává i po skončení, aby šla dohledat příčina pádu
    private var activeLogURL: URL?

    // Po zastavení znovu spustit (restart)
    private var pendingRestart = false
    // Odložené SIGKILL, pokud proces nereaguje na SIGTERM
    private var killTask: Task<Void, Never>?
    // Sledování konce procesu (kqueue) – pro vlastní i převzaté procesy
    private var exitSource: DispatchSourceProcess?
    // Záznamy o spuštěných procesech pro převzetí po restartu Runneru
    private let stateStore: RunStateStore

    init(definition: AppDefinition, stateStore: RunStateStore) {
        self.id = definition.id
        self.definition = definition
        self.stateStore = stateStore
    }

    // Proces běží pod kontrolou tohoto Runneru
    var isManaged: Bool { pid != nil }

    // Soubor logu pro zobrazení v okně
    var logURL: URL { activeLogURL ?? LogFile.url(for: definition) }

    // Změna konfigurace se projeví při příštím spuštění; u neběžící aplikace
    // zahodíme odkaz na starý log (mohl se změnit název souboru)
    func updateDefinition(_ newDefinition: AppDefinition) {
        definition = newDefinition
        if pid == nil {
            activeLogURL = nil
        }
    }

    // Spustí aplikaci
    func start() {
        guard status.canStart else { return }

        // Nejdřív ověříme složku a skript, ať uživatel dostane srozumitelnou chybu
        if let problem = definition.validationError {
            status = .failed(problem)
            return
        }

        do {
            let logURL = try LogFile.prepare(for: definition)
            let newPID = try ProcessSpawner.spawn(app: definition, logURL: logURL)
            activeLogURL = logURL
            pid = newPID
            startedAt = Date()
            status = initialRunningStatus
            watchExit(pid: newPID)

            // Zapamatujeme si proces pro případné převzetí po restartu Runneru
            if let info = ProcessInspector.info(pid: newPID) {
                stateStore.set(
                    RunStateStore.Record(pid: newPID, startTime: info.startTime, logPath: logURL.path),
                    for: id
                )
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // Převezme proces spuštěný předchozím během Runneru; vrací true při úspěchu.
    // Proces musí stále běžet, mít stejný čas startu (ochrana proti znovupoužitému
    // PID) a být vedoucím své skupiny procesů, jinak se záznam zahodí.
    @discardableResult
    func adopt(_ record: RunStateStore.Record) -> Bool {
        guard pid == nil,
              let info = ProcessInspector.info(pid: record.pid),
              abs(info.startTime - record.startTime) < 0.001,
              info.pgid == record.pid else {
            stateStore.remove(id: id)
            return false
        }

        pid = record.pid
        startedAt = Date(timeIntervalSince1970: info.startTime)
        activeLogURL = URL(fileURLWithPath: record.logPath)
        status = initialRunningStatus
        watchExit(pid: record.pid)
        return true
    }

    // Bez portu nemáme jak poznat připravenost – považujeme za běžící hned
    private var initialRunningStatus: RunStatus {
        definition.port == nil ? .running : .starting
    }

    // Začne hlídat konec procesu; handler běží na hlavní frontě
    private func watchExit(pid watchedPID: pid_t) {
        exitSource = ProcessSpawner.watchExit(pid: watchedPID) { [weak self] reason in
            MainActor.assumeIsolated {
                self?.handleExit(pid: watchedPID, reason: reason)
            }
        }
    }

    // Zastaví aplikaci: SIGTERM celé skupině procesů, po timeoutu SIGKILL
    func stop(timeout: TimeInterval = AppSettings.stopTimeout) {
        if status == .external {
            stopExternal(timeout: timeout)
            return
        }
        guard let pid, status != .stopping else { return }

        status = .stopping

        // Skupina už neexistuje – konec procesu brzy ohlásí sledování konce
        guard ProcessSpawner.signalGroup(pid, SIGTERM) else { return }

        killTask?.cancel()
        killTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            // Proces mezitím mohl skončit nebo být nahrazen novým během
            guard let self, !Task.isCancelled, self.pid == pid else { return }
            ProcessSpawner.signalGroup(pid, SIGKILL)
        }
    }

    // Restart: běžící aplikaci zastaví a po jejím skončení znovu spustí
    func restart(timeout: TimeInterval = AppSettings.stopTimeout) {
        if status.canStop {
            pendingRestart = true
            stop(timeout: timeout)
        } else if status.canStart {
            start()
        }
    }

    // Promítne zjištěný stav portu do stavu aplikace
    func applyPortState(_ isOpen: Bool) {
        // Přiřazení i stejné hodnoty by u @Observable překreslilo závislé pohledy
        if portOpen != isOpen {
            portOpen = isOpen
        }
        switch status {
        case .starting where isOpen:
            // Webové rozhraní naběhlo
            status = .running
        case .stopped where isOpen && pid == nil, .failed where isOpen && pid == nil:
            // Na portu běží instance, kterou nespustil tento Runner
            status = .external
        case .external where !isOpen:
            status = .stopped
        default:
            break
        }
    }

    // Zpracování konce procesu spuštěného nebo převzatého Runnerem.
    // reason je nil u převzatého procesu – návratový kód cizího procesu systém neprozradí.
    private func handleExit(pid exitedPID: pid_t, reason: ExitReason?) {
        guard pid == exitedPID else { return }
        let wasStopRequested = status == .stopping

        pid = nil
        startedAt = nil
        portOpen = false
        killTask?.cancel()
        killTask = nil
        exitSource?.cancel()
        exitSource = nil
        stateStore.remove(id: id)

        // Konec na žádost uživatele nebo čistý konec s kódem 0 není chyba
        if wasStopRequested {
            status = .stopped
        } else {
            switch reason {
            case .exited(0):
                status = .stopped
            case .exited(let code):
                status = .failed("Aplikace skončila s kódem \(code). Podrobnosti jsou v logu.")
            case .signaled(let signal):
                status = .failed("Aplikace byla ukončena signálem \(signal).")
            case nil:
                status = .failed("Aplikace neočekávaně skončila. Podrobnosti jsou v logu.")
            }
        }

        if let logURL = activeLogURL {
            try? LogFile.append("===== Konec: \(Self.describe(reason)) =====\n", to: logURL)
        }
        startIfRestartPending()
    }

    // Dokončení restartu po zastavení (vlastní i externí instance)
    private func startIfRestartPending() {
        guard pendingRestart else { return }
        pendingRestart = false
        status = .stopped
        start()
    }

    // Zastavení instance spuštěné mimo Runner – PID dohledáme podle portu
    private func stopExternal(timeout: TimeInterval) {
        guard let port = definition.port else { return }
        status = .stopping

        Task { [weak self] in
            let pids = await Task.detached { PortProbe.listeningPIDs(port: port) }.value
            pids.forEach { kill($0, SIGTERM) }

            // Čekáme, až se port uvolní; pokud ne, přijde SIGKILL
            let deadline = Date().addingTimeInterval(timeout)
            var stillListening = true
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
                stillListening = await Task.detached { PortProbe.isListening(port: port) }.value
                if !stillListening { break }
            }
            if stillListening {
                pids.forEach { kill($0, SIGKILL) }
            }

            guard let self else { return }
            self.portOpen = false
            self.status = .stopped
            self.startIfRestartPending()
        }
    }

    // Lidsky čitelný popis důvodu ukončení pro zápis do logu
    private static func describe(_ reason: ExitReason?) -> String {
        switch reason {
        case .exited(let code): "kód \(code)"
        case .signaled(let signal): "signál \(signal)"
        case nil: "převzatá aplikace skončila"
        }
    }
}
