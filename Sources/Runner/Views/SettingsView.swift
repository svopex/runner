import AppKit
import SwiftUI

// Nastavení Runneru (zobrazuje se jako list v hlavním okně)
struct SettingsView: View {
    @Environment(RunnerManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.stopTimeout) private var stopTimeout = AppSettings.defaultStopTimeout
    @AppStorage(SettingsKey.quitBehavior) private var quitBehavior = QuitBehavior.ask

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nastavení")
                .font(.title2.bold())

            Form {
                Section("Obecné") {
                    Toggle("Spouštět Runner po přihlášení", isOn: $launchAtLogin)
                        .disabled(!LoginItem.isAvailable)
                        .onChange(of: launchAtLogin) { _, enabled in
                            applyLoginItem(enabled)
                        }
                    if !LoginItem.isAvailable {
                        Text("Dostupné jen pro sestavenou Runner.app (./run.sh).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if LoginItem.requiresApproval {
                        Text("Povolte Runner v Nastavení systému → Obecné → Položky při přihlášení.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Picker("Při ukončení Runneru", selection: $quitBehavior) {
                        ForEach(QuitBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }

                    Stepper(value: $stopTimeout, in: 1...60, step: 1) {
                        Text("Čekat na ukončení aplikace: \(Int(stopTimeout)) s")
                    }
                    .help("Po této době se aplikaci, která nereaguje na SIGTERM, pošle SIGKILL")
                }

                Section("Soubory") {
                    LabeledContent("Konfigurace aplikací") {
                        Button("Zobrazit ve Finderu") {
                            NSWorkspace.shared.activateFileViewerSelecting([manager.config.fileURL])
                        }
                    }
                    LabeledContent("Logy aplikací") {
                        Button("Zobrazit ve Finderu") {
                            LogFile.ensureDirectory()
                            NSWorkspace.shared.open(LogFile.directory)
                        }
                    }
                    LabeledContent("Po ruční úpravě apps.json") {
                        Button("Znovu načíst konfiguraci") {
                            manager.reloadConfig()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Hotovo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // Zapne/vypne položku při přihlášení; při chybě vrátí přepínač zpět
    private func applyLoginItem(_ enabled: Bool) {
        guard enabled != LoginItem.isEnabled else { return }
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Nastavení se nepodařilo: \(error.localizedDescription)"
            launchAtLogin = LoginItem.isEnabled
        }
    }
}
