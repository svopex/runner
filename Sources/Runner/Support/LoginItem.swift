import Foundation
import ServiceManagement

// Spouštění Runneru po přihlášení do macOS přes SMAppService (macOS 13+).
// Funguje jen pro sestavenou Runner.app, ne pro binárku spuštěnou přes `swift run`.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // Uživatel musí položku povolit v Nastavení systému → Obecné → Položky při přihlášení
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
