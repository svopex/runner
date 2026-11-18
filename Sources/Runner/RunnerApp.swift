import AppKit
import SwiftUI

// Vstupní bod aplikace: hlavní okno se seznamem aplikací a ikona v horní liště
@main
struct RunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Runner", id: MainWindowView.windowID) {
            MainWindowView()
                .environment(appDelegate.manager)
        }
        .defaultSize(width: 860, height: 600)

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.manager)
        } label: {
            MenuBarLabel(manager: appDelegate.manager)
        }
    }
}

// Delegát aplikace: vlastní správce aplikací, řeší start a ukončení Runneru
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: RunnerManager

    override init() {
        manager = RunnerManager(
            config: ConfigStore(fileURL: ConfigStore.defaultFileURL),
            stateStore: RunStateStore(fileURL: RunStateStore.defaultFileURL)
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager.startMonitoring()
        Task { await manager.launchAutoStartApps() }

        configureLoginItemOnFirstLaunch()

        // Po spuštění při přihlášení nechceme otevírat okno – stačí ikona v horní liště
        if launchedAsLoginItem() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.windows
                    .filter { $0.identifier?.rawValue.hasPrefix(MainWindowView.windowID) == true }
                    .forEach { $0.close() }
            }
        }
    }

    // Zavřením okna aplikace nekončí – dál běží v horní liště
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Před ukončením Runneru rozhodneme, co s aplikacemi, které spustil
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runningCount = manager.managedCount
        guard runningCount > 0 else { return .terminateNow }

        var behavior = AppSettings.quitBehavior
        if behavior == .ask {
            switch askAboutRunningApps(count: runningCount) {
            case .alertFirstButtonReturn: behavior = .stop
            case .alertSecondButtonReturn: behavior = .leave
            default: return .terminateCancel
            }
        }

        if behavior == .leave {
            return .terminateNow
        }

        // Zastavení probíhá asynchronně, ukončení potvrdíme až po něm
        Task {
            await manager.stopManagedAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Dotaz na zastavení běžících aplikací; vrací stisknuté tlačítko
    private func askAboutRunningApps(count: Int) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Runner spustil aplikace, které stále běží (\(count))."
        alert.informativeText = "Chcete je před ukončením Runneru zastavit? Aplikace ponechané v běhu Runner po dalším spuštění znovu převezme."
        alert.addButton(withTitle: "Zastavit a ukončit")
        alert.addButton(withTitle: "Nechat běžet")
        alert.addButton(withTitle: "Zrušit")
        NSApp.activate()
        return alert.runModal()
    }

    // Při prvním spuštění sestavené Runner.app zapne spouštění po přihlášení
    // (dál už rozhoduje přepínač v nastavení)
    private func configureLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard LoginItem.isAvailable, !defaults.bool(forKey: SettingsKey.loginItemConfigured) else { return }
        try? LoginItem.setEnabled(true)
        defaults.set(true, forKey: SettingsKey.loginItemConfigured)
    }

    // macOS předá při spuštění položky po přihlášení v události „open application“
    // příznak keyAELaunchedAsLogInItem
    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
