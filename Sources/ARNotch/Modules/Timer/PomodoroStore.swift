import AppKit
import SwiftUI
import UserNotifications

/// Pomodoro cycle: focus → short break, and a long break after every fourth focus session.
/// Like TimerStore it keeps an absolute end date (correct across sleep), persists across launches,
/// and runs a 1 s ticker only while a phase is counting down.
@MainActor
final class PomodoroStore: ObservableObject {
    static let shared = PomodoroStore()

    enum Phase: String, Codable {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: "Focus"
            case .shortBreak: "Short Break"
            case .longBreak: "Long Break"
            }
        }

        var symbol: String { self == .focus ? "brain.head.profile" : "cup.and.saucer.fill" }
        var color: Color { self == .focus ? Color(red: 1, green: 0.42, blue: 0.35) : Color(red: 0.45, green: 0.85, blue: 0.6) }
    }

    /// Focus sessions per cycle before the long break.
    static let sessionsPerCycle = 4

    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: Keys.focus) } }
    @Published var shortBreakMinutes: Int { didSet { defaults.set(shortBreakMinutes, forKey: Keys.shortBreak) } }
    @Published var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: Keys.longBreak) } }
    /// Start the next phase automatically when one ends.
    @Published var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: Keys.autoContinue) } }

    @Published private(set) var phase: Phase = .focus
    /// When the running phase ends; nil while idle or paused.
    @Published private(set) var endDate: Date?
    /// Remaining seconds while paused.
    @Published private(set) var pausedRemaining: TimeInterval?
    /// Focus sessions finished in the current cycle (0...3).
    @Published private(set) var completedInCycle = 0
    /// Focus sessions finished today, for a little motivation.
    @Published private(set) var completedToday = 0

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }
    /// Something to show in the closed notch.
    var isActive: Bool { isRunning || isPaused }

    private let defaults = UserDefaults.standard
    private let player = TimerAlertPlayer()
    private var ticker: Timer?
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private enum Keys {
        static let focus = "pomodoro.focusMinutes"
        static let shortBreak = "pomodoro.shortBreakMinutes"
        static let longBreak = "pomodoro.longBreakMinutes"
        static let autoContinue = "pomodoro.autoContinue"
        static let state = "pomodoro.state"
    }

    private struct Saved: Codable {
        var phase: Phase
        var endDate: Date?
        var pausedRemaining: TimeInterval?
        var completedInCycle: Int
        var completedToday: Int
        var day: Date
    }

    private init() {
        defaults.register(defaults: [Keys.focus: 25, Keys.shortBreak: 5, Keys.longBreak: 15, Keys.autoContinue: true])
        focusMinutes = defaults.integer(forKey: Keys.focus)
        shortBreakMinutes = defaults.integer(forKey: Keys.shortBreak)
        longBreakMinutes = defaults.integer(forKey: Keys.longBreak)
        autoContinue = defaults.bool(forKey: Keys.autoContinue)
    }

    // MARK: Lifecycle

    func start() {
        if let data = defaults.data(forKey: Keys.state), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            phase = saved.phase
            endDate = saved.endDate
            pausedRemaining = saved.pausedRemaining
            completedInCycle = saved.completedInCycle
            completedToday = Calendar.current.isDateInToday(saved.day) ? saved.completedToday : 0
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PomodoroStore.shared.tick() }
        }
        // A phase that ended while Crest wasn't running just advances quietly.
        if let endDate, endDate <= Date() { finishPhase(silently: true) }
        updateTicker()
    }

    func minutes(for phase: Phase) -> Int {
        switch phase {
        case .focus: max(1, focusMinutes)
        case .shortBreak: max(1, shortBreakMinutes)
        case .longBreak: max(1, longBreakMinutes)
        }
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return TimeInterval(minutes(for: phase) * 60)
    }

    /// 0...1 of the current phase.
    func progress(at date: Date = Date()) -> Double {
        let total = TimeInterval(minutes(for: phase) * 60)
        return total > 0 ? min(1, max(0, 1 - remaining(at: date) / total)) : 0
    }

    // MARK: Controls

    func startOrResume() {
        if let pausedRemaining {
            endDate = Date().addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
        } else if endDate == nil {
            endDate = Date().addingTimeInterval(TimeInterval(minutes(for: phase) * 60))
            requestNotificationsIfNeeded()
        }
        changed()
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(1, endDate.timeIntervalSinceNow)
        self.endDate = nil
        changed()
    }

    func togglePause() { isRunning ? pause() : startOrResume() }

    /// Ends the current phase now and moves on (without counting a skipped focus session).
    func skip() {
        let wasActive = isActive
        advance(countFocus: false)
        if wasActive && autoContinue { startOrResume() } else { changed() }
    }

    /// Back to a fresh cycle, nothing running.
    func reset() {
        phase = .focus
        endDate = nil
        pausedRemaining = nil
        completedInCycle = 0
        changed()
    }

    // MARK: Internals

    private func tick() {
        guard let endDate else { return }
        if endDate <= Date() { finishPhase(silently: false) } else { objectWillChange.send() }
    }

    private func finishPhase(silently: Bool) {
        let finished = phase
        advance(countFocus: true)
        if !silently {
            player.playOnce(soundName: TimerStore.shared.alarmSoundName)
            notify(finished: finished)
        }
        if autoContinue && !silently { startOrResume() } else { changed() }
    }

    private func advance(countFocus: Bool) {
        endDate = nil
        pausedRemaining = nil
        if phase == .focus {
            if countFocus {
                completedInCycle += 1
                completedToday += 1
            }
            phase = completedInCycle >= Self.sessionsPerCycle ? .longBreak : .shortBreak
        } else {
            if phase == .longBreak { completedInCycle = 0 }
            phase = .focus
        }
    }

    private func changed() {
        save()
        updateTicker()
    }

    private func updateTicker() {
        if isRunning {
            if ticker == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated { PomodoroStore.shared.tick() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                ticker = timer
            }
            // Keep App Nap from delaying the chime; idle sleep stays allowed.
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                                 reason: "ARNotch Pomodoro running")
            }
        } else {
            ticker?.invalidate()
            ticker = nil
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    private func save() {
        let saved = Saved(phase: phase, endDate: endDate, pausedRemaining: pausedRemaining,
                          completedInCycle: completedInCycle, completedToday: completedToday, day: Date())
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Keys.state) }
    }

    // MARK: Notifications

    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationsIfNeeded() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(finished: Phase) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        if finished == .focus {
            content.title = "Focus session done"
            content.body = phase == .longBreak ? "Great work — time for a \(minutes(for: .longBreak))-minute long break."
                                               : "Take a \(minutes(for: .shortBreak))-minute break."
        } else {
            content.title = "Break's over"
            content.body = "Ready for a \(minutes(for: .focus))-minute focus session."
        }
        content.sound = nil
        let request = UNNotificationRequest(identifier: "crest.pomodoro.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
