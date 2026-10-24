import AppKit
import SwiftUI

/// Progress of Stop/Kill on one server (every row whose master it is).
enum DevPortAction: Equatable {
    /// SIGTERM sent; waiting for the processes to exit.
    case stopping
    /// Still running after the grace period: the button turns into a red Kill (SIGKILL).
    case needsKill([DevPortProcess])
    /// SIGKILL sent; the row stays like this until a scan confirms the port is free.
    case killing
}

/// A short message a row shows in place of its details for a few seconds.
struct DevPortNotice: Equatable {
    enum Tone { case info, success, warning, error }
    let text: String
    let tone: Tone
    let id: Int
}

/// Dev servers listening on this Mac: scanning, the closed-notch indicator, and Open/Copy/Stop actions.
///
/// Scans run on a utility serial queue and are published on the main actor. While a
/// `DevPortsListView` is on screen, every listener is scanned every 3 s. Otherwise, if the closed-notch
/// indicator is enabled, a quick scan every 10 s looks only at dev executables (plus likely-dev
/// servers found by the last full scan). With the indicator off and no list visible, no timer runs.
///
/// Stopping is two-step, like Force Quit: Stop sends SIGTERM to the server's master process and its
/// listeners; if any are still alive after 3 s, the button becomes Kill (SIGKILL), which needs another
/// click. Each process is re-validated (same start time, command and owner) right before it is signalled.
@MainActor
final class DevPortsStore: ObservableObject {
    static let shared = DevPortsStore()

    /// Full-scan interval while the list is visible.
    static let listInterval: TimeInterval = 3
    /// Quick-scan interval for the closed-notch indicator.
    static let backgroundInterval: TimeInterval = 10
    /// How long Stop waits for SIGTERM to work before offering Kill.
    static let killGracePeriod: Duration = .seconds(3)
    /// A detached server listening again this soon after Stop was restarted by a service manager.
    private static let respawnWindow: TimeInterval = 15

    /// True when at least one web dev server is listening and the closed-notch indicator is enabled.
    @Published private(set) var showsLiveActivity = false
    /// Every listener from the latest full scan: dev servers first, then by port.
    @Published private(set) var entries: [DevPortEntry] = []
    /// Ports counted by the closed-notch indicator (see `DevPortEntry.countsForIndicator`), ascending.
    @Published private(set) var livePorts: [UInt16] = []
    /// This Mac's address on the local network, for "Copy LAN URL".
    @Published private(set) var lanAddress: String?
    /// False until the first full scan has finished.
    @Published private(set) var hasScanned = false
    @Published private(set) var notices: [DevPortEntry.ID: DevPortNotice] = [:]
    /// Stop/Kill in progress, by the master process it was started on.
    @Published private var operations: [DevPortProcess: Operation] = [:]

    /// Show the dev-server indicator beside the closed notch.
    @Published var showInClosedNotch: Bool {
        didSet {
            guard showInClosedNotch != oldValue else { return }
            defaults.set(showInClosedNotch, forKey: Keys.showInClosedNotch)
            updateTimers()
            if showInClosedNotch { requestScan(full: true) }
            updateLiveActivity()
        }
    }

    /// List every listening port (apps, system services…), not only dev servers.
    @Published var showAll: Bool {
        didSet {
            guard showAll != oldValue else { return }
            defaults.set(showAll, forKey: Keys.showAll)
        }
    }

    private enum Keys {
        static let showInClosedNotch = "devPorts.showInClosedNotch"
        static let showAll = "devPorts.showAllListeners"
    }

    private struct Operation: Equatable {
        var action: DevPortAction
        /// Everything Stop signalled: the master and the listeners of all its rows.
        var targets: Set<DevPortProcess>
        /// Scans started before this one ran before the signal and can't settle the operation.
        var settlesFrom: Int
        /// The signals are done (everything exited, or SIGKILL went out): the next scan ends it either way.
        var isFinishing = false
        /// Quick scans see the server too (they skip apps and system listeners shown by "Show all").
        var isInQuickScans: Bool
    }

    /// A server Stop was used on, to notice a service manager bringing it back.
    private struct StoppedServer {
        let ports: Set<UInt16>
        let processes: Set<DevPortProcess>
        /// Rows of other servers on the same ports when Stop was pressed.
        let bystanders: Set<DevPortEntry.ID>
        let date: Date
    }

    private let defaults = UserDefaults.standard
    private let scanner = DevPortsScanner()
    private let scanQueue = DispatchQueue(label: "ARNotch.DevPorts.scan", qos: .utility)
    private var listTimer: Timer?
    private var backgroundTimer: Timer?
    private var visibleLists = 0
    private var scanInFlight = false
    /// A scan requested while another one ran (true = full); started when the running one finishes.
    private var queuedScan: Bool?
    /// Counts started scans.
    private var scanGeneration = 0
    private var didStart = false
    private var noticeSerial = 0
    private var noticeTasks: [DevPortEntry.ID: Task<Void, Never>] = [:]
    private var graceTasks: [DevPortProcess: Task<Void, Never>] = [:]
    private var recentlyStopped: [DevPortProcess: StoppedServer] = [:]

    private init() {
        defaults.register(defaults: [Keys.showInClosedNotch: true, Keys.showAll: false])
        showInClosedNotch = defaults.bool(forKey: Keys.showInClosedNotch)
        showAll = defaults.bool(forKey: Keys.showAll)
    }

    // MARK: Derived state

    /// What the list shows: dev servers, or every listener with "Show all".
    var visibleEntries: [DevPortEntry] { showAll ? entries : entries.filter(\.isDev) }
    var devCount: Int { entries.lazy.filter(\.isDev).count }
    /// Listeners hidden while "Show all" is off.
    var hiddenCount: Int { entries.count - devCount }
    /// Web dev servers, as the closed-notch indicator counts them.
    var webCount: Int { livePorts.count }

    /// Stop/Kill progress shown by `entry`: its master's, or that of a Stop whose processes it still holds.
    func action(for entry: DevPortEntry) -> DevPortAction? {
        operationKey(for: entry).flatMap { operations[$0]?.action }
    }

    private func operationKey(for entry: DevPortEntry) -> DevPortProcess? {
        if operations[entry.master] != nil { return entry.master }
        return operations.first { _, operation in
            operation.targets.contains(entry.master) || entry.listeners.contains(where: operation.targets.contains)
        }?.key
    }

    // MARK: Lifecycle

    /// Starts background monitoring for the closed-notch indicator (if enabled); called once at launch.
    func start() {
        guard !didStart else { return }
        didStart = true
        updateTimers()
        // One full scan also finds likely-dev servers (custom binaries) for the quick scans to follow.
        if showInClosedNotch { requestScan(full: true) }
    }

    /// Called by `DevPortsListView` when it appears: scan now, then every 3 s.
    func listDidAppear() {
        visibleLists += 1
        guard visibleLists == 1 else { return }
        updateTimers()
        requestScan(full: true)
    }

    func listDidDisappear() {
        visibleLists = max(visibleLists - 1, 0)
        if visibleLists == 0 { updateTimers() }
    }

    /// Rescans right away.
    func refresh() {
        requestScan(full: true)
    }

    // MARK: Scanning

    private func updateTimers() {
        let wantsList = visibleLists > 0
        // The list's full scans feed the indicator too, so the quick timer pauses meanwhile.
        let wantsBackground = !wantsList && showInClosedNotch

        if wantsList {
            if listTimer == nil { listTimer = makeTimer(interval: Self.listInterval, full: true) }
        } else {
            listTimer?.invalidate()
            listTimer = nil
        }
        if wantsBackground {
            if backgroundTimer == nil { backgroundTimer = makeTimer(interval: Self.backgroundInterval, full: false) }
        } else {
            backgroundTimer?.invalidate()
            backgroundTimer = nil
        }
    }

    private func makeTimer(interval: TimeInterval, full: Bool) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self?.requestScan(full: full) }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func requestScan(full: Bool) {
        if scanInFlight {
            queuedScan = (queuedScan ?? false) || full
            return
        }
        scanInFlight = true
        scanGeneration += 1
        let generation = scanGeneration
        let scanner = scanner
        scanQueue.async {
            let result = scanner.scan(full: full)
            DispatchQueue.main.async { DevPortsStore.shared.apply(result, generation: generation) }
        }
    }

    private func apply(_ result: DevPortsScanResult, generation: Int) {
        scanInFlight = false

        if result.isFull {
            if result.entries != entries { entries = result.entries }
            if result.lanAddress != lanAddress { lanAddress = result.lanAddress }
            if !hasScanned { hasScanned = true }
            noticeRespawns(in: result.entries)
        }
        settleOperations(with: result, generation: generation)
        let ports = Set(result.entries.lazy.filter(\.countsForIndicator).map(\.port)).sorted()
        if ports != livePorts { livePorts = ports }
        updateLiveActivity()

        if let full = queuedScan {
            queuedScan = nil
            requestScan(full: full)
        }
    }

    private func updateLiveActivity() {
        let shows = showInClosedNotch && !livePorts.isEmpty
        if shows != showsLiveActivity { showsLiveActivity = shows }
    }

    /// Ends Stop/Kill once its processes no longer listen, or once the signals are done. Runs after
    /// quick scans too, so a Kill left over from before the notch closed never sticks to a new server.
    private func settleOperations(with result: DevPortsScanResult, generation: Int) {
        for (key, operation) in operations where generation >= operation.settlesFrom && (result.isFull || operation.isInQuickScans) {
            let isListening = result.entries.contains { entry in
                entry.master == key || entry.listeners.contains(where: operation.targets.contains)
            }
            guard !isListening || operation.isFinishing else { continue }
            operations[key] = nil
            graceTasks[key]?.cancel()
            graceTasks[key] = nil
        }
    }

    /// Flags a stopped server's port taken again by a detached process (launchd agent, `brew services`,
    /// a supervisor). One started from a terminal is the user restarting it, which needs no comment.
    private func noticeRespawns(in entries: [DevPortEntry]) {
        let now = Date()
        for (key, stopped) in recentlyStopped {
            guard now.timeIntervalSince(stopped.date) <= Self.respawnWindow else {
                recentlyStopped[key] = nil
                continue
            }
            let successor = entries.first { entry in
                stopped.ports.contains(entry.port) && !stopped.bystanders.contains(entry.id)
                    && !stopped.processes.contains(entry.master) && !entry.listeners.contains(where: stopped.processes.contains)
            }
            guard let successor else { continue }
            recentlyStopped[key] = nil
            if successor.isDetached {
                post("Restarted automatically", tone: .warning, for: successor.id, duration: .seconds(5))
            }
        }
    }

    // MARK: Actions

    /// Opens the server in the default browser.
    func open(_ entry: DevPortEntry) {
        guard let url = entry.browserURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copies the URL (or "localhost:<port>").
    func copy(_ entry: DevPortEntry) {
        setPasteboard(entry.copyText)
        post("Copied \(entry.copyText)", tone: .success, for: entry.id)
    }

    /// Copies the address other devices on the network can use.
    func copyLAN(_ entry: DevPortEntry) {
        guard let address = lanAddress else {
            post("Not connected to a network", tone: .warning, for: entry.id)
            return
        }
        let text = entry.lanText(address: address)
        setPasteboard(text)
        post("Copied \(text)", tone: .success, for: entry.id)
    }

    func copyPID(_ entry: DevPortEntry) {
        setPasteboard("\(entry.master.pid)")
        post("Copied PID \(entry.master.pid)", tone: .success, for: entry.id)
    }

    /// Shows the server's project folder in Finder.
    func revealProject(_ entry: DevPortEntry) {
        guard let path = entry.projectPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    /// Explains why a row has no Stop button.
    func explainProtection(_ entry: DevPortEntry) {
        let text: String
        switch entry.protection {
        case .none: return
        case .otherUser: text = entry.context == "Valet" ? "Run by root — use valet stop" : "Run by root — needs sudo to stop"
        case .system: text = "macOS service — can't stop it"
        case .app(let name): text = "Quit \(name) instead"
        case .containerRuntime(let name): text = "Stop the container in \(name)"
        }
        post(text, tone: .info, for: entry.id, duration: .seconds(3.5))
    }

    /// First step: SIGTERM to the master and the listeners of every row it runs. Offers Kill if they
    /// survive the grace period.
    func stop(_ entry: DevPortEntry) {
        guard action(for: entry) == nil else { return }
        guard entry.isStoppable else {
            explainProtection(entry)
            return
        }
        let key = entry.master
        // One master can hold several rows (MAMP's mysqld on :8889 and :33060): stop them as one.
        let rows = [entry] + entries.filter { $0.master == key && $0.id != entry.id }
        var targets = [key]
        for row in rows {
            for process in row.listeners where !targets.contains(process) { targets.append(process) }
        }
        let ports = Set(rows.map(\.port))
        let stopped = StoppedServer(
            ports: ports,
            processes: Set(targets),
            bystanders: Set(entries.lazy.filter { ports.contains($0.port) && $0.master != key }.map(\.id)),
            date: Date()
        )
        operations[key] = Operation(
            action: .stopping, targets: Set(targets), settlesFrom: scanGeneration + 1, isInQuickScans: entry.category != .other
        )
        for row in rows { clearNotice(row.id) }
        let origin = entry.id
        scanQueue.async {
            let outcome = DevPortsSignaller.send(SIGTERM, to: targets)
            DispatchQueue.main.async { DevPortsStore.shared.didSendTerm(outcome, key: key, origin: origin, stopped: stopped) }
        }
    }

    /// Second step, only after Stop didn't work: SIGKILL to whatever is still running.
    func forceKill(_ entry: DevPortEntry) {
        guard let key = operationKey(for: entry), case .needsKill(let survivors)? = operations[key]?.action else { return }
        operations[key]?.action = .killing
        let origin = entry.id
        scanQueue.async {
            let outcome = DevPortsSignaller.send(SIGKILL, to: survivors)
            DispatchQueue.main.async { DevPortsStore.shared.didSendKill(outcome, key: key, origin: origin) }
        }
    }

    private func didSendTerm(_ outcome: DevPortSignalOutcome, key: DevPortProcess, origin: DevPortEntry.ID, stopped: StoppedServer) {
        guard operations[key]?.action == .stopping else { return }
        switch outcome {
        case .gone:
            recentlyStopped[key] = stopped
            finish(key)
        case .notPermitted:
            operations[key] = nil
            post("Not permitted to stop it", tone: .error, for: origin, duration: .seconds(3.5))
        case .sent:
            // From now on a detached server on the port is a restart, even if Kill is never needed.
            recentlyStopped[key] = stopped
            graceTasks[key]?.cancel()
            graceTasks[key] = Task { [weak self] in
                // Most servers exit within a moment: rescan early so the row goes away promptly.
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self else { return }
                self.requestScan(full: self.visibleLists > 0)
                try? await Task.sleep(for: DevPortsStore.killGracePeriod - .milliseconds(600))
                guard !Task.isCancelled else { return }
                self.checkSurvivors(key)
            }
        }
    }

    private func checkSurvivors(_ key: DevPortProcess) {
        graceTasks[key] = nil
        guard let operation = operations[key], operation.action == .stopping else { return }
        let targets = Array(operation.targets)
        scanQueue.async {
            let alive = DevPortsSignaller.survivors(of: targets)
            DispatchQueue.main.async { DevPortsStore.shared.didCheckSurvivors(alive, key: key) }
        }
    }

    private func didCheckSurvivors(_ alive: [DevPortProcess], key: DevPortProcess) {
        guard operations[key]?.action == .stopping else { return }
        if alive.isEmpty {
            finish(key)
        } else {
            operations[key]?.action = .needsKill(alive.sorted { $0.pid < $1.pid })
        }
    }

    private func didSendKill(_ outcome: DevPortSignalOutcome, key: DevPortProcess, origin: DevPortEntry.ID) {
        guard operations[key]?.action == .killing else { return }
        if outcome == .notPermitted {
            operations[key] = nil
            post("Not permitted to kill it", tone: .error, for: origin, duration: .seconds(3.5))
            return
        }
        // SIGKILL is immediate, but the kernel needs a moment to tear the sockets down. Until a scan
        // confirms it, the row keeps saying "Killing…" rather than looking like a healthy server.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.finish(key)
        }
    }

    /// The signals are done: the next scan removes the rows, or ends the operation if something still listens.
    private func finish(_ key: DevPortProcess) {
        guard operations[key] != nil else { return }
        operations[key]?.isFinishing = true
        operations[key]?.settlesFrom = scanGeneration + 1
        requestScan(full: visibleLists > 0)
    }

    // MARK: Helpers

    private func setPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func post(_ text: String, tone: DevPortNotice.Tone, for row: DevPortEntry.ID, duration: Duration = .seconds(2)) {
        noticeSerial += 1
        let notice = DevPortNotice(text: text, tone: tone, id: noticeSerial)
        notices[row] = notice
        noticeTasks[row]?.cancel()
        noticeTasks[row] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.notices[row]?.id == notice.id else { return }
            self.notices[row] = nil
            self.noticeTasks[row] = nil
        }
    }

    private func clearNotice(_ row: DevPortEntry.ID) {
        notices[row] = nil
        noticeTasks[row]?.cancel()
        noticeTasks[row] = nil
    }
}
