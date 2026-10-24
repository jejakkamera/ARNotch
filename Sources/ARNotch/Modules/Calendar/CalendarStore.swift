import AppKit
import Combine
import EventKit
import SwiftUI

/// One event occurrence, copied out of EventKit so it can safely cross threads.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var red: Double, green: Double, blue: Double
    }

    /// Unique per occurrence; recurring events share `itemIdentifier`.
    let id: String
    /// EventKit `calendarItemIdentifier`, used to reveal the event in Calendar.
    let itemIdentifier: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Part of a repeating series, so `itemIdentifier` alone does not pick this occurrence.
    let isRecurring: Bool
    let rgb: RGB

    var color: Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue) }

    /// True if the event touches the half-open interval [dayStart, dayEnd).
    func overlaps(dayStart: Date, dayEnd: Date) -> Bool {
        if end <= start { return start >= dayStart && start < dayEnd }
        return start < dayEnd && end > dayStart
    }

    /// All-day events first, then by start time, then by title.
    static func displayOrder(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

extension CalendarEvent {
    /// Must be called on the queue that fetched `event`.
    fileprivate init?(_ event: EKEvent) {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let trimmed = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = event.calendarItemIdentifier
        self.id = "\(identifier)|\(start.timeIntervalSinceReferenceDate)"
        self.itemIdentifier = identifier
        self.title = trimmed.isEmpty ? "New Event" : trimmed
        self.start = start
        self.end = end
        self.isAllDay = event.isAllDay
        self.isRecurring = event.hasRecurrenceRules
        if let color = event.calendar?.color?.usingColorSpace(.sRGB) {
            self.rgb = RGB(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
        } else {
            self.rgb = RGB(red: 0.04, green: 0.52, blue: 1.0)
        }
    }
}

/// Owns the EKEventStore; every EventKit call runs on its private serial queue.
final class CalendarEventFetcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.crest.calendar", qos: .userInitiated)
    /// Confined to `queue`. Created lazily so nothing touches EventKit until it is needed.
    private var store: EKEventStore?

    private func currentStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    /// Drops the current store; one created before access was granted can stay empty.
    func resetStore() {
        queue.async { self.store = nil }
    }

    func requestFullAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.currentStore().requestFullAccessToEvents { granted, _ in
                    self.queue.async {
                        if granted { self.store = nil }
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    /// Events from every calendar overlapping [start, end), in display order.
    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        await withCheckedContinuation { continuation in
            queue.async {
                let store = self.currentStore()
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let events = store.events(matching: predicate)
                    .compactMap(CalendarEvent.init)
                    .sorted(by: CalendarEvent.displayOrder)
                continuation.resume(returning: events)
            }
        }
    }
}

/// Calendar access state plus the current week's events. Loads lazily and only refreshes while a widget is visible.
@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    enum Access: Equatable {
        case notDetermined, granted, writeOnly, denied
    }

    @Published private(set) var access: Access
    /// Start of the current day.
    @Published private(set) var today: Date
    /// Start of each day of the week containing `today`, in locale order.
    @Published private(set) var weekDays: [Date]
    /// Start of the day whose events are listed.
    @Published private(set) var selectedDay: Date
    @Published private(set) var weekEvents: [CalendarEvent] = []
    /// Start-of-day dates in this week that have at least one event.
    @Published private(set) var daysWithEvents: Set<Date> = []
    /// False until the first fetch after access was granted completes.
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRequestingAccess = false

    let calendar = Calendar.autoupdatingCurrent

    private let fetcher = CalendarEventFetcher()
    private var visibleWidgets = 0
    private var isStale = true
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        self.today = today
        self.selectedDay = today
        self.weekDays = Self.week(containing: today, calendar: calendar)
        self.access = Self.currentAccess()

        let center = NotificationCenter.default
        center.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.eventsChanged() }
            .store(in: &cancellables)
        center.publisher(for: .NSCalendarDayChanged)
            .merge(with: center.publisher(for: .NSSystemTimeZoneDidChange),
                   center.publisher(for: .NSSystemClockDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateToday() }
            .store(in: &cancellables)
    }

    var isTodaySelected: Bool { selectedDay == today }

    var selectedDayEvents: [CalendarEvent] { events(on: selectedDay) }

    func events(on day: Date) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return weekEvents.filter { $0.overlaps(dayStart: start, dayEnd: end) }
    }

    func select(_ day: Date) {
        selectedDay = calendar.startOfDay(for: day)
    }

    /// Widgets call this from onAppear: re-checks access and the date, jumps back to today
    /// when the widget was hidden, and refreshes stale data.
    func widgetAppeared() {
        let wasHidden = visibleWidgets == 0
        visibleWidgets += 1
        refreshAccess()
        updateToday()
        if wasHidden { selectedDay = today }
        if isStale { refresh() }
    }

    func widgetDisappeared() {
        visibleWidgets = max(0, visibleWidgets - 1)
    }

    /// Shows the system prompt. Only call from a user action, never automatically.
    func requestAccess() {
        guard access == .notDetermined, !isRequestingAccess else { return }
        isRequestingAccess = true
        Task {
            _ = await fetcher.requestFullAccess()
            isRequestingAccess = false
            refreshAccess()
            refresh()
        }
    }

    /// Re-fetches this week's events off the main thread.
    func refresh() {
        guard access == .granted,
              let start = weekDays.first,
              let end = calendar.date(byAdding: .day, value: weekDays.count, to: start) else { return }
        isStale = false
        generation += 1
        let token = generation
        Task {
            let events = await fetcher.events(from: start, to: end)
            guard token == generation else { return }
            if events != weekEvents { weekEvents = events }
            updateDaysWithEvents()
            hasLoaded = true
        }
    }

    /// Rebuilt after every fetch and week change, not only when the events differ: `weekDays` can
    /// move (e.g. a time-zone change shifts every midnight) while the fetched events stay equal.
    private func updateDaysWithEvents() {
        let days = Set(weekDays.filter { day in
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            return weekEvents.contains { $0.overlaps(dayStart: day, dayEnd: next) }
        })
        if days != daysWithEvents { daysWithEvents = days }
    }

    private func eventsChanged() {
        isStale = true
        if visibleWidgets > 0 { refresh() }
    }

    private func refreshAccess() {
        let current = Self.currentAccess()
        guard current != access else { return }
        access = current
        isStale = true
        if current == .granted {
            fetcher.resetStore()
        } else {
            generation += 1
            weekEvents = []
            daysWithEvents = []
            hasLoaded = false
        }
    }

    private func updateToday() {
        let newToday = calendar.startOfDay(for: Date())
        guard newToday != today else { return }
        let followsToday = selectedDay == today
        today = newToday
        let week = Self.week(containing: newToday, calendar: calendar)
        if week != weekDays {
            weekDays = week
            isStale = true
            // Drop any in-flight fetch for the old range; dots follow the new days right away.
            generation += 1
            updateDaysWithEvents()
        }
        if followsToday || !weekDays.contains(selectedDay) {
            selectedDay = newToday
        }
        if isStale && visibleWidgets > 0 { refresh() }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    private static func week(containing day: Date, calendar: Calendar) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: Opening other apps

    static let calendarBundleID = "com.apple.iCal"

    static func openCalendarApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: calendarBundleID) else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows the event in Calendar, falling back to just opening the app.
    static func reveal(_ event: CalendarEvent) {
        if let url = showURL(for: event), NSWorkspace.shared.open(url) { return }
        openCalendarApp()
    }

    /// Compact UTC timestamp, e.g. `20261014T090000Z`.
    private static let occurrenceStyle = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted,
        timeZone: .gmt
    )

    /// `ical://ekevent/<id>`. Every occurrence of a repeating event shares one identifier, so those
    /// get the occurrence's start in front of it; otherwise Calendar would show the series' first one.
    private static func showURL(for event: CalendarEvent) -> URL? {
        guard let id = event.itemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let path = event.isRecurring ? "\(event.start.formatted(occurrenceStyle))/\(id)" : id
        return URL(string: "ical://ekevent/\(path)?method=show&options=more")
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
