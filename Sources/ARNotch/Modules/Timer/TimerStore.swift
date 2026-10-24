import AppKit
import Combine
import SwiftUI

/// Current time, republished once per second while something is pending. Kept apart from
/// `TimerStore` so the per-second tick only re-renders views that show remaining time.
@MainActor
final class TimerClock: ObservableObject {
    @Published fileprivate(set) var now = Date()
}

/// Countdown timers and clock alarms: scheduling, persistence, ringing and preferences.
///
/// Items keep absolute fire dates. A single run-loop timer ticks once per second, aligned to the
/// soonest item's second boundary, and only exists while something runs or rings. Waking from
/// sleep or a clock change triggers an immediate re-check. While a running item is due within
/// `sleepGuardWindow`, idle system sleep is held off (the display may still sleep).
@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()

    /// Maximum number of pending items.
    static let maxItems = 6
    /// Longest countdown that can be created.
    static let maxCountdown: TimeInterval = 24 * 3600
    /// Ringing stops by itself after this long; the items are then listed as missed.
    static let maxRingDuration: TimeInterval = 60
    /// Longest label kept.
    static let maxLabelLength = 40
    /// Items firing later than this (sleep, app not running) are flagged as late.
    private static let lateThreshold: TimeInterval = 5
    /// Items overdue by more than this (lid closed, app not running) chime once and are listed as
    /// missed instead of ringing and holding the notch open.
    private static let staleThreshold: TimeInterval = 120
    /// A running item due within this window keeps the Mac from idle-sleeping, so the alarm is heard.
    private static let sleepGuardWindow: TimeInterval = 3 * 3600
    /// Items within this much of their fire date count as due (absorbs Date rounding noise).
    private static let fireSlack: TimeInterval = 0.01

    /// Pending items: running ones by fire date, then paused ones by remaining time.
    @Published private(set) var items: [TimerItem] = []
    /// Items ringing right now; they are stopped or snoozed together.
    @Published private(set) var ringing: [FiredTimer] = []
    /// Items that rang unattended until the ring timed out; listed until dismissed.
    @Published private(set) var missed: [FiredTimer] = []
    /// True while at least one countdown/alarm is pending (running or paused).
    @Published private(set) var hasActiveTimer = false
    /// True while an alarm is ringing (the notch opens to the Timer tab and stays open).
    @Published private(set) var isRinging = false
    /// Fire date of the soonest running item; nil when nothing is running.
    @Published private(set) var nextFireDate: Date?

    /// Alarm sound name (file name without extension, see `TimerSounds.available`).
    @Published var alarmSoundName: String {
        didSet { defaults.set(alarmSoundName, forKey: Keys.sound) }
    }
    /// Snooze length in minutes (1–60).
    @Published var snoozeMinutes: Int {
        didSet {
            let clamped = min(max(snoozeMinutes, 1), 60)
            if clamped != snoozeMinutes { snoozeMinutes = clamped }
            defaults.set(clamped, forKey: Keys.snooze)
        }
    }

    /// Per-second clock for remaining-time displays.
    let clock = TimerClock()

    private enum Keys {
        static let items = "timer.items"
        static let sound = "timer.alarmSound"
        static let snooze = "timer.snoozeMinutes"
    }

    private let defaults = UserDefaults.standard
    private let player = TimerAlertPlayer()
    private let notifier = TimerNotifier()
    private var ticker: Timer?
    private var ringDeadline: Date?
    private var activity: NSObjectProtocol?
    /// Whether `activity` also disables idle system sleep.
    private var activityHoldsOffSleep = false
    private var cancellables = Set<AnyCancellable>()
    private var didStart = false

    private init() {
        defaults.register(defaults: [Keys.snooze: 5])
        let storedSound = defaults.string(forKey: Keys.sound)
        alarmSoundName = storedSound.flatMap { TimerSounds.available.contains($0) ? $0 : nil } ?? TimerSounds.defaultName
        snoozeMinutes = min(max(defaults.integer(forKey: Keys.snooze), 1), 60)
    }

    // MARK: Derived state

    /// The item the closed-notch activity shows: the soonest running one, else the first paused one.
    var soonestItem: TimerItem? { items.first }
    /// Whether another item may be created.
    var canAddItem: Bool { items.count < Self.maxItems }
    /// True while missed items wait to be dismissed (derived from the published `missed`).
    var hasMissed: Bool { !missed.isEmpty }
    var missedCount: Int { missed.count }
    /// Convenience for Core: show the timer live activity beside the closed notch.
    var showsLiveActivity: Bool { hasActiveTimer || isRinging || hasMissed }

    // MARK: Lifecycle

    /// Restores persisted timers (recently overdue ones ring right away, long overdue ones are listed as
    /// missed) and starts watching for wake/clock changes.
    func start() {
        guard !didStart else { return }
        didStart = true

        if let data = defaults.data(forKey: Keys.items),
           let restored = try? JSONDecoder().decode([TimerItem].self, from: data) {
            items = restored
        }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        itemsChanged()
        refresh()
    }

    // MARK: Creating

    /// Starts a countdown of `duration` seconds. Returns nil when the item limit is reached.
    @discardableResult
    func startCountdown(duration: TimeInterval, label: String = "") -> TimerItem? {
        guard canAddItem, duration.isFinite else { return nil }
        let seconds = min(max(duration.rounded(), 1), Self.maxCountdown)
        let now = Date()
        let item = TimerItem(kind: .countdown, label: Self.clean(label), fireDate: now.addingTimeInterval(seconds), totalDuration: seconds)
        add(item, now: now)
        return item
    }

    /// Sets an alarm for the next occurrence of `hour`:`minute` (today, or tomorrow if already past).
    /// Returns nil when the item limit is reached.
    @discardableResult
    func startAlarm(hour: Int, minute: Int, label: String = "") -> TimerItem? {
        let now = Date()
        guard canAddItem, let fireDate = Self.nextAlarmDate(hour: hour, minute: minute, after: now) else { return nil }
        let item = TimerItem(kind: .alarm, label: Self.clean(label), fireDate: fireDate, totalDuration: fireDate.timeIntervalSince(now))
        add(item, now: now)
        return item
    }

    /// Next moment strictly after `date` whose wall-clock time is `hour`:`minute`:00.
    static func nextAlarmDate(hour: Int, minute: Int, after date: Date = Date()) -> Date? {
        var components = DateComponents()
        components.hour = min(max(hour, 0), 23)
        components.minute = min(max(minute, 0), 59)
        components.second = 0
        return Calendar.current.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    // MARK: Editing

    func togglePause(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.isPaused { resume(id) } else { pause(id) }
    }

    /// Freezes a running countdown. Alarms cannot be paused.
    func pause(_ id: UUID) {
        let now = Date()
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].kind == .countdown, !items[index].isPaused else { return }
        let remaining = items[index].fireDate.timeIntervalSince(now)
        guard remaining > Self.fireSlack else {
            refresh()
            return
        }
        items[index].pausedRemaining = remaining
        clock.now = now
        itemsChanged()
    }

    func resume(_ id: UUID) {
        let now = Date()
        guard let index = items.firstIndex(where: { $0.id == id }),
              let remaining = items[index].pausedRemaining else { return }
        items[index].fireDate = now.addingTimeInterval(remaining)
        items[index].pausedRemaining = nil
        clock.now = now
        itemsChanged()
    }

    /// Pushes an item back (the "+1 min" button). Works for paused countdowns and alarms too.
    func extend(_ id: UUID, by seconds: TimeInterval = 60) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let remaining = items[index].pausedRemaining {
            items[index].pausedRemaining = min(remaining + seconds, Self.maxCountdown)
        } else {
            items[index].fireDate = items[index].fireDate.addingTimeInterval(seconds)
        }
        items[index].totalDuration += seconds
        clock.now = Date()
        itemsChanged()
    }

    func cancel(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        clock.now = Date()
        itemsChanged()
    }

    func dismissAllMissed() {
        if !missed.isEmpty { missed.removeAll() }
    }

    // MARK: Ringing

    /// Stops the alarm and dismisses every ringing item.
    func stopRinging() {
        guard isRinging || !ringing.isEmpty else { return }
        player.stopRinging()
        notifier.removeDelivered()
        ringing.removeAll()
        ringDeadline = nil
        isRinging = false
        updateTicker()
    }

    /// Stops the alarm and re-schedules every ringing item as a countdown of `snoozeMinutes`, titled
    /// "Snoozed · <label or original title>". Only the user's own label is carried over.
    func snoozeRinging() {
        guard !ringing.isEmpty else { return }
        let now = Date()
        let length = TimeInterval(snoozeMinutes * 60)
        let snoozed = ringing.map {
            TimerItem(
                kind: .countdown,
                label: $0.item.label,
                fireDate: now.addingTimeInterval(length),
                totalDuration: length,
                snoozedFrom: $0.item.snoozedFrom ?? $0.item.title
            )
        }
        stopRinging()
        items.append(contentsOf: snoozed)
        clock.now = now
        itemsChanged()
    }

    /// Plays the selected alarm sound once (Settings preview). Ignored while ringing.
    func previewAlarmSound() {
        guard !isRinging else { return }
        player.playOnce(soundName: alarmSoundName)
    }

    // MARK: Internals

    private func add(_ item: TimerItem, now: Date) {
        // Make sure persisted items are loaded before the list is saved over.
        if !didStart { start() }
        notifier.requestAuthorizationIfNeeded()
        items.append(item)
        clock.now = now
        itemsChanged()
    }

    private static func clean(_ label: String) -> String {
        String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLabelLength))
    }

    /// Re-sorts, saves, updates the published summary and re-aligns the ticker.
    private func itemsChanged() {
        items.sort(by: Self.isOrderedBefore)
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Keys.items)
        }
        let active = !items.isEmpty
        if hasActiveTimer != active { hasActiveTimer = active }
        let next = items.lazy.filter { !$0.isPaused }.map(\.fireDate).min()
        if nextFireDate != next { nextFireDate = next }
        updateTicker()
    }

    private static func isOrderedBefore(_ lhs: TimerItem, _ rhs: TimerItem) -> Bool {
        switch (lhs.pausedRemaining, rhs.pausedRemaining) {
        case (nil, nil): return lhs.fireDate < rhs.fireDate
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(left), .some(right)): return left < right
        }
    }

    /// Immediate re-check (launch, wake, clock change), then re-align the ticker.
    private func refresh() {
        tick()
        updateTicker()
    }

    private func tick() {
        let now = Date()
        clock.now = now
        fireDueItems(now: now)
        if let ringDeadline, now >= ringDeadline {
            ringTimedOut()
        }
        // Picks up an item entering the sleep-guard window as time passes.
        updateActivity(now: now)
    }

    private func fireDueItems(now: Date) {
        let due = items.filter { !$0.isPaused && $0.fireDate.timeIntervalSince(now) <= Self.fireSlack }
        guard !due.isEmpty else { return }
        let dueIDs = Set(due.map(\.id))
        items.removeAll { dueIDs.contains($0.id) }

        let fired = due.map { FiredTimer(item: $0, wasLate: now.timeIntervalSince($0.fireDate) > Self.lateThreshold) }
        // Long overdue (lid was closed, Crest not running): a single chime and a missed entry, no ringing.
        let stale = fired.filter { now.timeIntervalSince($0.dueDate) > Self.staleThreshold }
        let fresh = fired.filter { now.timeIntervalSince($0.dueDate) <= Self.staleThreshold }
        if !stale.isEmpty {
            addMissed(stale)
            notifier.post(stale, missed: true)
            if fresh.isEmpty && !isRinging { player.playOnce(soundName: alarmSoundName) }
        }
        if !fresh.isEmpty {
            ringing.append(contentsOf: fresh)
            // Every newly fired item gets the full ring time.
            ringDeadline = now.addingTimeInterval(Self.maxRingDuration)
            if !isRinging { isRinging = true }
            player.startRinging(soundName: alarmSoundName)
            notifier.post(fresh)
        }
        itemsChanged()
    }

    /// Lists items as missed, keeping only the most recent `maxItems`.
    private func addMissed(_ fired: [FiredTimer]) {
        missed.append(contentsOf: fired)
        if missed.count > Self.maxItems {
            missed.removeFirst(missed.count - Self.maxItems)
        }
    }

    /// Nobody reacted: stop the sound and keep the items as missed.
    private func ringTimedOut() {
        addMissed(ringing)
        player.stopRinging()
        notifier.forgetDelivered()
        ringing.removeAll()
        ringDeadline = nil
        isRinging = false
        updateTicker()
    }

    /// Runs the 1 s ticker only while something runs or rings. The first fire is aligned so ticks land
    /// right on the soonest item's second boundaries, which makes it fire on time and display exactly.
    private func updateTicker() {
        let runningDates = items.lazy.filter { !$0.isPaused }.map(\.fireDate)
        let now = Date()
        updateActivity(now: now)
        guard !runningDates.isEmpty || isRinging else {
            ticker?.invalidate()
            ticker = nil
            return
        }

        var firstFire = now.addingTimeInterval(1)
        if let soonest = runningDates.min() {
            let remaining = soonest.timeIntervalSince(now)
            if remaining <= 0 {
                firstFire = now
            } else {
                var offset = remaining - remaining.rounded(.down)
                if offset < 0.02 { offset += 1 }
                firstFire = now.addingTimeInterval(offset)
            }
        }

        ticker?.invalidate()
        let timer = Timer(fire: firstFire, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Keeps App Nap from coalescing the ticker while something runs or rings. While ringing, or while
    /// a running item is due within `sleepGuardWindow`, idle system sleep is disabled too (display
    /// sleep stays allowed; closing the lid still sleeps the Mac). Cheap when nothing changes.
    private func updateActivity(now: Date) {
        let next = nextFireDate
        guard next != nil || isRinging else {
            endActivity()
            return
        }
        let holdOffSleep = isRinging || (next.map { $0.timeIntervalSince(now) <= Self.sleepGuardWindow } ?? false)
        if activity != nil, activityHoldsOffSleep == holdOffSleep { return }
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
            options: holdOffSleep ? [.userInitiated] : [.userInitiatedAllowingIdleSystemSleep],
            reason: holdOffSleep ? "ARNotch timer or alarm due soon" : "ARNotch timer or alarm pending"
        )
        activityHoldsOffSleep = holdOffSleep
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        activityHoldsOffSleep = false
    }
}
