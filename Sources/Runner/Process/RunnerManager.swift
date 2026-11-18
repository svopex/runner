import Foundation
import Observation

// Správce všech aplikací: drží AppRunner pro každou položku konfigurace,
// pravidelně kontroluje porty a nabízí hromadné operace pro UI.
@MainActor
@Observable
final class RunnerManager {
    let config: ConfigStore
    // Záznamy o spuštěných procesech pro převzetí po restartu Runneru
    let stateStore: RunStateStore
    private(set) var runners: [AppRunner] = []
    // Požadavek na zobrazení nastavení (lze vyvolat i z menu v horní liště)
    var showSettings = false

    // Interval kontroly portů v sekundách
    private let pollInterval: TimeInterval = 2
    private var pollTimer: Timer?
    private var isRefreshing = false

    init(config: ConfigStore, stateStore: RunStateStore) {
        self.config = config
        self.stateStore = stateStore
        syncRunners()
        adoptRunningProcesses()
    }

    // Počet aplikací, které běží nebo se rozbíhají (pro ikonu v horní liště)
    var activeCount: Int {
        runners.filter { $0.status.canStop || $0.status == .stopping }.count
    }

    // Počet aplikací spuštěných tímto Runnerem
    var managedCount: Int {
        runners.filter(\.isManaged).count
    }

    func runner(for id: UUID?) -> AppRunner? {
        guard let id else { return nil }
        return runners.first { $0.id == id }
    }

    // MARK: - Spouštění a zastavování

    func startAll() {
        runners.filter { $0.status.canStart }.forEach { $0.start() }
    }

    // Zastaví všechny běžící aplikace včetně těch spuštěných mimo Runner
    func stopAll() {
        runners.filter { $0.status.canStop }.forEach { $0.stop() }
    }

    // Zastaví aplikace spuštěné Runnerem a počká na jejich konec (při ukončení Runneru)
    func stopManagedAndWait() async {
        let timeout = AppSettings.stopTimeout
        let managed = runners.filter(\.isManaged)
        managed.forEach { $0.stop(timeout: timeout) }

        // Rezerva navíc pro doručení SIGKILL a zpracování konce procesu
        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline, managed.contains(where: \.isManaged) {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // Po startu Runneru: zjistí stav portů a spustí aplikace s autoStart,
    // které už neběží (např. z předchozího běhu Runneru)
    func launchAutoStartApps() async {
        await refreshPorts()
        runners
            .filter { $0.definition.autoStart && $0.status.canStart }
            .forEach { $0.start() }
    }

    // Převezme aplikace, které spustil předchozí běh Runneru a které stále běží.
    // Záznamy aplikací, které už v konfiguraci nejsou, se zahodí (procesů se nedotýkáme).
    private func adoptRunningProcesses() {
        for (key, record) in stateStore.records {
            guard let id = UUID(uuidString: key) else { continue }
            if let runner = runner(for: id) {
                runner.adopt(record)
            } else {
                stateStore.remove(id: id)
            }
        }
    }

    // MARK: - Sledování portů

    func startMonitoring() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshPorts()
            }
        }
        Task { await refreshPorts() }
    }

    // Zkontroluje porty všech aplikací mimo hlavní vlákno a výsledek promítne do stavu
    func refreshPorts() async {
        // Překrývající se kontroly by jen zbytečně zatěžovaly systém
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let targets = runners.compactMap { runner in
            runner.definition.port.map { (id: runner.id, port: $0) }
        }
        let results = await Task.detached {
            targets.map { (id: $0.id, open: PortProbe.isListening(port: $0.port)) }
        }.value

        for result in results {
            runner(for: result.id)?.applyPortState(result.open)
        }
    }

    // MARK: - Úpravy konfigurace

    func addApp(_ app: AppDefinition) {
        config.add(app)
        syncRunners()
    }

    func updateApp(_ app: AppDefinition) {
        config.update(app)
        syncRunners()
    }

    // Odstranit lze jen neběžící aplikaci (UI to hlídá, tady pojistka)
    func removeApp(id: UUID) {
        if let runner = runner(for: id), runner.isManaged {
            return
        }
        config.remove(id: id)
        syncRunners()
    }

    func moveApps(fromOffsets source: IndexSet, toOffset destination: Int) {
        config.move(fromOffsets: source, toOffset: destination)
        syncRunners()
    }

    // Znovu načte apps.json (po ruční úpravě souboru)
    func reloadConfig() {
        config.load()
        syncRunners()
        Task { await refreshPorts() }
    }

    // Srovná seznam AppRunnerů s konfigurací: existující se zachovají (i s běžícím
    // procesem) a dostanou novou definici, nové se vytvoří, smazané odpadnou.
    // Běžící aplikace odebraná ručně z apps.json zůstane v seznamu až do zastavení.
    private func syncRunners() {
        var existing = Dictionary(runners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var updated: [AppRunner] = config.apps.map { definition in
            if let runner = existing.removeValue(forKey: definition.id) {
                runner.updateDefinition(definition)
                return runner
            }
            return AppRunner(definition: definition, stateStore: stateStore)
        }
        updated.append(contentsOf: existing.values.filter(\.isManaged))
        runners = updated
    }
}
