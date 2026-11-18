import Foundation

// Společné čtení a zápis konfiguračních JSON souborů Runneru
// (čitelný formát, atomický zápis, automatické vytvoření složky)
enum JSONFile {
    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
