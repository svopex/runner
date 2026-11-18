import AppKit
import SwiftUI

// Vstupní bod programu. Kromě běžného startu aplikace umí režim --install-launcher,
// který jen zajistí běžící spouštěč (nainstaluje ho a načte do launchd) a skončí. Volá ho run.sh z Terminálu:
// spouštěč tak není připsaný aplikaci Runner (viz Launcher).
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--install-launcher") {
            do {
                let outcome = try Launcher.current.ensureRunning()
                print("Spouštěč \(Launcher.current.label): \(outcome)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Spouštěč se nepodařilo načíst: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        RunnerApp.main()
    }
}

// Aplikace: hlavní okno se seznamem aplikací a ikona v horní liště
struct RunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Runner", id: MainWindowView.windowID) {
            MainWindowView()
                .environment(appDelegate.manager)
                .capturingOpenWindow { appDelegate.openWindowAction = $0 }
        }
        .defaultSize(width: 860, height: 600)

        MenuBarExtra {
            MenuBarContent(showMainWindow: appDelegate.showMainWindow)
                .environment(appDelegate.manager)
        } label: {
            MenuBarLabel(manager: appDelegate.manager)
                .capturingOpenWindow { appDelegate.openWindowAction = $0 }
        }
    }
}

// Delegát aplikace: vlastní správce aplikací, řeší start a ukončení Runneru
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: RunnerManager

    // Akce SwiftUI pro otevření okna; delegát ji z prostředí sám nezíská, proto ji
    // zachytí ikona v horní liště (je vidět vždy) a hlavní okno
    var openWindowAction: OpenWindowAction?

    override init() {
        manager = RunnerManager(
            config: ConfigStore(fileURL: ConfigStore.defaultFileURL),
            stateStore: RunStateStore(fileURL: RunStateStore.defaultFileURL)
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pojistka pro případ, že spouštěč neběží (instalace bez run.sh, ruční odebrání).
        // Načte-li ho Runner sám, jsou úlohy do příštího přihlášení připsané Runneru.
        do {
            if try Launcher.current.ensureRunning() == .bootstrapped {
                manager.launcherNotice = "Spouštěč načetl Runner sám. Do příštího přihlášení aplikace zastaví ukončení práce Runneru na pozadí v Docku – spusťte ./run.sh nebo se odhlaste a přihlaste."
            }
        } catch {
            manager.launcherNotice = "Spouštěč se nepodařilo spustit: \(error.localizedDescription)"
        }

        manager.startMonitoring()
        Task { await manager.launchAutoStartApps() }

        configureLoginItemOnFirstLaunch()

        // Po spuštění při přihlášení nechceme otevírat okno – stačí ikona v horní liště
        if launchedAsLoginItem() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.mainWindows.forEach { $0.close() }
            }
        }
    }

    // Zavřením okna aplikace nekončí – dál běží v horní liště
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Kliknutí na ikonu v Docku (nebo nové spuštění z Finderu) u běžícího Runneru
    // otevře hlavní okno. Vlastní obsluha je nutná, protože SwiftUI okno scény Window
    // samo znovu neotevře; vracíme false, aby AppKit už nic dalšího nedělal.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    // Zobrazí hlavní okno a aktivuje Runner; jediná cesta pro menu v horní liště i Dock.
    // Bez zachycené akce openWindow aspoň vrátí do popředí existující okno.
    func showMainWindow() {
        if let openWindowAction {
            openWindowAction(id: MainWindowView.windowID)
        } else {
            mainWindows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    // Okna scény hlavního okna (SwiftUI jim dává identifikátor začínající ID scény)
    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(MainWindowView.windowID) == true }
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

// Předá akci openWindow z prostředí SwiftUI ven (do delegáta aplikace)
private struct OpenWindowCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let store: (OpenWindowAction) -> Void

    func body(content: Content) -> some View {
        content.onAppear { store(openWindow) }
    }
}

extension View {
    // Zachytí akci openWindow při zobrazení pohledu
    func capturingOpenWindow(_ store: @escaping (OpenWindowAction) -> Void) -> some View {
        modifier(OpenWindowCapture(store: store))
    }
}
