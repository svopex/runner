import SwiftUI

// Vizuální podoba stavů aplikace (text, barva, emoji pro menu v horní liště)
extension RunStatus {
    var title: String {
        switch self {
        case .stopped: "Zastaveno"
        case .starting: "Spouští se…"
        case .running: "Běží"
        case .stopping: "Zastavuje se…"
        case .external: "Běží mimo Runner"
        case .failed: "Chyba"
        }
    }

    var color: Color {
        switch self {
        case .stopped: .secondary
        case .starting, .stopping: .orange
        case .running: .green
        case .external: .blue
        case .failed: .red
        }
    }

    // NSMenu nezobrazuje barevné ikony, proto v menu používáme barevná emoji
    var emoji: String {
        switch self {
        case .stopped: "⚪️"
        case .starting, .stopping: "🟡"
        case .running: "🟢"
        case .external: "🔵"
        case .failed: "🔴"
        }
    }
}

// Barevná tečka se stavem aplikace
struct StatusDot: View {
    let status: RunStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 10, height: 10)
            .help(status.title)
    }
}

// Formátování doby běhu, např. „2 h 05 min“, „3 min 12 s“
enum UptimeFormatter {
    static func string(from interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d h %02d min", hours, minutes)
        }
        if minutes > 0 {
            return "\(minutes) min \(seconds) s"
        }
        return "\(seconds) s"
    }
}
