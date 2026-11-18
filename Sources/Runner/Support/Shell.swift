import Foundation

// Chyba se srozumitelnou zprávou pro uživatele
struct RunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Pomocné funkce pro práci s externími nástroji a čekání na stav
enum Shell {
    // Spustí nástroj a vrátí návratový kód a spojený výstup (stdout i stderr)
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // Opakovaně volá body, dokud nevrátí hodnotu nebo nevyprší timeout (blokuje vlákno)
    static func poll<Value>(timeout: TimeInterval, interval: TimeInterval = 0.02, _ body: () -> Value?) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = body() {
                return value
            }
            if Date() >= deadline {
                return nil
            }
            usleep(useconds_t(interval * 1_000_000))
        }
    }
}
