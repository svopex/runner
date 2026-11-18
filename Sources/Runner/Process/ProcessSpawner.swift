import Darwin
import Foundation

// Důvod ukončení procesu dekódovaný ze stavu vráceného waitpid()
enum ExitReason: Equatable {
    case exited(Int32)
    case signaled(Int32)

    // Makra WIFEXITED/WEXITSTATUS nejsou ve Swiftu dostupná – dekódujeme ručně:
    // dolních 7 bitů je číslo signálu (0 = normální konec), bity 8–15 návratový kód
    init(rawStatus: Int32) {
        let signal = rawStatus & 0x7f
        if signal == 0 {
            self = .exited((rawStatus >> 8) & 0xff)
        } else {
            self = .signaled(signal)
        }
    }
}

// Spouštění aplikací přes posix_spawn.
//
// Proč ne Foundation.Process: potřebujeme, aby každá aplikace běžela ve vlastní
// skupině procesů (lze pak zastavit i podřízené procesy jedním kill(-pgid))
// a aby výstup šel přímo do souboru – aplikace tak může běžet dál i po ukončení
// Runneru, aniž by spadla na zavřené rouře.
enum ProcessSpawner {
    struct SpawnError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

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

    // Prostředí pro spouštěnou aplikaci.
    // Aplikace spuštěná z Finderu nemá PATH z Homebrew, proto ho doplníme
    // (login shell -l pak ještě načte ~/.zprofile uživatele).
    static func environment(for app: AppDefinition) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", currentPath].joined(separator: ":")
        env["RUNNER_APP_DIR"] = app.expandedPath
        env["RUNNER_APP_SCRIPT"] = app.scriptPath
        // Python jinak při výstupu do souboru bufferuje a log by se zobrazoval se zpožděním
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    // Neveřejná funkce libSystem responsibility_spawnattrs_setdisclaim (používají ji
    // Terminál, iTerm, VS Code): spuštěný proces se zřekne odpovědnosti rodiče.
    // Načítáme ji dynamicky – pokud v systému chybí, aplikace se spustí i bez ní.
    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaimResponsibility = systemSymbol("responsibility_spawnattrs_setdisclaim", as: DisclaimFunction.self)

    // Najde funkci v načtených systémových knihovnách a přetypuje ji na zadaný typ.
    // RTLD_DEFAULT (hledání ve všech knihovnách) Swift neimportuje – na Darwinu je to (void *)-2.
    static func systemSymbol<Function>(_ name: String, as type: Function.Type) -> Function? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    // Spustí skript aplikace ve vlastní skupině procesů, stdout i stderr přesměruje
    // do logu (append), stdin na /dev/null. Vrací PID, který je zároveň PGID.
    static func spawn(app: AppDefinition, logURL: URL) throws -> pid_t {
        let argv = ["/bin/zsh", "-l", "-c", shellCommand(arguments: app.arguments)]
        let env = environment(for: app)

        // Přesměrování deskriptorů: 0 ← /dev/null, 1 → log, 2 → kopie 1
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        // Atributy: nová skupina procesů (pgid = pid), zavřít všechny ostatní
        // zděděné deskriptory, výchozí obsluha signálů a prázdná maska signálů
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] {
            sigaddset(&defaultSignals, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        // Aplikace bude „odpovědným procesem“ sama za sebe. Jinak by ji macOS
        // připisoval Runneru a vynucené ukončení Runneru (Dock, Vynutit ukončení,
        // Monitor aktivity) by ukončilo i ji.
        _ = disclaimResponsibility?(&attributes, 1)

        // Převod argumentů a prostředí na pole C řetězců zakončená NULL
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArguments.append(nil)
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnvironment.append(nil)
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, argv[0], &fileActions, &attributes, cArguments, cEnvironment)
        guard result == 0 else {
            throw SpawnError(message: "Spuštění selhalo: \(String(cString: strerror(result)))")
        }
        return pid
    }

    // Hlídá konec procesu přes kqueue (EVFILT_PROC/NOTE_EXIT), které funguje pro
    // vlastní potomky i pro převzaté procesy. Po konci se zavolá waitpid: u potomka
    // vrátí důvod ukončení a uklidí zombie, u cizího procesu selže (ECHILD) → nil.
    // Handler se zavolá právě jednou na zadané frontě; vrácený zdroj je nutné držet.
    static func watchExit(
        pid: pid_t,
        queue: DispatchQueue = .main,
        onExit: @escaping (ExitReason?) -> Void
    ) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        // Zrušený zdroj slouží jako příznak „už ohlášeno“
        let fire = {
            guard !source.isCancelled else { return }
            source.cancel()
            onExit(reap(pid))
        }
        source.setEventHandler(handler: fire)
        source.resume()

        // Pojistka: proces mohl skončit ještě před registrací sledování
        if ProcessInspector.info(pid: pid) == nil {
            queue.async(execute: fire)
        }
        return source
    }

    // Vyzvedne stav ukončeného potomka; proces už skončil, takže waitpid neblokuje.
    // Pro proces, který není potomkem Runneru, vrací nil.
    private static func reap(_ pid: pid_t) -> ExitReason? {
        var status: Int32 = 0
        var result: pid_t
        // waitpid může být přerušen signálem – v tom případě to zkusíme znovu
        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR
        return result == pid ? ExitReason(rawStatus: status) : nil
    }

    // Pošle signál celé skupině procesů; vrací false, pokud skupina už neexistuje
    @discardableResult
    static func signalGroup(_ pgid: pid_t, _ signal: Int32) -> Bool {
        kill(-pgid, signal) == 0
    }
}
