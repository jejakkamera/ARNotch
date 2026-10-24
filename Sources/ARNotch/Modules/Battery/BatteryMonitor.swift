import AppKit
import IOKit.ps
import SwiftUI

/// A point-in-time reading of the internal battery.
struct BatteryState: Equatable, Sendable {
    /// False on Macs without an internal battery; battery views then render nothing.
    var hasBattery = false
    /// Charge level in percent, 0...100.
    var percentage = 0
    var isCharging = false
    /// True while the power source state is AC (may be plugged in without charging).
    var isPluggedIn = false
    var isCharged = false
    /// Minutes until full; nil while unknown or not charging.
    var timeToFull: Int?
    /// Minutes until empty; nil while unknown or plugged in.
    var timeToEmpty: Int?
    /// Battery health from AppleSmartBattery; nil when the registry doesn't report it.
    var health: BatteryHealth?

    static let unavailable = BatteryState()

    /// Reads the internal battery through IOKit power sources. Safe to call off the main thread.
    static func read() -> BatteryState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let level = maximum > 0 ? Double(current) / Double(maximum) * 100 : Double(current)
            let isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            // IOKit reports -1 while it is still estimating and 0 when not applicable.
            let toFull = description[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let toEmpty = description[kIOPSTimeToEmptyKey] as? Int ?? -1

            return BatteryState(
                hasBattery: true,
                percentage: min(max(Int(level.rounded()), 0), 100),
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                timeToFull: isCharging && toFull > 0 ? toFull : nil,
                timeToEmpty: !isPluggedIn && toEmpty > 0 ? toEmpty : nil,
                health: BatteryHealth.read()
            )
        }
        return .unavailable
    }
}

/// Cycle count and maximum capacity, as System Settings › Battery › Battery Health shows them.
struct BatteryHealth: Equatable, Sendable {
    var cycleCount: Int?
    /// Cycles the battery is designed for (1000 on recent MacBooks).
    var designCycleCount: Int?
    /// Full-charge capacity relative to the design capacity, in percent (100 = new).
    var maximumCapacity: Int?
    var fullChargeCapacity: Int?
    var designCapacity: Int?

    /// Apple recommends service below 80% maximum capacity.
    var needsService: Bool { (maximumCapacity ?? 100) < 80 }
    var condition: String { needsService ? "Service recommended" : "Normal" }

    /// Reads the AppleSmartBattery registry entry. Safe off the main thread; no special access needed.
    static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let data = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        let details = data["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            ((details[key] ?? data[key]) as? NSNumber)?.intValue
        }
        var health = BatteryHealth()
        health.cycleCount = int("CycleCount")
        health.designCycleCount = int("DesignCycleCount9C")
        // NominalChargeCapacity matches the "Maximum Capacity" System Settings shows; older
        // releases only publish AppleRawMaxCapacity.
        let design = int("DesignCapacity")
        let full = int("NominalChargeCapacity") ?? (data["AppleRawMaxCapacity"] as? NSNumber)?.intValue
        if let design, design > 0, let full, full > 0 {
            health.designCapacity = design
            health.fullChargeCapacity = full
            health.maximumCapacity = min(100, Int((Double(full) / Double(design) * 100).rounded(.down)))
        }
        return health.cycleCount == nil && health.maximumCapacity == nil ? nil : health
    }
}

/// Observes the internal battery and Low Power Mode without polling.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    /// True for a few seconds after power is connected (drives the closed-notch charging activity).
    @Published private(set) var showChargingActivity = false
    @Published private(set) var state = BatteryState.unavailable
    @Published private(set) var isLowPowerMode = false

    var hasBattery: Bool { state.hasBattery }
    var percentage: Int { state.percentage }
    var health: BatteryHealth? { state.health }
    var isCharging: Bool { state.isCharging }
    var isPluggedIn: Bool { state.isPluggedIn }
    var timeToFull: Int? { state.timeToFull }
    var timeToEmpty: Int? { state.timeToEmpty }

    /// How long the charging activity stays visible after plugging in.
    static let chargingActivityDuration: Duration = .seconds(4)

    private let readQueue = DispatchQueue(label: "ARNotch.BatteryMonitor", qos: .utility)
    private var runLoopSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    private var activityResetTask: Task<Void, Never>?
    /// The first reading only establishes a baseline; it never triggers the charging activity.
    private var hasReading = false

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // The source is attached to the main run loop, so the callback arrives on the main thread.
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }

        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BatteryMonitor.shared.updateLowPowerMode() }
        }

        updateLowPowerMode()
        refresh()
    }

    /// Re-reads the battery on a background queue; results are applied on the main queue in order.
    private func refresh() {
        readQueue.async {
            let state = BatteryState.read()
            DispatchQueue.main.async { self.apply(state) }
        }
    }

    private func apply(_ newState: BatteryState) {
        let wasPluggedIn = state.isPluggedIn
        if newState != state { state = newState }

        if hasReading && newState.hasBattery && newState.isPluggedIn && !wasPluggedIn {
            beginChargingActivity()
        } else if !newState.isPluggedIn && showChargingActivity {
            endChargingActivity()
        }
        hasReading = true
    }

    private func updateLowPowerMode() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        if enabled != isLowPowerMode { isLowPowerMode = enabled }
    }

    private func beginChargingActivity() {
        activityResetTask?.cancel()
        showChargingActivity = true
        activityResetTask = Task { [weak self] in
            try? await Task.sleep(for: BatteryMonitor.chargingActivityDuration)
            guard !Task.isCancelled else { return }
            self?.showChargingActivity = false
        }
    }

    private func endChargingActivity() {
        activityResetTask?.cancel()
        activityResetTask = nil
        showChargingActivity = false
    }
}
