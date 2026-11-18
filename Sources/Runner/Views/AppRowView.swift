import AppKit
import SwiftUI

// Řádek seznamu: stav, název, cesta, doba běhu a ovládací tlačítka
struct AppRowView: View {
    let runner: AppRunner
    let onEdit: () -> Void

    @Environment(RunnerManager.self) private var manager

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: runner.status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(runner.definition.name)
                        .font(.headline)
                    if runner.definition.autoStart {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .help("Spouští se automaticky se startem Runneru")
                    }
                }
                Text(runner.definition.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Popis chyby přímo v řádku, aby ji uživatel nemusel hledat
                if case .failed(let message) = runner.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            statusDetails
            controls
        }
        .padding(.vertical, 4)
    }

    // Stav, port, PID a doba běhu
    private var statusDetails: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(runner.status.title)
                .font(.callout)
                .foregroundStyle(runner.status.color)

            HStack(spacing: 8) {
                if let port = runner.definition.port {
                    Text(":\(String(port))")
                }
                if let pid = runner.pid {
                    Text("PID \(String(pid))")
                }
                // Doba běhu se překresluje každou sekundu
                if let startedAt = runner.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(UptimeFormatter.string(from: context.date.timeIntervalSince(startedAt)))
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // Tlačítka: start/stop, restart, otevřít v prohlížeči, upravit
    private var controls: some View {
        HStack(spacing: 4) {
            if runner.status == .stopping {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28)
            } else if runner.status.canStop {
                iconButton("stop.fill", help: "Zastavit") { runner.stop() }
            } else {
                iconButton("play.fill", help: "Spustit") { runner.start() }
            }

            iconButton("arrow.clockwise", help: "Restartovat") { runner.restart() }
                .disabled(!runner.status.canStop)

            iconButton("safari", help: "Otevřít webové rozhraní v prohlížeči") {
                if let url = runner.definition.webURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(runner.definition.webURL == nil || !runner.portOpen)

            iconButton("pencil", help: "Upravit nastavení aplikace", action: onEdit)
        }
        // Bez borderless stylu by tlačítka v řádku List kolidovala s výběrem řádku
        .buttonStyle(.borderless)
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 22)
        }
        .help(help)
    }
}
