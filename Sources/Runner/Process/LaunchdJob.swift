import Darwin
import Foundation

// Správa launchd úloh, ve kterých běží spouštěné aplikace (doména gui/<uid>).
//
// Proč launchd a ne přímý potomek Runneru: potomek dědí „coalition“ Runneru a macOS
// ji při ukončení „práce na pozadí“ Runneru v Docku ukončí celou – včetně aplikací.
// Úloha spuštěná launchd má vlastní coalition a rodičem je launchd.
//
// Úlohy do launchd nenačítá Runner, ale spouštěč (viz Launcher) – jinak by byly
// připsané Runneru a macOS by je zastavil stejně jako jeho podřízené procesy.
enum LaunchdJob {
    // Stav úlohy podle `launchctl print`
    struct Status: Equatable {
        // PID běžícího procesu, nil pokud proces neběží
        var pid: pid_t?
        // Důvod posledního ukončení, nil pokud proces ještě neskončil
        var lastExit: ExitReason?
    }

    static var domain: String { "gui/\(getuid())" }

    // Jak dlouho čekat, než spouštěč úlohu načte a launchd ji spustí
    private static let startTimeout: TimeInterval = 5

    // Jednoznačný název úlohy pro aplikaci (podle jejího id)
    static func label(for appID: UUID) -> String {
        "local.runner.app.\(appID.uuidString)"
    }

    // Plisty úloh jsou ve složce spouštěče, mimo ~/Library/LaunchAgents – při přihlášení
    // se tedy samy nenačítají
    private static func plistURL(for label: String) -> URL {
        Launcher.current.jobsDirectory.appendingPathComponent("\(label).plist")
    }

    // Spustí úlohu aplikace: zapíše plist a požádá spouštěč o jeho načtení do launchd
    // (RunAtLoad, bez KeepAlive). Vrací PID procesu; launchd ho spouští jako vedoucího
    // nové relace, takže PID = PGID.
    //
    // Parametry:
    // - label: název úlohy
    // - arguments: program a jeho argumenty
    // - environment: proměnné prostředí navíc k výchozímu prostředí launchd
    // - logURL: soubor pro stdout i stderr (launchd do něj připisuje)
    static func start(label: String, arguments: [String], environment: [String: String], logURL: URL) throws -> pid_t {
        // Případná stará (už ukončená) úloha se stejným názvem by načtení zablokovala
        remove(label)

        let jobPlistURL = plistURL(for: label)
        try FileManager.default.createDirectory(at: jobPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "EnvironmentVariables": environment,
            "StandardInPath": "/dev/null",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: jobPlistURL, options: .atomic)

        try Launcher.current.submit(jobPlistURL: jobPlistURL)

        // Počkáme, až spouštěč úlohu načte (desítky ms) a launchd ji spustí.
        // Úloha s důvodem ukončení, ale bez PID znamená, že skript okamžitě spadl.
        let started = Shell.poll(timeout: startTimeout) { () -> Status? in
            guard let current = status(label), current.pid != nil || current.lastExit != nil else { return nil }
            return current
        }
        if let pid = started?.pid {
            return pid
        }

        remove(label)
        if let reason = started?.lastExit {
            throw RunnerError(message: "Aplikace okamžitě skončila (\(reason)). Podrobnosti jsou v logu.")
        }
        throw RunnerError(message: "Spouštěč úlohu nenačetl. Podrobnosti: \(Launcher.current.logURL.path)")
    }

    // Stav úlohy, nebo nil, pokud úloha v launchd není načtená
    static func status(_ label: String) -> Status? {
        let result = launchctl(["print", target(label)])
        guard result.status == 0 else { return nil }
        return parseStatus(result.output)
    }

    // Rozbor výstupu `launchctl print`. Zajímají nás řádky první úrovně (jeden tabulátor):
    //   pid = 123
    //   last exit code = 3            (nebo „(never exited)“)
    //   last terminating signal = Terminated: 15
    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().components(separatedBy: " = ")
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "pid":
                status.pid = pid_t(value)
            case "last exit code":
                // „(never exited)“ se nepřevede na číslo a zůstane nil
                if let code = Int32(value) {
                    status.lastExit = .exited(code)
                }
            case "last terminating signal":
                // Číslo signálu je za poslední dvojtečkou, např. „Terminated: 15“
                if let number = value.split(separator: ":").last.flatMap({ Int32($0.trimmingCharacters(in: .whitespaces)) }) {
                    status.lastExit = .signaled(number)
                }
            default:
                break
            }
        }
        return status
    }

    // Počká, až launchd zaznamená konec procesu, a vrátí jeho důvod (nil, pokud úloha
    // v launchd není). kqueue ohlásí konec dřív, než launchd proces vyzvedne – proto čekáme.
    static func waitForExitReason(_ label: String, timeout: TimeInterval = 2) -> ExitReason? {
        // Vnější Optional = „ještě čekat“, vnitřní = výsledek (nil pro nenačtenou úlohu)
        let reason = Shell.poll(timeout: timeout, interval: 0.05) { () -> ExitReason?? in
            guard let current = status(label) else { return .some(nil) }
            guard current.pid == nil, let reason = current.lastExit else { return nil }
            return .some(reason)
        }
        return reason ?? nil
    }

    // Odebere úlohu z launchd a smaže její plist; běžící proces by launchd ukončil,
    // proto se volá jen po skončení procesu nebo před novým spuštěním
    static func remove(_ label: String) {
        bootout(label)
        try? FileManager.default.removeItem(at: plistURL(for: label))
    }

    // Odebere úlohu z launchd (pokud je načtená)
    static func bootout(_ label: String) {
        _ = launchctl(["bootout", target(label)])
    }

    // Označení úlohy pro launchctl, např. gui/501/local.runner.app.<id>
    static func target(_ label: String) -> String {
        "\(domain)/\(label)"
    }

    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        Shell.run("/bin/launchctl", arguments)
    }
}
