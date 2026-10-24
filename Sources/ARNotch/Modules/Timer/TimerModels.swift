import Foundation

/// One pending countdown or clock alarm. Times are stored as absolute dates so they stay
/// correct across sleep, clock drift of the run loop and relaunches.
struct TimerItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case countdown, alarm
    }

    let id: UUID
    let kind: Kind
    var label: String
    /// Moment the item fires. Ignored while paused.
    var fireDate: Date
    /// Full span used for the progress ring; grows with "+1 min".
    var totalDuration: TimeInterval
    /// Remaining time frozen when a countdown is paused; nil while running.
    var pausedRemaining: TimeInterval?
    /// For a snooze: title of the item that rang (its label, or e.g. "Alarm 07:30"); nil otherwise.
    var snoozedFrom: String?

    init(kind: Kind, label: String, fireDate: Date, totalDuration: TimeInterval, snoozedFrom: String? = nil) {
        id = UUID()
        self.kind = kind
        self.label = label
        self.fireDate = fireDate
        self.totalDuration = max(totalDuration, 1)
        pausedRemaining = nil
        self.snoozedFrom = snoozedFrom
    }

    var isPaused: Bool { pausedRemaining != nil }

    /// Seconds left at `now` (frozen while paused), never negative.
    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        return max(0, fireDate.timeIntervalSince(now))
    }

    /// Share of the span still to go: 1 just after starting, 0 when due.
    func remainingFraction(at now: Date) -> Double {
        guard totalDuration > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / totalDuration))
    }

    /// "Snoozed · …" for a snooze, else the user's label or a description such as "15 min timer" / "Alarm 07:30".
    var title: String {
        if let snoozedFrom { return "Snoozed · \(snoozedFrom)" }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .countdown: return "\(TimerFormat.duration(totalDuration)) timer"
        case .alarm: return "Alarm \(TimerFormat.timeOfDay(fireDate))"
        }
    }
}

/// An item that went off. Kept while it rings, and afterwards as "missed" if nobody stopped it.
struct FiredTimer: Identifiable, Equatable {
    let item: TimerItem
    /// True when it went off noticeably late (Mac asleep, or Crest was not running).
    let wasLate: Bool

    var id: UUID { item.id }
    /// When the item was due.
    var dueDate: Date { item.fireDate }
}

/// Text formatting shared by the Timer views and notifications.
enum TimerFormat {
    /// Whole seconds shown for a remaining interval. Rounded up, so "0:00" only appears when due;
    /// the small bias absorbs floating-point noise from Date arithmetic.
    static func wholeSeconds(_ interval: TimeInterval) -> Int {
        guard interval.isFinite, interval > 0 else { return 0 }
        return max(0, Int((interval - 0.01).rounded(.up)))
    }

    /// "4:59", "14:59" or "1:05:00".
    static func clock(_ interval: TimeInterval) -> String {
        let total = wholeSeconds(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? "\(hours):\(pad(minutes)):\(pad(seconds))" : "\(minutes):\(pad(seconds))"
    }

    /// Closed-notch wing text: "4:59" / "59:59" under an hour, then hours and minutes ("1:05", "13:05")
    /// with `inHours` set so the view adds an "h" suffix. Minutes round up, like the seconds in `clock`.
    static func compact(_ interval: TimeInterval) -> (text: String, inHours: Bool) {
        let total = wholeSeconds(interval)
        guard total >= 3600 else { return ("\(total / 60):\(pad(total % 60))", false) }
        let minutes = (total + 59) / 60
        return ("\(minutes / 60):\(pad(minutes % 60))", true)
    }

    /// "45 sec", "15 min", "1 h 30 min".
    static func duration(_ interval: TimeInterval) -> String {
        let total = interval.isFinite ? max(0, Int(interval.rounded())) : 0
        if total < 60 { return "\(total) sec" }
        return minutes((total + 30) / 60)
    }

    /// "25 min", "2 h", "1 h 30 min".
    static func minutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Compact time until something: "7h 12m", "45m", "1m".
    static func relative(_ interval: TimeInterval) -> String {
        let minutes = interval.isFinite ? max(1, Int((interval / 60).rounded(.up))) : 1
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Locale-aware wall-clock time, e.g. "07:30" or "7:30 AM".
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// True when the user's locale shows hours as 1–12 with AM/PM.
    static let uses12HourClock: Bool = {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
    }()

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
