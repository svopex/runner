import Foundation
import Observation

// Úložiště seznamu aplikací v ~/Library/Application Support/Runner/apps.json.
// Každá změna se okamžitě zapisuje na disk; soubor lze upravovat i ručně
// a pak ho v nastavení znovu načíst.
@MainActor
@Observable
final class ConfigStore {
    // Obálka souboru – umožní později přidat další položky bez rozbití formátu
    private struct ConfigFile: Codable {
        var apps: [AppDefinition]
    }

    private(set) var apps: [AppDefinition] = []
    // Poslední chyba načtení nebo uložení, zobrazuje se v hlavním okně
    private(set) var lastError: String?
    let fileURL: URL

    // Parametr fileURL umožňuje v testech použít dočasný soubor
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Runner", isDirectory: true)
            .appendingPathComponent("apps.json")
    }

    // Načte konfiguraci ze souboru
    func load() {
        // Při prvním spuštění soubor neexistuje – založíme ho s výchozími aplikacemi
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            apps = Self.defaultApps()
            lastError = nil
            save()
            return
        }

        do {
            apps = Self.withUniqueIDs(try JSONFile.read(ConfigFile.self, from: fileURL).apps)
            lastError = nil
        } catch {
            // Poškozený soubor odložíme stranou, aby ho další uložení nepřepsalo
            // a uživatel mohl obsah ručně zachránit
            let backupURL = fileURL.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            apps = []
            lastError = "Konfiguraci nelze načíst (\(error)). Původní soubor je zálohován jako \(backupURL.lastPathComponent)."
        }
    }

    // Zapíše aktuální seznam aplikací na disk (atomicky)
    func save() {
        do {
            try JSONFile.write(ConfigFile(apps: apps), to: fileURL)
            lastError = nil
        } catch {
            lastError = "Konfiguraci nelze uložit: \(error.localizedDescription)"
        }
    }

    func add(_ app: AppDefinition) {
        apps.append(app)
        save()
    }

    // Nahradí existující definici se stejným id
    func update(_ app: AppDefinition) {
        guard let index = apps.firstIndex(where: { $0.id == app.id }) else { return }
        apps[index] = app
        save()
    }

    func remove(id: UUID) {
        apps.removeAll { $0.id == id }
        save()
    }

    // Přeřazení aplikací (drag & drop v seznamu)
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        apps.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // Ručně upravený soubor může obsahovat duplicitní id – duplikáty dostanou nové
    private static func withUniqueIDs(_ apps: [AppDefinition]) -> [AppDefinition] {
        var seen = Set<UUID>()
        return apps.map { app in
            var copy = app
            if seen.contains(copy.id) {
                copy.id = UUID()
            }
            seen.insert(copy.id)
            return copy
        }
    }

    // Výchozí aplikace ze zadání projektu (cesty relativně k domovskému adresáři)
    static func defaultApps() -> [AppDefinition] {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("GitLab/soukrome")
        let seeds: [(name: String, folder: String, port: Int)] = [
            ("AI Robot Watchlist", "ai-robot-watchlist", 8092),
            ("AI Robot Watchlist Forex", "ai-robot-watchlist-forex", 8094),
            ("TickView", "TickView", 8095),
            ("TWS opce", "TWS-opce", 8090),
            ("TWS opce ručně", "TWS-opce-rucne", 8091),
        ]
        return seeds.map { seed in
            AppDefinition(
                name: seed.name,
                path: (base as NSString).appendingPathComponent(seed.folder),
                port: seed.port
            )
        }
    }
}
