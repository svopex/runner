import AppKit
import SwiftUI

// Ikona v horní liště; při běžících aplikacích ukazuje jejich počet
struct MenuBarLabel: View {
    let manager: RunnerManager

    var body: some View {
        let count = manager.activeCount
        if count > 0 {
            Image(systemName: "play.circle.fill")
            Text("\(count)")
        } else {
            Image(systemName: "play.circle")
        }
    }
}

// Obsah menu v horní liště: podmenu pro každou aplikaci a hromadné akce
struct MenuBarContent: View {
    @Environment(RunnerManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(manager.runners) { runner in
            Menu("\(runner.status.emoji)  \(runner.definition.name)") {
                appActions(for: runner)
            }
        }

        if manager.runners.isEmpty {
            Text("Žádné aplikace")
        }

        Divider()

        Button("Spustit vše") { manager.startAll() }
        Button("Zastavit vše") { manager.stopAll() }

        Divider()

        Button("Otevřít okno Runneru…") { showMainWindow() }
        Button("Nastavení…") {
            manager.showSettings = true
            showMainWindow()
        }

        Divider()

        Button("Ukončit Runner") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // Akce dostupné pro jednu aplikaci podle jejího stavu
    @ViewBuilder
    private func appActions(for runner: AppRunner) -> some View {
        Text(runner.status.title)

        if runner.status.canStart {
            Button("Spustit") { runner.start() }
        }
        if runner.status.canStop {
            Button("Zastavit") { runner.stop() }
            Button("Restartovat") { runner.restart() }
        }
        if let url = runner.definition.webURL {
            Button("Otevřít v prohlížeči") { NSWorkspace.shared.open(url) }
                .disabled(!runner.portOpen)
        }
    }

    // Okno aplikace v horní liště se samo do popředí nedostane – aktivujeme ji
    private func showMainWindow() {
        openWindow(id: MainWindowView.windowID)
        NSApp.activate()
    }
}
