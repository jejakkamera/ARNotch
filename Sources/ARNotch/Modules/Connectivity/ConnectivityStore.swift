import AppKit
import Combine
import CoreBluetooth
import CoreGraphics

/// Sampling exists only while the Connectivity tab is visible. Audio work and registry reads never
/// block the main thread. Generation checks discard completions after the tab closes.
@MainActor
final class ConnectivityStore: NSObject, ObservableObject, CBCentralManagerDelegate {
    static let shared = ConnectivityStore()

    @Published private(set) var audio: [ConnectedAudio] = []
    @Published private(set) var displays: [ConnectedDisplay] = []
    @Published private(set) var peripherals: [ConnectedPeripheral] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    @Published private(set) var bluetoothStatus = ""
    @Published private(set) var bluetoothAllowed = false
    @Published private(set) var bluetoothEnabled = false
    @Published private(set) var isRequestingBluetooth = false
    /// External display currently being re-arranged (mirror / extend), if any.
    @Published private(set) var arrangingDisplay: UInt32?
    /// False in clamshell mode: there is no built-in panel to mirror onto.
    @Published private(set) var builtInOnline = true
    @Published private var bleReadings: [UUID: BLEBatteryReader.Reading] = [:]

    private let queue = DispatchQueue(label: "ARNotch.Connectivity", qos: .utility)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var central: CBCentralManager?
    private var consumers = 0
    private var generation = 0
    private var inFlight = false
    private var fullScanQueued = false
    private var lastFullScan = Date.distantPast
    private var volumeTasks: [String: Task<Void, Never>] = [:]
    private var messageTask: Task<Void, Never>?
    @Published private var pendingVolumes: [String: Double] = [:]
    private var volumeRevisions: [String: UInt64] = [:]
    private var onBluetoothPromptChanged: ((Bool) -> Void)?
    private let ble = BLEBatteryReader()

    private override init() {
        super.init()
        ble.onChange = { [weak self] in
            guard let self else { return }
            if self.bleReadings != self.ble.readings { self.bleReadings = self.ble.readings }
        }
    }

    var count: Int { audio.count + displays.count + visiblePeripherals.count }

    /// Audio devices with Bluetooth LE battery levels filled in where the registry had none.
    var visibleAudio: [ConnectedAudio] {
        audio.map { device in
            guard device.batteries.isEmpty, let level = bleLevel(named: device.name) else { return device }
            var copy = device
            copy.batteries = [ConnectionBattery(label: "Battery", percent: level)]
            return copy
        }
    }

    /// Peripherals plus Bluetooth LE accessories that only reported a battery level over GATT.
    var visiblePeripherals: [ConnectedPeripheral] {
        var list = peripherals
        for (id, reading) in bleReadings.sorted(by: { $0.value.name < $1.value.name }) {
            let key = Self.normalized(reading.name)
            if let index = list.firstIndex(where: { Self.normalized($0.name) == key }) {
                if list[index].batteries.isEmpty {
                    list[index].batteries = [ConnectionBattery(label: "Battery", percent: reading.percent)]
                }
            } else if !audio.contains(where: { Self.normalized($0.name) == key }) {
                list.append(ConnectedPeripheral(id: "ble-" + id.uuidString, name: reading.name, transport: "Bluetooth",
                                                symbol: Self.symbol(forName: reading.name),
                                                batteries: [ConnectionBattery(label: "Battery", percent: reading.percent)]))
            }
        }
        return list
    }

    private func bleLevel(named name: String) -> Int? {
        let key = Self.normalized(name)
        return bleReadings.values.first { Self.normalized($0.name) == key }?.percent
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func symbol(forName name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mouse") || lower.contains("mx ") { return "computermouse.fill" }
        if lower.contains("keyboard") || lower.contains("keys") { return "keyboard.fill" }
        if lower.contains("controller") || lower.contains("pad") { return "gamecontroller.fill" }
        if lower.contains("pen") || lower.contains("pencil") { return "pencil" }
        return "antenna.radiowaves.left.and.right"
    }

    func appear(onBluetoothPromptChanged: @escaping (Bool) -> Void) {
        consumers += 1
        self.onBluetoothPromptChanged = onBluetoothPromptChanged
        guard consumers == 1 else { return }
        generation += 1
        hasLoaded = false
        configureBluetoothIfPreviouslyAllowed()
        updateDisplays()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateDisplays() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestScan(full: Date().timeIntervalSince(self.lastFullScan) >= 10)
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        requestScan(full: true)
    }

    func disappear() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        generation += 1
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        // An already queued volume write still finishes; a scheduled final slider value is not lost.
        for (uid, value) in pendingVolumes {
            if let device = audio.first(where: { $0.uid == uid }) {
                queue.async { _ = ConnectivityAudio.setVolume(value, on: device) }
            }
        }
        volumeTasks.values.forEach { $0.cancel() }
        volumeTasks.removeAll()
        pendingVolumes.removeAll()
        messageTask?.cancel()
        message = nil
        setRequestingBluetooth(false)
        onBluetoothPromptChanged = nil
        ble.stop(using: central)
        central?.delegate = nil
        central = nil
        isRefreshing = false
        fullScanQueued = false
    }

    func refresh() {
        guard consumers > 0 else { return }
        updateDisplays()
        requestScan(full: true)
    }

    private func requestScan(full: Bool) {
        guard consumers > 0 else { return }
        guard !inFlight else {
            fullScanQueued = fullScanQueued || full
            return
        }
        inFlight = true
        let gen = generation
        let includeBluetooth = bluetoothAllowed && bluetoothEnabled
        if full { isRefreshing = true }
        queue.async {
            let snapshot: ConnectivitySnapshot
            if full { snapshot = ConnectivityScanner.scan(includeBluetooth: includeBluetooth) }
            else { snapshot = ConnectivitySnapshot(audio: ConnectivityAudio.scan()) }
            DispatchQueue.main.async { ConnectivityStore.shared.apply(snapshot, full: full, generation: gen) }
        }
    }

    private func apply(_ snapshot: ConnectivitySnapshot, full: Bool, generation gen: Int) {
        inFlight = false
        guard gen == generation, consumers > 0 else {
            if consumers > 0 { requestScan(full: true) }
            return
        }
        var next = snapshot.audio
        if !full {
            for index in next.indices {
                next[index].batteries = audio.first { $0.uid == next[index].uid }?.batteries ?? []
            }
        }
        if next != audio { audio = next }
        if full {
            if snapshot.peripherals != peripherals { peripherals = snapshot.peripherals }
            if bluetoothEnabled, let central { ble.refreshIfDue(using: central) }
            lastFullScan = Date()
            isRefreshing = false
        }
        hasLoaded = true
        if fullScanQueued {
            fullScanQueued = false
            requestScan(full: true)
        }
    }

    // MARK: Audio actions

    func displayedVolume(_ device: ConnectedAudio) -> Double { pendingVolumes[device.uid] ?? device.volume ?? 0 }

    /// Coalescing keeps slider drags responsive without queueing a write for every mouse event.
    func setVolume(_ value: Double, on device: ConnectedAudio) {
        guard value.isFinite, device.canSetVolume else { return }
        pendingVolumes[device.uid] = min(max(value, 0), 1)
        volumeRevisions[device.uid, default: 0] += 1
        let revision = volumeRevisions[device.uid, default: 0]
        volumeTasks[device.uid]?.cancel()
        volumeTasks[device.uid] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self, let final = self.pendingVolumes[device.uid] else { return }
            self.volumeTasks[device.uid] = nil
            self.perform(on: device, volumeRevision: revision) { ConnectivityAudio.setVolume(final, on: $0) }
        }
    }

    func select(_ device: ConnectedAudio) {
        perform(on: device) { ConnectivityAudio.select($0) }
    }

    func toggleMute(_ device: ConnectedAudio) {
        guard device.canMute, let muted = device.isMuted else { return }
        perform(on: device) { ConnectivityAudio.setMuted(!muted, on: $0) }
    }

    private func perform(on device: ConnectedAudio, volumeRevision: UInt64? = nil, action: @escaping @Sendable (ConnectedAudio) -> Bool) {
        queue.async {
            let success = action(device)
            DispatchQueue.main.async {
                let store = ConnectivityStore.shared
                if let revision = volumeRevision, store.volumeRevisions[device.uid] == revision {
                    store.pendingVolumes[device.uid] = nil
                }
                if !success { store.showMessage("Device unavailable or control not supported. Try refreshing.") }
                store.requestScan(full: false)
            }
        }
    }

    private func showMessage(_ text: String) {
        guard consumers > 0 else { return }
        messageTask?.cancel()
        message = text
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Bluetooth (explicit opt-in, no scanning or pairing)

    func enableBluetooth() {
        switch CBManager.authorization {
        case .denied, .restricted:
            openSettings("Privacy_Bluetooth")
        default:
            UserDefaults.standard.set(true, forKey: "connectivity.includeBluetooth")
            setRequestingBluetooth(CBManager.authorization == .notDetermined)
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    private func configureBluetoothIfPreviouslyAllowed() {
        bluetoothEnabled = false
        bluetoothAllowed = CBManager.authorization == .allowedAlways
        bluetoothStatus = bluetoothAllowed ? "" : "Include Bluetooth"
        if bluetoothAllowed && UserDefaults.standard.bool(forKey: "connectivity.includeBluetooth") {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else {
            bluetoothEnabled = false
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { ble.didConnect(peripheral) }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in self?.bluetoothStateChanged() }
    }

    private func bluetoothStateChanged() {
        guard consumers > 0, let central else { return }
        bluetoothAllowed = CBManager.authorization == .allowedAlways
        bluetoothEnabled = bluetoothAllowed && central.state == .poweredOn
        switch central.state {
        case .poweredOn: bluetoothStatus = "Bluetooth on"
        case .poweredOff: bluetoothStatus = "Bluetooth off"
        case .unauthorized: bluetoothStatus = "Allow Bluetooth"
        case .unsupported: bluetoothStatus = "Bluetooth unavailable"
        default: bluetoothStatus = "Checking Bluetooth…"
        }
        if central.state != .unknown && central.state != .resetting { setRequestingBluetooth(false) }
        requestScan(full: true)
    }

    private func setRequestingBluetooth(_ requesting: Bool) {
        isRequestingBluetooth = requesting
        onBluetoothPromptChanged?(requesting)
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // MARK: Display actions

    /// Shows the built-in screen's picture on `display` too.
    func mirror(_ display: ConnectedDisplay) {
        DisplayBlanker.shared.unblank(display.id)
        arrange(display.id) { DisplayArrangement.mirror(display.id) }
    }

    /// Gives every display its own desktop again.
    func extend(_ display: ConnectedDisplay) {
        arrange(display.id) { DisplayArrangement.extend() }
    }

    func toggleBlank(_ display: ConnectedDisplay) {
        DisplayBlanker.shared.toggle(display.id)
    }

    private func arrange(_ id: UInt32, _ work: @escaping @Sendable () -> Bool) {
        guard arrangingDisplay == nil else { return }
        arrangingDisplay = id
        DispatchQueue.global(qos: .userInitiated).async {
            let success = work()
            DispatchQueue.main.async {
                let store = ConnectivityStore.shared
                store.arrangingDisplay = nil
                store.updateDisplays()
                if !success { store.showMessage("macOS didn't accept the display change. Try again from Displays settings.") }
            }
        }
    }

    private func updateDisplays() {
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { CGGetOnlineDisplayList(UInt32($0.count), $0.baseAddress, &count) }
        guard status == .success else { return }
        let next = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map { id -> ConnectedDisplay in
            let mode = CGDisplayCopyDisplayMode(id)
            let resolution = "\(mode?.pixelWidth ?? CGDisplayPixelsWide(id)) × \(mode?.pixelHeight ?? CGDisplayPixelsHigh(id))"
            let rate = mode?.refreshRate ?? 0
            let detail = resolution + (rate > 0 ? " · \(Int(rate.rounded())) Hz" : "")
            return ConnectedDisplay(id: id, name: names[id] ?? "External display", detail: detail,
                                    isMirrored: CGDisplayIsInMirrorSet(id) != 0, isMain: CGDisplayIsMain(id) != 0)
        }.sorted { $0.id < $1.id }
        if displays != next { displays = next }
        let builtIn = DisplayArrangement.builtInDisplay() != nil
        if builtInOnline != builtIn { builtInOnline = builtIn }
    }
}
