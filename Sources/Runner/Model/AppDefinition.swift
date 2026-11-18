import Foundation

// Definice jedné spouštěné aplikace tak, jak je uložená v apps.json.
//
// Parametry:
// - id: stabilní identifikátor (podle něj se páruje běžící proces a log)
// - name: zobrazovaný název
// - path: složka projektu, ve které se spouští skript
// - script: spouštěcí skript relativně ke složce (nebo absolutní cesta), výchozí run.sh
// - arguments: parametry předávané skriptu (zapisují se jako v shellu)
// - port: port webového rozhraní – slouží k detekci běhu a tlačítku „Otevřít“
// - autoStart: spustit aplikaci automaticky při startu Runneru
struct AppDefinition: Codable, Identifiable, Hashable {
    static let defaultScript = "run.sh"

    var id: UUID = UUID()
    var name: String
    var path: String
    var script: String = defaultScript
    var arguments: String = ""
    var port: Int?
    var autoStart: Bool = false

    // Cesta ke složce s rozvinutou vlnovkou (~ → domovský adresář)
    var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    // Cesta ke složce zkrácená vlnovkou – pro přehlednější zobrazení v UI
    var displayPath: String {
        (expandedPath as NSString).abbreviatingWithTildeInPath
    }

    // Absolutní cesta ke skriptu; absolutní hodnota v poli script se použije beze změny
    var scriptPath: String {
        let expandedScript = (script as NSString).expandingTildeInPath
        if (expandedScript as NSString).isAbsolutePath {
            return expandedScript
        }
        return (expandedPath as NSString).appendingPathComponent(expandedScript)
    }

    // Adresa webového rozhraní, pokud je zadaný port
    var webURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    // Kontrola, zda lze aplikaci spustit; vrací popis problému nebo nil
    var validationError: String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        // Složka musí existovat a být adresářem
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Složka \(displayPath) neexistuje."
        }
        // Skript musí existovat a mít právo ke spuštění (spouští se přímo, podle shebangu)
        guard fileManager.fileExists(atPath: scriptPath) else {
            return "Skript \(script) ve složce neexistuje."
        }
        guard fileManager.isExecutableFile(atPath: scriptPath) else {
            return "Skript \(script) není spustitelný (chmod +x \(script))."
        }
        return nil
    }
}

// Vlastní dekódování v extension, aby zůstal zachovaný automatický memberwise inicializátor.
// Chybějící nepovinné klíče v ručně upraveném apps.json dostanou výchozí hodnoty.
extension AppDefinition {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        script = try container.decodeIfPresent(String.self, forKey: .script) ?? Self.defaultScript
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}
