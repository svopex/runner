import Darwin
import Foundation

// Zjišťování stavu portů webových rozhraní na localhostu
enum PortProbe {
    // Zkusí se připojit na 127.0.0.1:port; na localhostu je odmítnutí okamžité,
    // takže blokující connect() nevadí (volá se mimo hlavní vlákno)
    static func isListening(port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        // connect() očekává obecný sockaddr – přetypujeme ukazatel na sockaddr_in
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(socketFD, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // PID procesů, které na portu naslouchají – pro zastavení aplikací spuštěných
    // mimo Runner (např. ručně z Terminálu nebo před restartem Runneru).
    // Používá systémový lsof: -t jen PID, -sTCP:LISTEN jen naslouchající sokety.
    static func listeningPIDs(port: Int) -> [pid_t] {
        let result = Shell.run("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"])

        // Výstup je jeden PID na řádek; vlastní proces Runneru nikdy nezabíjíme
        let ownPID = getpid()
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != ownPID }
    }
}
