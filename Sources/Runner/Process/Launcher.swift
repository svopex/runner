import Darwin
import Foundation

// Spouštěč (launcher): trvalá launchd úloha, která do launchd načítá úlohy aplikací.
//
// Proč ho Runner potřebuje: macOS si u každé launchd úlohy pamatuje, která aplikace
// ji do launchd načetla (i přes pomocné úlohy), a když uživatel v Docku ukončí
// „práci na pozadí“ této aplikace, zastaví i všechny takto připsané úlohy. Úlohy
// proto nenačítá Runner, ale spouštěč, kterého při přihlášení načte sám launchd
// z ~/Library/LaunchAgents – nepatří tedy žádné aplikaci. Runner mu jen přes
// pojmenovanou rouru pošle cestu k plistu úlohy.
struct Launcher {
    // Co bylo potřeba udělat, aby spouštěč běžel
    enum Outcome: Equatable {
        // Běžel a nic se neměnilo
        case alreadyRunning
        // Úloha byla v launchd načtená, jen se restartoval její proces (atribuci to nemění)
        case restarted
        // Úlohu načetl volající proces – až do příštího přihlášení je připsaná jemu
        case bootstrapped
    }

    // Název launchd úlohy spouštěče
    let label: String
    // Složka se skriptem, rourou a plisty úloh (podsložka jobs)
    let directory: URL
    // Plist launchd úlohy spouštěče
    let plistURL: URL
    // Log spouštěče (chyby launchctl bootstrap)
    let logURL: URL

    // Spouštěč používaný aplikací; testy si ho nahrazují vlastním v dočasné složce
    static var current = standard

    static let standard: Launcher = {
        let label = "local.runner.launcher"
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return Launcher(
            label: label,
            directory: ConfigStore.supportDirectory,
            plistURL: library.appendingPathComponent("LaunchAgents/\(label).plist"),
            logURL: LogFile.directory.appendingPathComponent("launcher.log")
        )
    }()

    var scriptURL: URL { directory.appendingPathComponent("launcher.sh") }
    var fifoURL: URL { directory.appendingPathComponent("launcher.fifo") }
    var jobsDirectory: URL { directory.appendingPathComponent("jobs", isDirectory: true) }

    // Skript spouštěče: čte z roury cesty k plistům a načítá je do launchd.
    // Rouru otevírá pro čtení i zápis (<>), aby read po odpojení pisatele nevracel EOF.
    // Přijímá jen plisty ze své složky jobs.
    private static let script = """
    #!/bin/bash
    # Spouštěč Runneru – generovaný soubor, neupravujte (Runner ho přepisuje).
    # Načítá do launchd úlohy aplikací, aby nebyly připsané aplikaci Runner.
    DIR="$(dirname "$0")"
    FIFO="$DIR/launcher.fifo"
    DOMAIN="gui/$(id -u)"

    # Roura může po pádu zůstat, případně na jejím místě může být běžný soubor
    if [ ! -p "$FIFO" ]; then
        rm -f "$FIFO"
        mkfifo -m 600 "$FIFO"
    fi

    exec 3<>"$FIFO"
    while IFS= read -r plist <&3; do
        case "$plist" in
            "$DIR/jobs/"*.plist)
                /bin/launchctl bootstrap "$DOMAIN" "$plist" \\
                    || echo "$(date '+%F %T') bootstrap selhal: $plist" >&2
                ;;
            *)
                echo "$(date '+%F %T') odmítnut požadavek: $plist" >&2
                ;;
        esac
    done

    """

    // Spouštěč běží, pokud z roury někdo čte – tedy pokud ji lze neblokujícím
    // způsobem otevřít pro zápis (jediným čtenářem je skript spouštěče)
    var isRunning: Bool {
        guard let descriptor = openFifoForWriting() else { return false }
        close(descriptor)
        return true
    }

    // Zajistí běžící spouštěč s aktuálním skriptem.
    //
    // Načtenou úlohu jen restartuje (kickstart) – to nemění, komu ji macOS připisuje.
    // Do launchd ji načítá (bootstrap), jen když načtená není nebo se změnil její plist;
    // pak je až do příštího přihlášení připsaná volajícímu. Proto se má poprvé volat
    // z instalace (run.sh → Runner --install-launcher), ne z běžící aplikace Runner.
    @discardableResult
    func ensureRunning() throws -> Outcome {
        let changes = try install()
        if isRunning && !changes.script && !changes.plist {
            return .alreadyRunning
        }

        let isLoaded = LaunchdJob.status(label) != nil
        let outcome: Outcome
        if isLoaded && !changes.plist {
            // -k ukončí běžící proces, aby se načetl nový skript
            let result = LaunchdJob.launchctl(["kickstart", "-k", LaunchdJob.target(label)])
            guard result.status == 0 else {
                throw RunnerError(message: "Spouštěč se nepodařilo restartovat: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            outcome = .restarted
        } else {
            LaunchdJob.bootout(label)
            let result = LaunchdJob.launchctl(["bootstrap", LaunchdJob.domain, plistURL.path])
            guard result.status == 0 else {
                throw RunnerError(message: "Spouštěč se nepodařilo načíst: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            outcome = .bootstrapped
        }

        // Počkáme, až skript začne číst z roury
        guard Shell.poll(timeout: 3, { isRunning ? true : nil }) != nil else {
            throw RunnerError(message: "Spouštěč se nespustil. Podrobnosti: \(logURL.path)")
        }
        return outcome
    }

    // Pošle spouštěči požadavek na načtení plistu úlohy
    func submit(jobPlistURL: URL) throws {
        if write(line: jobPlistURL.path) {
            return
        }
        // Roura nemá čtenáře – spouštěč neběží; nastartujeme ho a zkusíme to znovu
        try ensureRunning()
        guard write(line: jobPlistURL.path) else {
            throw RunnerError(message: "Spouštěč nepřijímá požadavky. Podrobnosti: \(logURL.path)")
        }
    }

    // Zapíše skript a plist spouštěče; vrací, které soubory se změnily
    private func install() throws -> (script: Bool, plist: Bool) {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            // Bez toho launchd čeká s opakovaným startem 10 s (restart po změně skriptu, pád)
            "ThrottleInterval": 1,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        return (
            script: try Self.writeIfChanged(Data(Self.script.utf8), to: scriptURL),
            plist: try Self.writeIfChanged(plistData, to: plistURL)
        )
    }

    // Otevře rouru pro zápis bez blokování; nil, pokud neexistuje nebo nemá čtenáře
    private func openFifoForWriting() -> Int32? {
        let descriptor = open(fifoURL.path, O_WRONLY | O_NONBLOCK)
        return descriptor >= 0 ? descriptor : nil
    }

    // Zapíše řádek do roury; vrací false, pokud roura nemá čtenáře.
    // Řádek je kratší než PIPE_BUF, takže zápis je atomický.
    private func write(line: String) -> Bool {
        guard let descriptor = openFifoForWriting() else { return false }
        defer { close(descriptor) }
        let bytes = Array((line + "\n").utf8)
        return Darwin.write(descriptor, bytes, bytes.count) == bytes.count
    }

    // Zapíše soubor jen při změně obsahu; vrací true, pokud zapisoval
    private static func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
        if let existing = try? Data(contentsOf: url), existing == data {
            return false
        }
        try data.write(to: url, options: .atomic)
        return true
    }
}
