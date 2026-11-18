import Darwin
import Foundation
import XCTest
@testable import Runner

// Testy jádra Runneru: konfigurace, spouštění/zastavování procesů, porty a logy
final class RunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Vytvoří ve složce testovací run.sh s daným obsahem a právem ke spuštění
    private func makeApp(script body: String, port: Int? = nil, arguments: String = "") throws -> AppDefinition {
        let scriptURL = tempDir.appendingPathComponent("run.sh")
        try "#!/usr/bin/env bash\n\(body)\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return AppDefinition(name: "Test App", path: tempDir.path, arguments: arguments, port: port)
    }

    // Úložiště stavu procesů v dočasné složce testu
    @MainActor
    private func makeStateStore() -> RunStateStore {
        RunStateStore(fileURL: tempDir.appendingPathComponent("state.json"))
    }

    // Počká, dokud podmínka neplatí, nejdéle timeout sekund
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    // Asynchronně počká, než aplikace přestane běžet pod Runnerem (nejdéle timeout sekund)
    @MainActor
    private func waitUntilStopped(_ runner: AppRunner, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while runner.isManaged, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Model

    func testExitReasonDecoding() {
        XCTAssertEqual(ExitReason(rawStatus: 0), .exited(0))
        XCTAssertEqual(ExitReason(rawStatus: 3 << 8), .exited(3))
        XCTAssertEqual(ExitReason(rawStatus: SIGTERM), .signaled(SIGTERM))
    }

    func testDefinitionDecodingUsesDefaults() throws {
        let json = #"{"name": "A", "path": "~/x"}"#
        let app = try JSONDecoder().decode(AppDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(app.script, "run.sh")
        XCTAssertEqual(app.arguments, "")
        XCTAssertNil(app.port)
        XCTAssertFalse(app.autoStart)
        XCTAssertEqual(app.expandedPath, NSHomeDirectory() + "/x")
        XCTAssertEqual(app.scriptPath, NSHomeDirectory() + "/x/run.sh")
    }

    func testValidationReportsMissingAndNonExecutableScript() throws {
        var app = AppDefinition(name: "A", path: tempDir.path)
        XCTAssertNotNil(app.validationError)

        let scriptURL = tempDir.appendingPathComponent("run.sh")
        try "echo".write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.validationError?.contains("chmod") ?? false)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        XCTAssertNil(app.validationError)

        app.path = tempDir.appendingPathComponent("neexistuje").path
        XCTAssertNotNil(app.validationError)
    }

    @MainActor
    func testConfigStoreSeedsDefaultsAndPersistsChanges() throws {
        let fileURL = tempDir.appendingPathComponent("apps.json")
        let store = ConfigStore(fileURL: fileURL)
        XCTAssertEqual(store.apps.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let added = AppDefinition(name: "Nová", path: "/tmp", port: 9999)
        store.add(added)
        let reloaded = ConfigStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.apps.last, added)
    }

    @MainActor
    func testBrokenConfigIsBackedUp() throws {
        let fileURL = tempDir.appendingPathComponent("apps.json")
        try "{ nevalidní".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(fileURL: fileURL)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.apps.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).filter { $0.contains("broken") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: - Logy a příkaz

    func testLogCleanRemovesANSIAndCarriageReturns() {
        XCTAssertEqual(LogFile.clean("\u{1B}[32mOK\u{1B}[0m\r\nA\rB"), "OK\nA\nB")
    }

    func testShellCommandAppendsArguments() {
        XCTAssertEqual(ProcessSpawner.shellCommand(arguments: ""), #"cd "$RUNNER_APP_DIR" && exec "$RUNNER_APP_SCRIPT""#)
        XCTAssertTrue(ProcessSpawner.shellCommand(arguments: " --port 9000 ").hasSuffix(#""$RUNNER_APP_SCRIPT" --port 9000"#))
    }

    // MARK: - Procesy

    // Skript běží ve své složce, dostane parametry a výstup jde do logu
    func testSpawnWritesOutputToLogAndExits() throws {
        let app = try makeApp(script: #"echo "cwd=$(pwd) args=$*"; exit 3"#, arguments: "--a 1")
        let logURL = tempDir.appendingPathComponent("out.log")
        let pid = try ProcessSpawner.spawn(app: app, logURL: logURL)

        let exited = expectation(description: "exit")
        nonisolated(unsafe) var reason: ExitReason?
        let source = ProcessSpawner.watchExit(pid: pid) { reason = $0; exited.fulfill() }
        wait(for: [exited], timeout: 15)
        source.cancel()

        XCTAssertEqual(reason, .exited(3))
        let log = try String(contentsOf: logURL, encoding: .utf8)
        // Cesta v /var je symlink na /private/var – porovnáváme jen konec
        XCTAssertTrue(log.contains("args=--a 1"), log)
        XCTAssertTrue(log.contains(tempDir.lastPathComponent), log)
    }

    // SIGTERM skupině procesů ukončí i podřízené procesy skriptu
    func testSignalGroupStopsChildProcesses() throws {
        let markerURL = tempDir.appendingPathComponent("child.pid")
        let app = try makeApp(script: "sleep 300 & echo $! > \"\(markerURL.path)\"; wait")
        let pid = try ProcessSpawner.spawn(app: app, logURL: tempDir.appendingPathComponent("out.log"))

        XCTAssertTrue(waitUntil(timeout: 15) { FileManager.default.fileExists(atPath: markerURL.path) && LogFile.fileSize(markerURL) > 0 })
        let childPID = pid_t(try String(contentsOf: markerURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!

        let exited = expectation(description: "exit")
        let source = ProcessSpawner.watchExit(pid: pid) { _ in exited.fulfill() }
        XCTAssertTrue(ProcessSpawner.signalGroup(pid, SIGTERM))
        wait(for: [exited], timeout: 10)
        source.cancel()

        // Podřízený sleep musí zmizet také
        XCTAssertTrue(waitUntil(timeout: 5) { kill(childPID, 0) != 0 })
    }

    // Spuštěná aplikace musí být „odpovědným procesem“ sama za sebe, jinak ji macOS
    // ukončí spolu s Runnerem (Dock → Ukončit práci na pozadí, vynucené ukončení)
    func testSpawnedProcessIsResponsibleForItself() throws {
        typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
        let responsiblePID = try XCTUnwrap(
            ProcessSpawner.systemSymbol("responsibility_get_pid_responsible_for_pid", as: ResponsibleFunction.self),
            "Systém neposkytuje responsibility_get_pid_responsible_for_pid"
        )

        let app = try makeApp(script: "sleep 30")
        let pid = try ProcessSpawner.spawn(app: app, logURL: tempDir.appendingPathComponent("out.log"))
        defer {
            ProcessSpawner.signalGroup(pid, SIGKILL)
            waitpid(pid, nil, 0)
        }

        XCTAssertEqual(responsiblePID(pid), pid)
    }

    // Celý životní cyklus přes AppRunner: start → běží → stop → zastaveno
    @MainActor
    func testRunnerLifecycleWithoutPort() async throws {
        let app = try makeApp(script: "trap 'exit 0' TERM; while true; do sleep 0.1; done")
        let runner = AppRunner(definition: app, stateStore: makeStateStore())

        runner.start()
        XCTAssertEqual(runner.status, .running)
        XCTAssertNotNil(runner.pid)

        runner.stop(timeout: 5)
        XCTAssertEqual(runner.status, .stopping)
        try await waitUntilStopped(runner)
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertNil(runner.pid)
        try? FileManager.default.removeItem(at: runner.logURL)
    }

    // Proces ignorující SIGTERM se po timeoutu ukončí přes SIGKILL
    @MainActor
    func testRunnerEscalatesToSigkill() async throws {
        let app = try makeApp(script: "trap '' TERM; while true; do sleep 0.1; done")
        let runner = AppRunner(definition: app, stateStore: makeStateStore())
        runner.start()
        try await Task.sleep(for: .milliseconds(500))

        runner.stop(timeout: 1)
        try await waitUntilStopped(runner)
        XCTAssertEqual(runner.status, .stopped)
        try? FileManager.default.removeItem(at: runner.logURL)
    }

    // Nečekaný konec s nenulovým kódem se zobrazí jako chyba
    @MainActor
    func testRunnerReportsCrash() async throws {
        let app = try makeApp(script: "exit 7")
        let runner = AppRunner(definition: app, stateStore: makeStateStore())
        runner.start()
        try await waitUntilStopped(runner)
        guard case .failed(let message) = runner.status else {
            return XCTFail("Očekáván stav failed, je \(runner.status)")
        }
        XCTAssertTrue(message.contains("7"))
        try? FileManager.default.removeItem(at: runner.logURL)
    }

    // MARK: - Převzetí po restartu Runneru

    func testProcessInspectorReadsOwnProcess() throws {
        let info = try XCTUnwrap(ProcessInspector.info(pid: getpid()))
        XCTAssertLessThan(info.startTime, Date().timeIntervalSince1970)
        XCTAssertNil(ProcessInspector.info(pid: 999_999))
    }

    // Spuštění zapíše záznam, nový AppRunner (jako po restartu) proces převezme,
    // zastaví ho a záznam smaže
    @MainActor
    func testRunnerAdoptsProcessFromPreviousRun() async throws {
        let app = try makeApp(script: "trap 'exit 0' TERM; while true; do sleep 0.1; done")
        let store = makeStateStore()
        let original = AppRunner(definition: app, stateStore: store)
        original.start()
        let record = try XCTUnwrap(store.record(for: app.id))
        XCTAssertEqual(record.pid, original.pid)

        // Záznam musí přežít „restart“ – načteme ho z disku do nového úložiště
        let reloadedStore = RunStateStore(fileURL: store.fileURL)
        XCTAssertEqual(reloadedStore.record(for: app.id), record)

        let adopted = AppRunner(definition: app, stateStore: reloadedStore)
        XCTAssertTrue(adopted.adopt(record))
        XCTAssertEqual(adopted.pid, record.pid)
        XCTAssertEqual(adopted.status, .running)
        XCTAssertNotNil(adopted.startedAt)

        adopted.stop(timeout: 5)
        try await waitUntilStopped(adopted)
        XCTAssertEqual(adopted.status, .stopped)
        XCTAssertNil(reloadedStore.record(for: app.id))
        try? FileManager.default.removeItem(at: original.logURL)
    }

    // Záznam s nesouhlasícím časem startu (znovupoužitý PID) se nepřevezme
    @MainActor
    func testRunnerRejectsRecordWithDifferentStartTime() throws {
        let app = try makeApp(script: "exit 0")
        let store = makeStateStore()
        let record = RunStateStore.Record(pid: getpid(), startTime: 1, logPath: "/dev/null")
        store.set(record, for: app.id)

        let runner = AppRunner(definition: app, stateStore: store)
        XCTAssertFalse(runner.adopt(record))
        XCTAssertNil(runner.pid)
        XCTAssertNil(store.record(for: app.id))
    }

    // MARK: - Porty

    func testPortProbeDetectsListeningSocket() throws {
        // Otevřeme naslouchající soket na náhodném volném portu
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socketFD, 0)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress -> Bool in
                Darwin.bind(socketFD, socketAddress, length) == 0
                    && listen(socketFD, 1) == 0
                    && getsockname(socketFD, socketAddress, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = Int(UInt16(bigEndian: address.sin_port))

        XCTAssertTrue(PortProbe.isListening(port: port))
        XCTAssertTrue(PortProbe.listeningPIDs(port: port).isEmpty, "Vlastní PID se nesmí vracet")
        close(socketFD)
        XCTAssertFalse(PortProbe.isListening(port: port))
    }
}
