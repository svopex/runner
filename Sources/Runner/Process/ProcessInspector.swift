import Darwin
import Foundation

// Informace o běžícím procesu ze systému (sysctl KERN_PROC_PID).
// Slouží k bezpečnému převzetí aplikace po restartu Runneru: kromě PID
// porovnáváme i čas startu, aby se nepřevzal cizí proces se stejným PID.
enum ProcessInspector {
    struct Info: Equatable {
        // Čas startu procesu v sekundách od 1970 (s přesností na mikrosekundy)
        let startTime: TimeInterval
        // Skupina procesů – u aplikací spuštěných Runnerem je rovna PID
        let pgid: pid_t
        // Rodičovský proces (u aplikací spuštěných Runnerem je to launchd, PID 1)
        let ppid: pid_t
    }

    // Vrací informace o živém procesu, nebo nil (neexistuje nebo je to zombie)
    static func info(pid: pid_t) -> Info? {
        guard pid > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // Pro neexistující PID sysctl uspěje, ale vrátí nulovou velikost
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        // Ukončený proces, který ještě nikdo „neuklidil“, už neběží
        guard process.kp_proc.p_stat != SZOMB else { return nil }

        // Makro p_starttime není ve Swiftu dostupné – čteme přímo položku unie
        let start = process.kp_proc.p_un.__p_starttime
        return Info(
            startTime: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000,
            pgid: process.kp_eproc.e_pgid,
            ppid: process.kp_eproc.e_ppid
        )
    }
}
