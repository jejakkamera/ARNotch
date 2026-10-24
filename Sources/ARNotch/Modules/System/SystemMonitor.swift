import AppKit
import ApplicationServices
import SwiftUI

/// Which metric the Top apps list is sorted by.
enum SystemProcessSort: String, CaseIterable, Identifiable {
    case cpu, memory
    var id: String { rawValue }
    var title: String { self == .cpu ? "CPU" : "Memory" }
}

/// What the right side of the System tab shows when a ports panel is supplied.
enum SystemPanel: String, CaseIterable, Identifiable {
    case apps, ports
    var id: String { rawValue }
    var title: String { self == .apps ? "Apps" : "Ports" }
}

/// What an on-screen view needs sampled.
enum SystemSamplingDemand: Hashable {
    /// CPU, memory and network every second (header metrics, metric cards).
    case metrics
    /// The running-app list and count, kept current from launch/quit notifications (System tab).
    case apps
    /// The per-process sweep every two seconds plus frozen-app checks (the Apps list only). Implies `.apps`.
    case processes
}

/// Latest header-level readings plus about a minute of history for the sparklines.
struct SystemMetrics: Equatable {
    /// Busy share of all cores, 0...100; nil until two readings exist.
    var cpu: Double?
    var memory: SystemMemoryUsage?
    var network: SystemNetworkRate?
    /// Oldest first, one entry per reading; nil entries are gaps while sampling was paused.
    var cpuHistory: [Double?] = []
    var networkHistory: [SystemNetworkRate?] = []

    static let historyLength = 60
}

/// A row of the Top apps list: an app with its helper processes, one heavy loose process, or several
/// light loose processes running the same executable.
struct SystemAppEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case app
        /// One process outside any app bundle.
        case process
        /// Several light processes running the same executable, added up ("node ×26"); never quittable.
        case processGroup
    }

    let id: String
    let kind: Kind
    let name: String
    /// The app's main pid, or the loose process's pid.
    let pid: pid_t
    /// Percent of one core (can exceed 100); nil until two sweeps exist.
    let cpu: Double?
    let memory: UInt64
    let processCount: Int
    /// Detected as not answering (needs Accessibility access).
    let isUnresponsive: Bool
    /// False for Crest itself, essential system processes and anything not owned by the user.
    let canQuit: Bool
    /// The row's processes are gone. Shown dimmed, without a button, only while the list order is held
    /// (so the rows below don't move under the pointer).
    var hasEnded = false

    /// This row as an "Ended" placeholder.
    func ended() -> SystemAppEntry {
        var copy = SystemAppEntry(
            id: id, kind: kind, name: name, pid: pid, cpu: cpu, memory: memory, processCount: processCount,
            isUnresponsive: false, canQuit: false
        )
        copy.hasEnded = true
        return copy
    }
}

/// What a row's action button currently does.
enum SystemRowAction: Equatable {
    case none
    case quit
    case quitting
    /// Force Quit was just offered; it ignores clicks for a moment so a click meant for something
    /// else can't land on it (drawn dimmed).
    case forceQuitArming
    case forceQuit
    /// The row's processes are gone (shown while the list order is held).
    case ended
}

/// Live system metrics, the heaviest apps, and quitting apps that hang.
///
/// Nothing runs while no view is visible: views hold a `SystemSamplingLease`, and sampling starts
/// with the first lease and stops with the last. Header metrics (CPU, memory, network) refresh every
/// second; the per-process sweep runs every two seconds only while the System tab's Apps list is
/// visible. All sampling happens on a utility queue; results are published on the main actor.
/// Frozen-app detection uses Accessibility and runs every three seconds while the Apps list is visible.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    static let metricsInterval: TimeInterval = 1
    static let processInterval: TimeInterval = 2
    static let hangCheckInterval: TimeInterval = 3
    /// Re-reads the running apps while the System tab is visible: catches apps that gain or lose their
    /// Dock icon, which posts no launch or quit notification.
    static let appsRefreshInterval: TimeInterval = 8
    /// How long Quit waits before offering Force Quit.
    static let quitGracePeriod: Duration = .seconds(3)
    /// How long Force Quit ignores clicks after it appears.
    static let forceQuitArmingDelay: TimeInterval = 0.8
    /// How long an offered Force Quit stays before the row goes back to Quit (e.g. after the user
    /// cancelled the app's "Save changes?" sheet).
    static let forceQuitOfferLifetime: Duration = .seconds(12)
    /// Rows in the Top apps list (frozen apps are pinned on top of these).
    static let topAppCount = 8
    static let activityMonitorBundleID = "com.apple.ActivityMonitor"

    @Published private(set) var metrics = SystemMetrics()
    /// Rows for the Top apps list, frozen apps first, then sorted by `sort`.
    @Published private(set) var topApps: [SystemAppEntry] = []
    /// False until the first process sweep after the System tab appeared.
    @Published private(set) var hasProcessSample = false
    /// False until a second sweep made per-app CPU available.
    @Published private(set) var hasProcessCPU = false
    /// Apps with a Dock presence (activation policy `.regular`).
    @Published private(set) var runningAppCount = 0
    /// Frozen apps left out of the list because its order is held under the pointer; the list shows
    /// a pill for them that calls `showFrozenApps()`.
    @Published private(set) var hiddenFrozenCount = 0
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    /// The "Allow Accessibility to detect frozen apps" banner was closed (until detection is turned on again).
    @Published private(set) var isFrozenAppsBannerDismissed: Bool
    @Published private var quitRequests: [String: QuitRequest] = [:]

    @Published var sort: SystemProcessSort {
        didSet {
            defaults.set(sort.rawValue, forKey: Keys.sort)
            heldOrder = nil
            updatePinnedKeys()
            rebuildTopApps()
        }
    }
    /// Apps or Ports on the right side of the System tab (only used when Core supplies a ports panel).
    /// Core may set it to open the tab on a given panel.
    @Published var panel: SystemPanel {
        didSet { defaults.set(panel.rawValue, forKey: Keys.panel) }
    }
    /// Shows the compact metrics beside the battery in the open-notch header.
    @Published var showsHeaderMetrics: Bool {
        didSet { defaults.set(showsHeaderMetrics, forKey: Keys.headerMetrics) }
    }
    /// Flags apps that stop responding (only works with Accessibility access).
    @Published var detectsFrozenApps: Bool {
        didSet {
            defaults.set(detectsFrozenApps, forKey: Keys.frozenApps)
            if detectsFrozenApps, !oldValue, isFrozenAppsBannerDismissed {
                isFrozenAppsBannerDismissed = false
                defaults.set(false, forKey: Keys.frozenBannerDismissed)
            }
            updateHangChecks()
        }
    }

    /// True when the Apps list should ask for Accessibility access.
    var showsFrozenAppsBanner: Bool {
        detectsFrozenApps && !isAccessibilityTrusted && !isFrozenAppsBannerDismissed
    }

    private enum Keys {
        static let headerMetrics = "system.showHeaderMetrics"
        static let frozenApps = "system.detectFrozenApps"
        static let frozenBannerDismissed = "system.frozenAppsBannerDismissed"
        static let sort = "system.processSort"
        static let panel = "system.rightPanel"
    }

    /// Never offered for quitting: quitting these logs out, breaks the desktop, or is Crest itself.
    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.WindowServer",
    ]
    private static let protectedNames: Set<String> = [
        "Finder", "Dock", "loginwindow", "SystemUIServer", "WindowServer", "ControlCenter", "Control Center", "ARNotch",
    ]
    private static let accessibilityPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    private let defaults = UserDefaults.standard
    private let samplingQueue = DispatchQueue(label: "ARNotch.SystemMonitor.sampling", qos: .utility)
    /// User-initiated so a saturated CPU can't delay an instant Accessibility failure into a "timeout".
    private let hangQueue = DispatchQueue(label: "ARNotch.SystemMonitor.hang", qos: .userInitiated)
    private let sampler = SystemSampler()
    private let hangProbe = SystemHangProbe()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var demandCounts: [SystemSamplingDemand: Int] = [:]
    private var metricsTimer: DispatchSourceTimer?
    private var processTimer: DispatchSourceTimer?
    private var hangTimer: Timer?
    private var appsRefreshTimer: Timer?
    /// Bumped whenever a sampler stops, so results still in flight are dropped.
    private var metricsGeneration = 0
    private var processGeneration = 0
    private var hangGeneration = 0
    private var hangCheckInFlight = false
    /// Uptime (seconds) of the last applied metrics reading; used to mark the pause as a gap in the history.
    private var lastMetricsUptime: TimeInterval?

    private var processGroups: [SystemProcessGroup] = []
    /// Row order frozen by `holdOrder(true)` while the pointer is over the list.
    private var heldOrder: [String]?
    private var unresponsivePIDs = Set<pid_t>()
    /// When each unresponsive app was first reported (uptime), for arming its Force Quit.
    private var unresponsiveSince: [pid_t: TimeInterval] = [:]
    /// Running apps by pid; captured when the System tab appears, re-read every few seconds, and kept
    /// current from NSWorkspace notifications in between.
    private var runningApps: [pid_t: SystemRunningApp] = [:]
    /// Bundle paths of the running regular apps, as last handed to the sampler.
    private var registeredAppBundles = Set<String>()
    /// True once the first snapshot for the current tracking session has arrived.
    private var hasRunningAppsSnapshot = false
    private var appsGeneration = 0
    /// Launches and quits seen while a snapshot is being captured; merged into it so the (older)
    /// snapshot can't undo them. Nil while no snapshot is in flight.
    private var pendingAppEvents: AppEvents?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var quitTargets: [String: QuitTarget] = [:]
    private var quitTasks: [String: Task<Void, Never>] = [:]
    private var armingRefreshTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]
    private var trustObserver: NSObjectProtocol?

    private struct AppEvents {
        var launched: [pid_t: SystemRunningApp] = [:]
        var terminated = Set<pid_t>()
    }

    /// What a row's button acts on. Apps are looked up as NSRunningApplication only when clicked.
    private enum QuitTarget: Equatable {
        case app(pid: pid_t)
        /// A loose process, re-verified by start time and executable path before it is signalled
        /// (pids get reused, and exec swaps the program).
        case process(pid: pid_t, startTime: UInt64, path: String)
    }

    /// A quit in progress for one row, bound to the process it was made for.
    private struct QuitRequest: Equatable {
        enum Phase: Equatable {
            /// Quit was requested; waiting to see whether the target exits.
            case quitting
            /// Still running after the grace period: the row offers Force Quit.
            case offerForceQuit
        }
        var phase: Phase
        /// A row that now shows another process (the app was relaunched) drops the request.
        let target: QuitTarget
        /// Uptime when Force Quit was offered.
        var armedAt: TimeInterval = 0
    }

    private init() {
        defaults.register(defaults: [
            Keys.headerMetrics: true,
            Keys.frozenApps: true,
            Keys.frozenBannerDismissed: false,
            Keys.sort: SystemProcessSort.cpu.rawValue,
            Keys.panel: SystemPanel.apps.rawValue,
        ])
        showsHeaderMetrics = defaults.bool(forKey: Keys.headerMetrics)
        detectsFrozenApps = defaults.bool(forKey: Keys.frozenApps)
        isFrozenAppsBannerDismissed = defaults.bool(forKey: Keys.frozenBannerDismissed)
        sort = SystemProcessSort(rawValue: defaults.string(forKey: Keys.sort) ?? "") ?? .cpu
        panel = SystemPanel(rawValue: defaults.string(forKey: Keys.panel) ?? "") ?? .apps

        // Posted when the Accessibility list changes in System Settings; TCC needs a moment to settle.
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                SystemMonitor.shared.refreshAccessibilityTrust()
            }
        }
    }

    // MARK: Demand

    /// Registers a visible consumer. Prefer `SystemSamplingLease`, which keeps calls balanced.
    func acquire(_ demand: SystemSamplingDemand) {
        demandCounts[demand, default: 0] += 1
        updateSampling()
    }

    func release(_ demand: SystemSamplingDemand) {
        demandCounts[demand] = max((demandCounts[demand] ?? 0) - 1, 0)
        updateSampling()
    }

    private var needsProcesses: Bool { (demandCounts[.processes] ?? 0) > 0 }
    private var needsApps: Bool { (demandCounts[.apps] ?? 0) > 0 || needsProcesses }
    private var needsMetrics: Bool { (demandCounts[.metrics] ?? 0) > 0 }

    /// True while anything is being sampled (for diagnostics and tests).
    var isSampling: Bool { metricsTimer != nil || processTimer != nil || isTrackingApps || hangTimer != nil }

    private func updateSampling() {
        if needsMetrics { startMetrics() } else { stopMetrics() }
        // App tracking starts before the sweep so its snapshot reaches the main queue first.
        if needsApps { startAppTracking() }
        if needsProcesses { startProcesses() } else { stopProcesses() }
        if !needsApps { stopAppTracking() }
        updateHangChecks()
    }

    // MARK: Header metrics

    private func startMetrics() {
        guard metricsTimer == nil else { return }
        metricsGeneration += 1
        let generation = metricsGeneration
        markPauseInHistory()

        let sampler = self.sampler
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        // The first rate comes 0.25 s after the baseline, while the notch is still opening.
        timer.schedule(deadline: .now() + 0.25, repeating: Self.metricsInterval, leeway: .milliseconds(100))
        timer.setEventHandler {
            let sample = sampler.sampleMetrics()
            DispatchQueue.main.async {
                SystemMonitor.shared.applyMetrics(sample, generation: generation)
            }
        }
        samplingQueue.async {
            sampler.resetMetricsBaseline()
            let baseline = sampler.sampleMetrics()
            DispatchQueue.main.async {
                SystemMonitor.shared.applyBaseline(baseline, generation: generation)
            }
        }
        timer.resume()
        metricsTimer = timer
    }

    private func stopMetrics() {
        guard let timer = metricsTimer else { return }
        timer.cancel()
        metricsTimer = nil
        metricsGeneration += 1
    }

    /// The baseline carries memory only (rates need two readings); earlier rates stay until the first one arrives.
    private func applyBaseline(_ sample: SystemMetricsSample, generation: Int) {
        guard generation == metricsGeneration, let memory = sample.memory, memory != metrics.memory else { return }
        metrics.memory = memory
    }

    private func applyMetrics(_ sample: SystemMetricsSample, generation: Int) {
        guard generation == metricsGeneration else { return }
        var next = metrics
        if let cpu = sample.cpu { next.cpu = cpu }
        if let memory = sample.memory { next.memory = memory }
        if let network = sample.network { next.network = network }
        next.cpuHistory.append(sample.cpu)
        next.networkHistory.append(sample.network)
        Self.trim(&next.cpuHistory)
        Self.trim(&next.networkHistory)
        metrics = next
        lastMetricsUptime = ProcessInfo.processInfo.systemUptime
    }

    /// Appends one gap entry per missed second, or clears the history when all of it is stale.
    private func markPauseInHistory() {
        guard let last = lastMetricsUptime else { return }
        let missed = Int((ProcessInfo.processInfo.systemUptime - last) / Self.metricsInterval) - 1
        guard missed > 0 else { return }
        if missed >= SystemMetrics.historyLength {
            metrics.cpuHistory.removeAll()
            metrics.networkHistory.removeAll()
        } else {
            metrics.cpuHistory.append(contentsOf: Array(repeating: nil, count: missed))
            metrics.networkHistory.append(contentsOf: Array(repeating: nil, count: missed))
            Self.trim(&metrics.cpuHistory)
            Self.trim(&metrics.networkHistory)
        }
    }

    private static func trim<T>(_ history: inout [T]) {
        if history.count > SystemMetrics.historyLength {
            history.removeFirst(history.count - SystemMetrics.historyLength)
        }
    }

    // MARK: Processes

    private func startProcesses() {
        guard processTimer == nil else { return }
        processGeneration += 1
        let generation = processGeneration

        let sampler = self.sampler
        let sweep: @Sendable () -> Void = {
            let sample = sampler.sampleProcesses()
            DispatchQueue.main.async {
                SystemMonitor.shared.applyProcesses(sample, generation: generation)
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        // The second sweep comes early: the CPU-sorted list waits for it ("Measuring…").
        timer.schedule(deadline: .now() + 0.6, repeating: Self.processInterval, leeway: .milliseconds(200))
        timer.setEventHandler(handler: sweep)
        let bundles = registeredAppBundles
        samplingQueue.async {
            sampler.resetProcesses()
            sampler.registeredAppBundles = bundles
            sweep()
        }
        timer.resume()
        processTimer = timer
    }

    private func stopProcesses() {
        guard let timer = processTimer else { return }
        timer.cancel()
        processTimer = nil
        processGeneration += 1
        let sampler = self.sampler
        samplingQueue.async { sampler.resetProcesses() }

        processGroups = []
        heldOrder = nil
        topApps = []
        if hiddenFrozenCount != 0 { hiddenFrozenCount = 0 }
        hasProcessSample = false
        hasProcessCPU = false
        quitTargets = [:]
        // Quit requests belong to this visit: a later visit starts every row at Quit again.
        quitTasks.values.forEach { $0.cancel() }
        quitTasks = [:]
        if !quitRequests.isEmpty { quitRequests = [:] }
        armingRefreshTask?.cancel()
        armingRefreshTask = nil
        iconCache = [:]
    }

    private func applyProcesses(_ sample: SystemProcessSample, generation: Int) {
        guard generation == processGeneration else { return }
        processGroups = sample.groups
        if !hasProcessSample { hasProcessSample = true }
        if hasProcessCPU != sample.hasCPU { hasProcessCPU = sample.hasCPU }
        rebuildTopApps()
    }

    // MARK: Running apps

    private var isTrackingApps: Bool { !workspaceObservers.isEmpty }

    /// Captures the running apps off the main thread, then follows launches and quits, and re-reads
    /// them every few seconds.
    private func startAppTracking() {
        guard !isTrackingApps else { return }
        appsGeneration += 1
        observeWorkspace()
        requestAppsSnapshot()
        let timer = Timer(timeInterval: Self.appsRefreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { SystemMonitor.shared.requestAppsSnapshot() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        appsRefreshTimer = timer
    }

    private func stopAppTracking() {
        guard isTrackingApps else { return }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        appsRefreshTimer?.invalidate()
        appsRefreshTimer = nil
        appsGeneration += 1
        pendingAppEvents = nil
        runningApps = [:]
        hasRunningAppsSnapshot = false
        // `runningAppCount` keeps its last value, so the next visit doesn't flash "0 apps".
    }

    /// Reads all running apps off the main thread (about 15 ms for 130 apps); one at a time.
    private func requestAppsSnapshot() {
        guard isTrackingApps, pendingAppEvents == nil else { return }
        pendingAppEvents = AppEvents()
        let generation = appsGeneration
        samplingQueue.async {
            let apps = SystemRunningApp.snapshot()
            DispatchQueue.main.async {
                SystemMonitor.shared.applyRunningApps(apps, generation: generation)
            }
        }
    }

    private func applyRunningApps(_ apps: [SystemRunningApp], generation: Int) {
        guard generation == appsGeneration else { return }
        var next = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        if let events = pendingAppEvents {
            // Notifications that arrived while the snapshot was captured are newer than it.
            for pid in events.terminated { next.removeValue(forKey: pid) }
            next.merge(events.launched) { _, launched in launched }
        }
        pendingAppEvents = nil
        let isFirst = !hasRunningAppsSnapshot
        hasRunningAppsSnapshot = true
        if next != runningApps {
            runningApps = next
            forgetUnresponsiveApps()
            runningAppsChanged()
        }
        // First frozen-app check right away; with two failures needed, a hung app shows up after ~3 s.
        if isFirst, hangTimer != nil { runHangCheck() }
    }

    /// Launches and quits while the System tab is visible; each costs one LaunchServices lookup.
    private func observeWorkspace() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let info = SystemRunningApp(app)
            MainActor.assumeIsolated { SystemMonitor.shared.appLaunched(info) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { SystemMonitor.shared.appTerminated(pid) }
        })
    }

    private func appLaunched(_ app: SystemRunningApp) {
        guard isTrackingApps else { return }
        pendingAppEvents?.terminated.remove(app.pid)
        pendingAppEvents?.launched[app.pid] = app
        guard runningApps[app.pid] != app else { return }
        runningApps[app.pid] = app
        runningAppsChanged()
    }

    private func appTerminated(_ pid: pid_t) {
        guard isTrackingApps else { return }
        pendingAppEvents?.launched.removeValue(forKey: pid)
        pendingAppEvents?.terminated.insert(pid)
        guard runningApps.removeValue(forKey: pid) != nil else { return }
        forgetUnresponsiveApps()
        runningAppsChanged()
    }

    private func forgetUnresponsiveApps() {
        let gone = unresponsivePIDs.filter { runningApps[$0] == nil }
        guard !gone.isEmpty else { return }
        unresponsivePIDs.subtract(gone)
        gone.forEach { unresponsiveSince.removeValue(forKey: $0) }
    }

    private func runningAppsChanged() {
        let count = runningApps.values.reduce(0) { $0 + ($1.isRegular ? 1 : 0) }
        if count != runningAppCount { runningAppCount = count }

        let bundles = Set(runningApps.values.lazy.filter(\.isRegular).compactMap(\.bundlePath))
        if bundles != registeredAppBundles {
            registeredAppBundles = bundles
            let sampler = self.sampler
            samplingQueue.async { sampler.registeredAppBundles = bundles }
        }
        rebuildTopApps()
    }

    // MARK: Rows

    /// Keeps the current rows in place while the pointer is over the list, so a row never moves under
    /// a click: values keep updating, rows whose processes exit stay as dimmed "Ended" placeholders,
    /// and apps that freeze meanwhile are counted in `hiddenFrozenCount` instead of being inserted.
    /// Does nothing until the rows are final (the CPU-sorted list waits for the second sweep).
    func holdOrder(_ hold: Bool) {
        if hold {
            guard heldOrder == nil, hasProcessSample, sort == .memory || hasProcessCPU, !topApps.isEmpty else { return }
            heldOrder = topApps.map(\.id)
            updatePinnedKeys()
        } else if heldOrder != nil {
            heldOrder = nil
            updatePinnedKeys()
            rebuildTopApps()
        }
    }

    /// Releases the held order so apps that froze meanwhile move to the top of the list.
    func showFrozenApps() {
        holdOrder(false)
    }

    /// Held rows stay listed by the sampler even when they drop below the loose-process thresholds.
    private func updatePinnedKeys() {
        let keys = Set(heldOrder ?? [])
        let sampler = self.sampler
        samplingQueue.async { sampler.pinnedKeys = keys }
    }

    /// Recomputes the visible rows: frozen apps first, then the top apps by the selected metric.
    private func rebuildTopApps() {
        guard hasProcessSample else { return }
        var targets: [String: QuitTarget] = [:]
        var rows: [SystemAppEntry] = []
        var hiddenFrozen = 0

        if let heldOrder {
            let groupsByKey = Dictionary(processGroups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let shown = Dictionary(topApps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for key in heldOrder {
                if let group = groupsByKey[key] {
                    let app = resolveApp(for: group)
                    rows.append(makeEntry(for: group, app: app, isFrozen: isFrozen(app), targets: &targets))
                } else if let row = shown[key] {
                    // Gone: a placeholder keeps the rows below where the pointer expects them.
                    rows.append(row.hasEnded ? row : row.ended())
                }
            }
            let held = Set(heldOrder)
            for group in processGroups where !held.contains(group.key) && isFrozen(resolveApp(for: group)) {
                hiddenFrozen += 1
            }
        } else {
            let ordered: [SystemProcessGroup]
            switch sort {
            case .cpu:
                ordered = processGroups.sorted { ($0.cpu ?? -1, $0.memory) > ($1.cpu ?? -1, $1.memory) }
            case .memory:
                ordered = processGroups.sorted { $0.memory > $1.memory }
            }
            var frozen: [SystemAppEntry] = []
            var regular: [SystemAppEntry] = []
            for group in ordered {
                let app = resolveApp(for: group)
                let frozenApp = isFrozen(app)
                guard frozenApp || regular.count < Self.topAppCount else { continue }
                let entry = makeEntry(for: group, app: app, isFrozen: frozenApp, targets: &targets)
                if frozenApp { frozen.append(entry) } else { regular.append(entry) }
            }
            rows = frozen + regular
        }
        quitTargets = targets

        // A request ends with its row, and with the process it was made for: a relaunched app (new
        // pid on the same row) starts again at Quit.
        let stale = quitRequests.filter { targets[$0.key] != $0.value.target }.map(\.key)
        if !stale.isEmpty {
            for key in stale { quitTasks.removeValue(forKey: key)?.cancel() }
            quitRequests = quitRequests.filter { !stale.contains($0.key) }
        }

        if hiddenFrozen != hiddenFrozenCount { hiddenFrozenCount = hiddenFrozen }
        if rows != topApps { topApps = rows }
    }

    private func isFrozen(_ app: SystemRunningApp?) -> Bool {
        guard let app, !unresponsivePIDs.isEmpty else { return false }
        return unresponsivePIDs.contains(app.pid)
    }

    private func makeEntry(
        for group: SystemProcessGroup, app: SystemRunningApp?, isFrozen: Bool, targets: inout [String: QuitTarget]
    ) -> SystemAppEntry {
        let pid = app?.pid ?? group.leaderPID ?? group.pids.first ?? 0

        var target: QuitTarget?
        if let app {
            if !isProtected(app) { target = .app(pid: app.pid) }
        } else if group.kind != .executable, let leader = group.leaderPID, let path = group.leaderPath,
                  !group.isSystemPath, leader != ownPID, !group.pids.contains(ownPID),
                  !Self.protectedNames.contains(group.name) {
            // A loose process, or an app bundle LaunchServices doesn't know (e.g. a CLI shipped as an .app):
            // signal its main process; helpers normally exit with it.
            target = .process(pid: leader, startTime: group.leaderStartTime, path: path)
        }
        if let target { targets[group.key] = target }

        if iconCache[group.key] == nil, let path = app?.bundlePath ?? group.bundlePath {
            iconCache[group.key] = NSWorkspace.shared.icon(forFile: path)
        }

        let kind: SystemAppEntry.Kind
        switch group.kind {
        case .bundle: kind = .app
        case .process: kind = .process
        case .executable: kind = .processGroup
        }
        return SystemAppEntry(
            id: group.key,
            kind: kind,
            name: app?.name ?? group.name,
            pid: pid,
            cpu: group.cpu,
            memory: group.memory,
            processCount: group.pids.count,
            isUnresponsive: isFrozen,
            canQuit: target != nil
        )
    }

    /// The running app a bundle group belongs to. Matches the bundle path first, then the bundle name
    /// (Safari runs from a system cryptex but registers /Applications/Safari.app), then a sole
    /// registered app inside the bundle (e.g. a login-item helper running on its own).
    private func resolveApp(for group: SystemProcessGroup) -> SystemRunningApp? {
        guard let bundlePath = group.bundlePath, !runningApps.isEmpty else { return nil }
        let bundleName = (bundlePath as NSString).lastPathComponent
        var sameName: SystemRunningApp?
        var registered: [SystemRunningApp] = []
        for pid in group.pids {
            guard let app = runningApps[pid] else { continue }
            registered.append(app)
            guard let path = app.bundlePath else { continue }
            if path == bundlePath { return app }
            if sameName == nil, (path as NSString).lastPathComponent == bundleName { sameName = app }
        }
        return sameName ?? (registered.count == 1 ? registered[0] : nil)
    }

    private func isProtected(_ app: SystemRunningApp) -> Bool {
        if app.pid == ownPID { return true }
        if let id = app.bundleIdentifier {
            if Self.protectedBundleIDs.contains(id) || id == Bundle.main.bundleIdentifier { return true }
        }
        if Self.protectedNames.contains(app.name ?? "") { return true }
        // Background agents that ship with macOS (Spotlight, Notification Center, Window Manager…):
        // ending them disrupts the desktop, so they are left to Activity Monitor.
        if !app.isRegular, let path = app.bundlePath, SystemSampler.isSystemLocation(path) { return true }
        return false
    }

    /// App icon for a row (nil for loose processes).
    func icon(for entry: SystemAppEntry) -> NSImage? { iconCache[entry.id] }

    /// What the row's button does right now.
    func action(for entry: SystemAppEntry) -> SystemRowAction {
        if entry.hasEnded { return .ended }
        guard entry.canQuit, let target = quitTargets[entry.id] else { return .none }
        if let request = quitRequests[entry.id], request.target == target {
            switch request.phase {
            case .quitting: return .quitting
            case .offerForceQuit: return isArmed(since: request.armedAt) ? .forceQuit : .forceQuitArming
            }
        }
        if entry.isUnresponsive, case .app(let pid) = target {
            return isArmed(since: unresponsiveSince[pid] ?? 0) ? .forceQuit : .forceQuitArming
        }
        return .quit
    }

    private func isArmed(since time: TimeInterval) -> Bool {
        ProcessInfo.processInfo.systemUptime - time >= Self.forceQuitArmingDelay
    }

    /// Redraws the rows once a Force Quit that just appeared accepts clicks.
    private func scheduleArmingRefresh() {
        armingRefreshTask?.cancel()
        armingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.forceQuitArmingDelay * 1_000) + 50))
            guard !Task.isCancelled, let self else { return }
            self.armingRefreshTask = nil
            self.objectWillChange.send()
        }
    }

    // MARK: Quitting

    /// Asks the app to quit (or sends SIGTERM to a loose process). If it is still running after the grace
    /// period, the row offers Force Quit, which needs another explicit click. Ignored unless the row
    /// currently shows Quit.
    func quit(_ entry: SystemAppEntry) {
        guard let current = topApps.first(where: { $0.id == entry.id }), action(for: current) == .quit,
              let target = quitTargets[entry.id]
        else { return }
        end(target, key: entry.id, force: false)
    }

    /// Ends the app immediately (SIGKILL for loose processes). Unsaved changes are lost. Ignored unless the
    /// row currently shows an armed Force Quit for this same process (offered after Quit, or a frozen app).
    func forceQuit(_ entry: SystemAppEntry) {
        guard let current = topApps.first(where: { $0.id == entry.id }), action(for: current) == .forceQuit,
              let target = quitTargets[entry.id]
        else { return }
        end(target, key: entry.id, force: true)
    }

    private func end(_ target: QuitTarget, key: String, force: Bool) {
        switch target {
        case .app(let pid):
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                removeQuitRequest(key)
                return
            }
            let delivered = force ? app.forceTerminate() : app.terminate()
            if !delivered, force { NSSound.beep() }
            // Even an undelivered request waits out the grace period, so Force Quit never appears
            // under the second click of a double-click.
            beginGracePeriod(for: key, target: target) { report in report(app.isTerminated) }
        case let .process(pid, startTime, path):
            quitRequests[key] = QuitRequest(phase: .quitting, target: target)
            let signal = force ? SIGKILL : SIGTERM
            samplingQueue.async {
                let sent = SystemSampler.canSignal(pid, startTime: startTime, path: path) && kill(pid, signal) == 0
                DispatchQueue.main.async {
                    SystemMonitor.shared.signalSent(sent, key: key, target: target)
                }
            }
        }
    }

    private func signalSent(_ sent: Bool, key: String, target: QuitTarget) {
        guard quitRequests[key]?.target == target else { return }
        guard sent, case let .process(pid, startTime, _) = target else {
            // The process is gone already (or is no longer the one listed); the next sweep updates the row.
            removeQuitRequest(key)
            return
        }
        let queue = samplingQueue
        beginGracePeriod(for: key, target: target) { report in
            queue.async {
                let gone = !SystemSampler.isSameUserProcess(pid, startTime: startTime)
                DispatchQueue.main.async { report(gone) }
            }
        }
    }

    private func removeQuitRequest(_ key: String) {
        quitTasks.removeValue(forKey: key)?.cancel()
        if quitRequests[key] != nil { quitRequests.removeValue(forKey: key) }
    }

    /// Shows "Quitting…", then after the grace period asks `check` whether the target is gone; if not,
    /// the row offers Force Quit for a while, then goes back to Quit.
    private func beginGracePeriod(
        for key: String, target: QuitTarget, check: @escaping (@escaping @MainActor (Bool) -> Void) -> Void
    ) {
        quitRequests[key] = QuitRequest(phase: .quitting, target: target)
        quitTasks[key]?.cancel()
        quitTasks[key] = Task {
            try? await Task.sleep(for: Self.quitGracePeriod)
            guard !Task.isCancelled else { return }
            check { gone in
                SystemMonitor.shared.gracePeriodEnded(key: key, target: target, gone: gone)
            }
        }
    }

    private func gracePeriodEnded(key: String, target: QuitTarget, gone: Bool) {
        // Dropped meanwhile: the tab closed, the row went away, or the row now shows another process.
        guard let request = quitRequests[key], request.target == target, request.phase == .quitting else { return }
        if gone {
            removeQuitRequest(key)
            return
        }
        let armedAt = ProcessInfo.processInfo.systemUptime
        quitRequests[key] = QuitRequest(phase: .offerForceQuit, target: target, armedAt: armedAt)
        scheduleArmingRefresh()
        quitTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.forceQuitOfferLifetime)
            guard !Task.isCancelled, let self, self.quitRequests[key]?.armedAt == armedAt else { return }
            self.quitTasks[key] = nil
            self.quitRequests.removeValue(forKey: key)
        }
    }

    /// Opens (or brings forward) Activity Monitor.
    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.activityMonitorBundleID) else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    // MARK: Frozen apps

    private func updateHangChecks() {
        let wanted = needsProcesses && detectsFrozenApps
        if wanted, hangTimer == nil {
            hangGeneration += 1
            let timer = Timer(timeInterval: Self.hangCheckInterval, repeats: true) { _ in
                MainActor.assumeIsolated { SystemMonitor.shared.runHangCheck() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            hangTimer = timer
            // The first check runs as soon as the running apps are known: now, or when the snapshot arrives.
            if hasRunningAppsSnapshot { runHangCheck() }
        } else if !wanted, let timer = hangTimer {
            timer.invalidate()
            hangTimer = nil
            hangGeneration += 1
            let probe = hangProbe
            hangQueue.async { probe.reset() }
            unresponsiveSince = [:]
            if !unresponsivePIDs.isEmpty {
                unresponsivePIDs = []
                rebuildTopApps()
            }
        }
    }

    /// One Accessibility sweep over the regular apps; a no-op while the previous one is still running.
    private func runHangCheck() {
        guard !hangCheckInFlight else { return }
        hangCheckInFlight = true
        let generation = hangGeneration
        let pids = runningApps.values
            .filter { $0.isRegular && $0.isFinishedLaunching && $0.pid != ownPID }
            .map(\.pid)
        let probe = hangProbe
        hangQueue.async {
            let result = probe.check(pids)
            DispatchQueue.main.async {
                SystemMonitor.shared.applyHangCheck(result, generation: generation)
            }
        }
    }

    private func applyHangCheck(_ result: Set<pid_t>?, generation: Int) {
        hangCheckInFlight = false
        let trusted = result != nil
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        guard generation == hangGeneration else { return }
        // Apps that quit while the check ran stay out.
        let next = (result ?? []).filter { runningApps[$0] != nil }
        guard next != unresponsivePIDs else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let newlyFrozen = next.subtracting(unresponsivePIDs)
        for pid in newlyFrozen { unresponsiveSince[pid] = now }
        unresponsiveSince = unresponsiveSince.filter { next.contains($0.key) }
        unresponsivePIDs = next
        if !newlyFrozen.isEmpty { scheduleArmingRefresh() }
        rebuildTopApps()
    }

    /// Re-reads whether Crest may use Accessibility.
    func refreshAccessibilityTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
    }

    /// Shows the system Accessibility prompt and opens the matching System Settings pane.
    /// Only call this from an explicit user action.
    func requestAccessibilityAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if trusted != isAccessibilityTrusted { isAccessibilityTrusted = trusted }
        if !trusted, let url = Self.accessibilityPaneURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings › Privacy & Security › Accessibility.
    func openAccessibilitySettings() {
        if let url = Self.accessibilityPaneURL { NSWorkspace.shared.open(url) }
    }

    /// Hides the Apps list's Accessibility banner until frozen-app detection is turned on again.
    func dismissFrozenAppsBanner() {
        isFrozenAppsBannerDismissed = true
        defaults.set(true, forKey: Keys.frozenBannerDismissed)
    }

    // MARK: Uptime

    /// Boot time from kern.boottime (includes time asleep, like `uptime`).
    nonisolated static let bootDate: Date? = {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000)
    }()
}

/// Ties sampling to a view's time on screen. `hold()` / `drop()` are idempotent, so repeated or
/// missing appear/disappear callbacks can never leave sampling running.
@MainActor
final class SystemSamplingLease: ObservableObject {
    private let demands: [SystemSamplingDemand]
    private var isHeld = false

    init(_ demands: SystemSamplingDemand...) {
        self.demands = demands
    }

    func hold() {
        guard !isHeld else { return }
        isHeld = true
        demands.forEach(SystemMonitor.shared.acquire)
    }

    func drop() {
        guard isHeld else { return }
        isHeld = false
        demands.forEach(SystemMonitor.shared.release)
    }

    deinit {
        // Safety net for a view torn down without onDisappear.
        guard isHeld else { return }
        let demands = self.demands
        DispatchQueue.main.async {
            MainActor.assumeIsolated { demands.forEach(SystemMonitor.shared.release) }
        }
    }
}
