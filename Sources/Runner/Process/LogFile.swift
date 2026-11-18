import Foundation

// Práce s logy aplikací v ~/Library/Logs/Runner.
// Aplikace zapisuje stdout/stderr přímo do souboru, okno logu čte jeho konec.
enum LogFile {
    // Při překročení této velikosti se log při dalším startu odsune do .1
    static let rotateSize: UInt64 = 5 * 1024 * 1024

    static var directory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/Runner", isDirectory: true)
    }

    // Název souboru: název aplikace bez diakritiky a zvláštních znaků + začátek id
    // (id zajistí jednoznačnost i u dvou aplikací se stejným názvem)
    static func url(for app: AppDefinition) -> URL {
        let folded = app.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let safeName = String(folded.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        let shortID = app.id.uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("\(safeName)_\(shortID).log")
    }

    // Připraví log před startem: vytvoří složku, případně zrotuje velký soubor
    // a zapíše oddělovač s časem a spouštěným příkazem
    static func prepare(for app: AppDefinition) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = url(for: app)

        // Rotace: starý .1 se zahodí, aktuální soubor se přejmenuje
        if fileSize(logURL) > rotateSize {
            let rotatedURL = logURL.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotatedURL)
            try? fileManager.moveItem(at: logURL, to: rotatedURL)
        }

        let timestamp = Date().formatted(date: .numeric, time: .standard)
        let header = "\n===== Start \(timestamp) =====\n$ cd \(app.displayPath) && \(app.script) \(app.arguments)\n"
        try append(header, to: logURL)
        return logURL
    }

    // Vytvoří složku logů, pokud ještě neexistuje
    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Připíše text na konec souboru (soubor případně vytvoří)
    static func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // Vyprázdní log; běžící aplikace zapisuje s O_APPEND, takže pokračuje od začátku
    static func clear(_ url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
    }

    static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // Přečte posledních maxBytes bajtů logu a očistí je pro zobrazení.
    // Pokud se velikost souboru od minulého čtení nezměnila, vrací text nil.
    static func readTail(
        _ url: URL,
        unlessSize previousSize: UInt64? = nil,
        maxBytes: Int = 64 * 1024
    ) -> (size: UInt64, text: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, "") }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size == previousSize {
            return (size, nil)
        }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()

        // Neplatné UTF-8 (useknutý znak na začátku) se nahradí, první neúplný řádek zahodíme
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return (size, clean(text))
    }

    // Regulární výraz pro ANSI escape sekvence (barvy, pohyb kurzoru):
    // ESC [ volitelné parametry (číslice, ;, ?) mezilehlé znaky a koncový znak @–~
    private static let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    // Odstraní ANSI sekvence a převede návraty vozíku (progress bary pipu) na nové řádky
    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let withoutANSI = ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return withoutANSI
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
