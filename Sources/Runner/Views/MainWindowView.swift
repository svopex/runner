import AppKit
import SwiftUI

// Požadavek na otevření editoru aplikace (nová nebo existující)
struct EditorRequest: Identifiable {
    let id = UUID()
    let app: AppDefinition
    let isNew: Bool
}

// Hlavní okno: nahoře seznam aplikací s ovládáním, dole log vybrané aplikace
struct MainWindowView: View {
    static let windowID = "main"

    @Environment(RunnerManager.self) private var manager
    @State private var selection: UUID?
    @State private var editorRequest: EditorRequest?
    @State private var deleteCandidate: AppDefinition?

    var body: some View {
        @Bindable var bindableManager = manager

        VStack(spacing: 0) {
            // Chyba načtení/uložení konfigurace
            if let error = manager.config.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red)
            }

            // Upozornění, že spouštěč neběží v plně nezávislém režimu
            if let notice = manager.launcherNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.25))
            }

            VSplitView {
                appList
                    .frame(minHeight: 180)
                logPane
                    .frame(minHeight: 140)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { toolbarContent }
        .sheet(item: $editorRequest) { request in
            AppEditorView(
                request: request,
                canDelete: !(manager.runner(for: request.app.id)?.isManaged ?? false),
                onSave: { app in save(app, isNew: request.isNew) },
                onDelete: { app in deleteCandidate = app }
            )
        }
        .sheet(isPresented: $bindableManager.showSettings) {
            SettingsView()
                .environment(manager)
        }
        .confirmationDialog(
            "Odstranit aplikaci „\(deleteCandidate?.name ?? "")“?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Odstranit", role: .destructive) {
                if let app = deleteCandidate {
                    manager.removeApp(id: app.id)
                    if selection == app.id { selection = nil }
                }
                deleteCandidate = nil
            }
        } message: {
            Text("Aplikace zmizí jen ze seznamu Runneru, její soubory zůstanou beze změny.")
        }
        // Při otevřeném okně se Runner chová jako běžná aplikace (Dock, Cmd+Tab),
        // po zavření okna zůstane jen ikona v horní liště
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Seznam aplikací s možností přeřazení tažením
    @ViewBuilder
    private var appList: some View {
        if manager.runners.isEmpty {
            ContentUnavailableView {
                Label("Žádné aplikace", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("Přidejte aplikaci tlačítkem + v nástrojové liště.")
            }
        } else {
            List(selection: $selection) {
                ForEach(manager.runners) { runner in
                    AppRowView(runner: runner, onEdit: { edit(runner) })
                        .tag(runner.id)
                        .contextMenu { contextMenu(for: runner) }
                }
                .onMove { source, destination in
                    manager.moveApps(fromOffsets: source, toOffset: destination)
                }
            }
        }
    }

    // Log vybrané aplikace nebo nápověda
    @ViewBuilder
    private var logPane: some View {
        if let runner = manager.runner(for: selection) {
            LogView(runner: runner)
                .id(runner.id)
        } else {
            Text("Vyberte aplikaci pro zobrazení jejího logu.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                manager.startAll()
            } label: {
                Label("Spustit vše", systemImage: "play.fill")
            }
            .help("Spustit všechny zastavené aplikace")

            Button {
                manager.stopAll()
            } label: {
                Label("Zastavit vše", systemImage: "stop.fill")
            }
            .help("Zastavit všechny běžící aplikace")

            Button {
                manager.restartAll()
            } label: {
                Label("Restartovat vše", systemImage: "arrow.clockwise")
            }
            .help("Restartovat všechny běžící aplikace")

            Button {
                editorRequest = EditorRequest(app: AppDefinition(name: "", path: ""), isNew: true)
            } label: {
                Label("Přidat aplikaci", systemImage: "plus")
            }
            .help("Přidat aplikaci")

            Button {
                manager.showSettings = true
            } label: {
                Label("Nastavení", systemImage: "gearshape")
            }
            .help("Nastavení Runneru")
        }
    }

    // Kontextové menu řádku
    @ViewBuilder
    private func contextMenu(for runner: AppRunner) -> some View {
        Button("Upravit…") { edit(runner) }
        Button("Zobrazit složku ve Finderu") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runner.definition.expandedPath)])
        }
        Button("Otevřít log v Konzoli") {
            NSWorkspace.shared.open(runner.logURL)
        }
        Divider()
        Button("Odstranit…", role: .destructive) {
            deleteCandidate = runner.definition
        }
        .disabled(runner.isManaged)
    }

    private func edit(_ runner: AppRunner) {
        editorRequest = EditorRequest(app: runner.definition, isNew: false)
    }

    // Uložení z editoru; nově přidanou aplikaci rovnou vybereme
    private func save(_ app: AppDefinition, isNew: Bool) {
        if isNew {
            manager.addApp(app)
            selection = app.id
        } else {
            manager.updateApp(app)
        }
    }
}
