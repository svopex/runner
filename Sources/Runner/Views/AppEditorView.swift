import AppKit
import SwiftUI

// Formulář pro přidání nebo úpravu aplikace
//
// Parametry:
// - request: upravovaná definice a příznak, zda jde o novou aplikaci
// - canDelete: odstranění je zakázané, dokud aplikace běží
// - onSave: uložení upravené definice
// - onDelete: požadavek na odstranění (potvrzení řeší hlavní okno)
struct AppEditorView: View {
    let request: EditorRequest
    let canDelete: Bool
    let onSave: (AppDefinition) -> Void
    let onDelete: (AppDefinition) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppDefinition
    @State private var portText: String

    init(
        request: EditorRequest,
        canDelete: Bool,
        onSave: @escaping (AppDefinition) -> Void,
        onDelete: @escaping (AppDefinition) -> Void
    ) {
        self.request = request
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: request.app)
        _portText = State(initialValue: request.app.port.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.isNew ? "Nová aplikace" : "Upravit aplikaci")
                .font(.title2.bold())

            Form {
                TextField("Název", text: $draft.name)

                HStack {
                    TextField("Složka", text: $draft.path)
                    Button("Vybrat…") { chooseFolder() }
                }

                TextField("Spouštěcí skript", text: $draft.script, prompt: Text("run.sh"))
                TextField("Parametry", text: $draft.arguments, prompt: Text("např. --port 9000"))
                TextField("Port webového rozhraní", text: $portText, prompt: Text("nepovinné, např. 8090"))
                Toggle("Spustit automaticky při startu Runneru", isOn: $draft.autoStart)
            }
            .formStyle(.grouped)

            // Blokující chyby formuláře mají přednost před varováním o složce/skriptu
            // (s varováním lze uložit, např. složka na momentálně odpojeném disku)
            if let problem = formError ?? draft.validationError {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(formError != nil ? .red : .orange)
                    .font(.callout)
            }

            HStack {
                if !request.isNew {
                    Button("Odstranit…", role: .destructive) {
                        dismiss()
                        onDelete(request.app)
                    }
                    .disabled(!canDelete)
                    .help(canDelete ? "Odstranit aplikaci ze seznamu" : "Běžící aplikaci nelze odstranit")
                }
                Spacer()
                Button("Zrušit") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Uložit") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(formError != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // Port převedený z textu; prázdný text znamená „bez portu“
    private var parsedPort: Int?? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
        return .some(port)
    }

    // Koncept s oříznutými mezerami v textových polích – podle něj se validuje i ukládá
    private var trimmedDraft: AppDefinition {
        var app = draft
        app.name = app.name.trimmingCharacters(in: .whitespaces)
        app.path = app.path.trimmingCharacters(in: .whitespaces)
        app.script = app.script.trimmingCharacters(in: .whitespaces)
        return app
    }

    // Chyby, kvůli kterým nelze uložit
    private var formError: String? {
        let app = trimmedDraft
        if app.name.isEmpty {
            return "Zadejte název aplikace."
        }
        if app.path.isEmpty {
            return "Zadejte složku aplikace."
        }
        if app.script.isEmpty {
            return "Zadejte spouštěcí skript."
        }
        if parsedPort == nil {
            return "Port musí být číslo 1–65535."
        }
        return nil
    }

    private func save() {
        guard formError == nil, let port = parsedPort else { return }
        var app = trimmedDraft
        app.port = port
        onSave(app)
        dismiss()
    }

    // Výběr složky dialogem; prázdný název se doplní podle názvu složky
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Vybrat"
        if !draft.path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.expandedPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        draft.path = url.path
        if trimmedDraft.name.isEmpty {
            draft.name = url.lastPathComponent
        }
    }
}
