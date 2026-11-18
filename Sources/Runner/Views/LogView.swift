import AppKit
import SwiftUI

// Zobrazení konce logu vybrané aplikace; soubor se kontroluje každou sekundu
// a znovu se čte jen při změně velikosti
struct LogView: View {
    let runner: AppRunner

    @State private var text = ""
    @State private var autoScroll = true

    private let bottomID = "log-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(log je prázdný)" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: text) {
                    if autoScroll {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
        }
        // Úloha se restartuje při změně souboru logu (nový běh, přejmenování)
        .task(id: runner.logURL) {
            await pollLog(runner.logURL)
        }
    }

    private var header: some View {
        HStack {
            Text("Log – \(runner.definition.name)")
                .font(.headline)
            Spacer()
            Toggle("Posouvat na konec", isOn: $autoScroll)
                .toggleStyle(.checkbox)
            Button("Vymazat") {
                LogFile.clear(runner.logURL)
                text = ""
            }
            Button("Otevřít v Konzoli") {
                NSWorkspace.shared.open(runner.logURL)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // Smyčka sledování logu – čtení souboru probíhá mimo hlavní vlákno
    private func pollLog(_ url: URL) async {
        var lastSize: UInt64?
        text = ""
        while !Task.isCancelled {
            let previousSize = lastSize
            let result = await Task.detached { LogFile.readTail(url, unlessSize: previousSize) }.value
            lastSize = result.size
            if let newText = result.text {
                text = newText
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
