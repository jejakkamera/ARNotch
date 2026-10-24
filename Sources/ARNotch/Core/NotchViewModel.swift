import AppKit
import Combine
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case home, shelf, timer, system, connectivity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Nook"
        case .shelf: "Shelf"
        case .timer: "Timer"
        case .system: "System"
        case .connectivity: "Connect"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.full.fill"
        case .timer: "timer"
        case .system: "gauge.with.dots.needle.50percent"
        case .connectivity: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// What the closed notch shows on either side of the hardware cutout.
enum ClosedActivity: Equatable {
    case none, media, charging, timer, pomodoro, blank, ports
}

enum NotchMetrics {
    /// Size of the opened notch, including the header row that sits beside the hardware notch.
    static let openSize = CGSize(width: 660, height: 200)
    /// Width of each "wing" shown beside the closed notch during a live activity.
    static let activityWingWidth: CGFloat = 44
    /// Quiet background servers need only a dot and a small count.
    static let portsWingWidth: CGFloat = 16
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 10
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 24
    /// Size of the transparent panel that hosts the notch; larger than openSize so the shadow is not clipped.
    static let panelSize = CGSize(width: 760, height: 340)
}

@MainActor
final class NotchViewModel: ObservableObject {
    enum Status { case closed, open }

    /// Who is holding the notch open. Each owner releases only its own reason, so one can never drop another's hold.
    enum HoldReason: Hashable {
        case alarm, debug, mirrorRecording, shelfDragOut, shelfMenu, shelfSharing, mirrorPrompt, calendarPrompt, scrub, connectivityPrompt, connectivityVolume
    }

    @Published private(set) var status: Status = .closed
    @Published var tab: NotchTab = .home
    /// Size of the hardware notch in points (or a simulated one on screens without a notch).
    @Published private(set) var notchSize = CGSize(width: 185, height: 32)
    @Published private(set) var hasPhysicalNotch = true
    /// True while a file drag hovers over the notch.
    @Published var isDropTargeted = false
    /// Active holds that stop auto-close (e.g. dragging out of the shelf, a ringing alarm). Cleared by `close()`.
    @Published private(set) var holds = Set<HoldReason>()

    var isOpen: Bool { status == .open }
    var keepOpen: Bool { !holds.isEmpty }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Re-render when module state that changes the closed-notch width changes.
        MediaController.shared.objectWillChange
            .merge(with: BatteryMonitor.shared.objectWillChange, AppSettings.shared.objectWillChange, TimerStore.shared.objectWillChange,
                        DevPortsStore.shared.objectWillChange, DisplayBlanker.shared.objectWillChange,
                        PomodoroStore.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A ringing alarm opens the notch on the Timer tab and keeps it open until stopped or snoozed.
        // No dropFirst(): alarms overdue at launch start ringing inside TimerStore.start().
        TimerStore.shared.$isRinging
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] ringing in self?.alarmRingingChanged(ringing) }
            .store(in: &cancellables)
    }

    private func alarmRingingChanged(_ ringing: Bool) {
        if ringing {
            open(tab: .timer)
            hold(.alarm)
        } else {
            release(.alarm)
        }
    }

    /// Stops auto-close until `release(reason)` or `close()`.
    func hold(_ reason: HoldReason) {
        guard !holds.contains(reason) else { return }
        holds.insert(reason)
    }

    func release(_ reason: HoldReason) {
        guard holds.contains(reason) else { return }
        holds.remove(reason)
    }

    func isHeld(by reason: HoldReason) -> Bool { holds.contains(reason) }

    func updateGeometry(for screen: NSScreen) {
        let geometry = NotchGeometry.notch(for: screen)
        notchSize = geometry.size
        hasPhysicalNotch = geometry.isPhysical
    }

    var closedActivity: ClosedActivity {
        let settings = AppSettings.shared
        if settings.showChargingActivity && BatteryMonitor.shared.showChargingActivity { return .charging }
        if TimerStore.shared.showsLiveActivity { return .timer }
        if PomodoroStore.shared.isActive { return .pomodoro }
        if !DisplayBlanker.shared.blanked.isEmpty { return .blank }
        if settings.showMediaActivity && MediaController.shared.isPlaying { return .media }
        if DevPortsStore.shared.showsLiveActivity { return .ports }
        return .none
    }

    var openSize: CGSize {
        tab == .connectivity ? CGSize(width: 660, height: 280) : NotchMetrics.openSize
    }

    var closedWingWidth: CGFloat {
        switch closedActivity {
        case .none: return 0
        default: return NotchMetrics.activityWingWidth
        }
    }

    /// Size of the black notch shape in the current state.
    var shapeSize: CGSize {
        if isOpen { return openSize }
        let wings = closedWingWidth * 2
        return CGSize(width: notchSize.width + wings, height: notchSize.height)
    }

    func open(tab: NotchTab? = nil) {
        if let tab { self.tab = tab }
        guard status != .open else { return }
        status = .open
        if AppSettings.shared.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    func close() {
        guard status != .closed else { return }
        status = .closed
        if !holds.isEmpty { holds.removeAll() }
        isDropTargeted = false
    }
}

enum NotchGeometry {
    /// Prefer the built-in display with a notch; fall back to the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func notch(for screen: NSScreen) -> (size: CGSize, isPhysical: Bool) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return (CGSize(width: width, height: screen.safeAreaInsets.top), true)
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return (CGSize(width: 185, height: max(menuBarHeight, 24)), false)
    }
}
