import Foundation

// Záznamy o procesech spuštěných Runnerem v ~/Library/Application Support/Runner/state.json.
// Díky nim lze po restartu Runneru aplikace, které zůstaly běžet, znovu převzít.
@MainActor
final class RunStateStore {
    // Záznam o jednom spuštěném procesu
    //
    // Parametry:
    // - pid: PID procesu (zároveň PGID jeho skupiny)
    // - startTime: čas startu procesu podle systému – ochrana proti znovupoužitému PID
    // - logPath: soubor, do kterého proces zapisuje výstup
    struct Record: Codable, Equatable {
        var pid: pid_t
        var startTime: TimeInterval
        var logPath: String
    }

    // Klíčem je UUID aplikace jako text (JSON neumí jiné klíče objektu)
    private(set) var records: [String: Record] = [:]
    let fileURL: URL

    // Parametr fileURL umožňuje v testech použít dočasný soubor
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultFileURL: URL {
        ConfigStore.supportDirectory.appendingPathComponent("state.json")
    }

    func record(for id: UUID) -> Record? {
        records[id.uuidString]
    }

    func set(_ record: Record, for id: UUID) {
        records[id.uuidString] = record
        save()
    }

    func remove(id: UUID) {
        guard records.removeValue(forKey: id.uuidString) != nil else { return }
        save()
    }

    // Poškozený nebo chybějící soubor znamená „nic k převzetí“
    private func load() {
        records = (try? JSONFile.read([String: Record].self, from: fileURL)) ?? [:]
    }

    // Uložení je best-effort – při chybě jen přijdeme o možnost převzetí
    private func save() {
        try? JSONFile.write(records, to: fileURL)
    }
}
