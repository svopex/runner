import Foundation

// Klíče uživatelského nastavení v UserDefaults
enum SettingsKey {
    // Kolik sekund čekat po SIGTERM, než se pošle SIGKILL
    static let stopTimeout = "stopTimeout"
    // Chování při ukončení Runneru, hodnota QuitBehavior.rawValue
    static let quitBehavior = "quitBehavior"
    // Zda už proběhlo první automatické zapnutí spouštění po přihlášení
    static let loginItemConfigured = "loginItemConfigured"
}

// Co udělat s běžícími aplikacemi při ukončení Runneru
enum QuitBehavior: String, CaseIterable, Identifiable {
    case ask
    case stop
    case leave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Zeptat se"
        case .stop: "Zastavit aplikace"
        case .leave: "Nechat aplikace běžet"
        }
    }
}

// Pohodlný přístup k nastavení; při chybějící hodnotě vrací výchozí
enum AppSettings {
    static let defaultStopTimeout: TimeInterval = 5

    static var stopTimeout: TimeInterval {
        let value = UserDefaults.standard.double(forKey: SettingsKey.stopTimeout)
        return value > 0 ? value : defaultStopTimeout
    }

    static var quitBehavior: QuitBehavior {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.quitBehavior) ?? ""
        return QuitBehavior(rawValue: raw) ?? .ask
    }
}
