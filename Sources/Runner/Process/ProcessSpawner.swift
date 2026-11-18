import Darwin
import Foundation

// Důvod ukončení procesu (návratový kód nebo signál)
enum ExitReason: Equatable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    // Lidsky čitelný popis pro log a chybové zprávy
    var description: String {
        switch self {
        case .exited(let code): "kód \(code)"
        case .signaled(let signal): "signál \(signal)"
        }
    }
}

// Spouštění aplikací a sledování jejich konce.
//
// Aplikace běží jako samostatné launchd úlohy (viz LaunchdJob): mají vlastní
// skupinu procesů (lze je zastavit i s podřízenými procesy jedním kill(-pgid)),
// výstup jde přímo do souboru a běží nezávisle na Runneru – přežijí jeho ukončení
// i volbu Docku „Ukončit práci na pozadí“.
enum ProcessSpawner {
    // Shellový příkaz spouštěný v login shellu. Složka a skript jdou přes proměnné
    // prostředí (bez problémů s uvozovkami), parametry se vkládají tak, jak je
    // uživatel zapsal – mohou tedy obsahovat i uvozovky jako v Terminálu.
    static func shellCommand(arguments: String) -> String {
        var command = "cd \"$RUNNER_APP_DIR\" && exec \"$RUNNER_APP_SCRIPT\""
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            command += " " + trimmed
        }
        return command
    }

    // Proměnné prostředí navíc k výchozímu prostředí launchd.
    // launchd nemá PATH z Homebrew, proto ho doplníme (login shell -l pak ještě
    // načte ~/.zprofile uživatele).
    static func environment(for app: AppDefinition) -> [String: String] {
        [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "RUNNER_APP_DIR": app.expandedPath,
            "RUNNER_APP_SCRIPT": app.scriptPath,
            // Python jinak při výstupu do souboru bufferuje a log by se zobrazoval se zpožděním
            "PYTHONUNBUFFERED": "1",
        ]
    }

    // Spustí skript aplikace jako launchd úlohu, stdout i stderr jdou do logu (append).
    // Vrací PID, který je zároveň PGID.
    static func spawn(app: AppDefinition, logURL: URL) throws -> pid_t {
        try LaunchdJob.start(
            label: LaunchdJob.label(for: app.id),
            arguments: ["/bin/zsh", "-l", "-c", shellCommand(arguments: app.arguments)],
            environment: environment(for: app),
            logURL: logURL
        )
    }

    // Hlídá konec procesu přes kqueue (EVFILT_PROC/NOTE_EXIT), které funguje i pro
    // procesy, jež nejsou potomky Runneru. Po konci zjistí důvod od launchd (nil, pokud
    // proces nebyl launchd úlohou), úlohu odebere a zavolá onExit na zadané frontě.
    // Handler se zavolá právě jednou; vrácený zdroj je nutné držet.
    static func watchExit(
        pid: pid_t,
        label: String,
        queue: DispatchQueue = .main,
        onExit: @escaping (ExitReason?) -> Void
    ) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // Zrušený zdroj slouží jako příznak „už ohlášeno“; dotazy na launchd
        // trvají desítky ms, proto běží mimo hlavní frontu
        let fire = {
            guard !source.isCancelled else { return }
            source.cancel()
            DispatchQueue.global(qos: .userInitiated).async {
                let reason = LaunchdJob.waitForExitReason(label)
                LaunchdJob.remove(label)
                queue.async { onExit(reason) }
            }
        }
        source.setEventHandler(handler: fire)
        source.resume()

        // Pojistka: proces mohl skončit ještě před registrací sledování
        if ProcessInspector.info(pid: pid) == nil {
            queue.async(execute: fire)
        }
        return source
    }

    // Pošle signál celé skupině procesů; vrací false, pokud skupina už neexistuje
    @discardableResult
    static func signalGroup(_ pgid: pid_t, _ signal: Int32) -> Bool {
        kill(-pgid, signal) == 0
    }
}
