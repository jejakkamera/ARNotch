import SwiftUI

/// Calendar widget on the Home tab (170×~130 pt): month, this week's days and the selected day's events.
struct CalendarWidgetView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var store = CalendarStore.shared

    private let selectionAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 14)
                .padding(.bottom, 3)
            CalendarWeekStrip(store: store) { day in
                withAnimation(selectionAnimation) { store.select(day) }
            }
            .padding(.bottom, 4)
            GeometryReader { proxy in
                eventArea(height: proxy.size.height)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { store.widgetAppeared() }
        .onDisappear {
            store.widgetDisappeared()
            vm.release(.calendarPrompt)
        }
        // Keep the notch open while the user answers the calendar prompt outside it, then briefly so the
        // events can be seen arriving.
        .onChange(of: store.isRequestingAccess) { _, requesting in
            let model = vm
            if requesting {
                model.hold(.calendarPrompt)
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    model.release(.calendarPrompt)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                openCalendar()
            } label: {
                Text(store.selectedDay, format: .dateTime.month(.wide))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Calendar")

            Spacer(minLength: 4)

            if store.isTodaySelected {
                Text("Today")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            } else {
                Button {
                    withAnimation(selectionAnimation) { store.select(store.today) }
                } label: {
                    Text("Today")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .frame(height: 14)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(CalendarPressStyle())
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    @ViewBuilder
    private func eventArea(height: CGFloat) -> some View {
        switch store.access {
        case .notDetermined:
            CalendarAccessPrompt(
                symbol: "calendar.badge.plus",
                message: "See your events at a glance",
                buttonTitle: store.isRequestingAccess ? "Waiting…" : "Connect Calendar",
                isBusy: store.isRequestingAccess
            ) { store.requestAccess() }
        case .writeOnly:
            CalendarAccessPrompt(
                symbol: "calendar.badge.exclamationmark",
                message: "ARNotch needs full calendar access",
                buttonTitle: "Open Settings"
            ) { CalendarStore.openPrivacySettings() }
        case .denied:
            CalendarAccessPrompt(
                symbol: "calendar.badge.exclamationmark",
                message: "Calendar access is turned off",
                buttonTitle: "Open Settings"
            ) { CalendarStore.openPrivacySettings() }
        case .granted:
            let events = store.selectedDayEvents
            if !store.hasLoaded {
                Color.clear
            } else if events.isEmpty {
                CalendarEmptyState(isToday: store.isTodaySelected)
                    .transition(.opacity)
            } else {
                CalendarEventList(
                    events: events,
                    day: store.selectedDay,
                    calendar: store.calendar,
                    availableHeight: height,
                    onOpen: { reveal($0) },
                    onMore: { openCalendar() }
                )
                .id(store.selectedDay)
                .transition(.opacity)
            }
        }
    }

    private func openCalendar() {
        CalendarStore.openCalendarApp()
        vm.close()
    }

    private func reveal(_ event: CalendarEvent) {
        CalendarStore.reveal(event)
        vm.close()
    }
}

// MARK: Week strip

private struct CalendarWeekStrip: View {
    @ObservedObject var store: CalendarStore
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(store.weekDays, id: \.self) { day in
                CalendarDayCell(
                    day: day,
                    isToday: day == store.today,
                    isSelected: day == store.selectedDay,
                    isPast: day < store.today,
                    hasEvents: store.daysWithEvents.contains(day)
                ) { onSelect(day) }
            }
        }
    }
}

private struct CalendarDayCell: View {
    let day: Date
    let isToday: Bool
    let isSelected: Bool
    let isPast: Bool
    let hasEvents: Bool
    let action: () -> Void

    @CalendarViewState private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(day, format: .dateTime.weekday(.narrow))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(isToday ? 0.85 : 0.55))
                    .frame(height: 11)
                ZStack {
                    if isToday {
                        Circle().fill(Color.accentColor)
                    } else if isSelected {
                        Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                    } else if isHovering {
                        Circle().fill(Color.white.opacity(0.1))
                    }
                    Text(day, format: .dateTime.day())
                        .font(.system(size: 11, weight: isToday || isSelected ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(numberColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 19, height: 19)
                Circle()
                    .fill(Color.white.opacity(hasEvents ? (isSelected ? 0.75 : 0.4) : 0))
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var numberColor: Color {
        if isToday { return .white }
        return Color.white.opacity(isPast && !isSelected ? 0.45 : 0.9)
    }
}

// MARK: Events

private struct CalendarEventList: View {
    let events: [CalendarEvent]
    let day: Date
    let calendar: Calendar
    let availableHeight: CGFloat
    let onOpen: (CalendarEvent) -> Void
    let onMore: () -> Void

    static let rowHeight: CGFloat = 24
    static let rowSpacing: CGFloat = 2
    static let moreHeight: CGFloat = 11
    static let maxRows = 3

    /// Rows that fit, leaving room for the "+N more" line when not everything fits.
    static func visibleCount(total: Int, height: CGFloat) -> Int {
        let pitch = rowHeight + rowSpacing
        let fitting = max(1, min(maxRows, Int((height + rowSpacing) / pitch)))
        if total <= fitting { return total }
        return max(1, min(maxRows, Int((height - moreHeight) / pitch)))
    }

    var body: some View {
        let shown = Self.visibleCount(total: events.count, height: availableHeight)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let now = Date()

        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(events.prefix(shown)) { event in
                CalendarEventRow(event: event, dayStart: day, dayEnd: dayEnd, now: now) { onOpen(event) }
                    .frame(height: Self.rowHeight)
            }
            if events.count > shown {
                Button(action: onMore) {
                    Text("+\(events.count - shown) more")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.leading, 9)
                        .frame(height: Self.moreHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show all in Calendar")
            }
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let dayStart: Date
    let dayEnd: Date
    let now: Date
    let action: () -> Void

    @CalendarViewState private var isHovering = false

    private var spansWholeDay: Bool {
        event.isAllDay || (event.start <= dayStart && event.end >= dayEnd)
    }

    private var isOngoing: Bool {
        !spansWholeDay && event.start <= now && now < event.end
    }

    private var isPast: Bool { event.end > event.start ? event.end <= now : event.start < now }

    private var timeText: String {
        if spansWholeDay { return "All day" }
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        if isOngoing { return "Now · until \(time(event.end))" }
        if event.start < dayStart { return "Until \(time(event.end))" }
        if event.end > dayEnd { return "From \(time(event.start))" }
        if event.end <= event.start { return time(event.start) }
        return (event.start..<event.end).formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3)
                    .padding(.vertical, 1)
                    .opacity(isPast ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(isPast ? 0.6 : 0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(timeText)
                        .font(.system(size: 9, weight: isOngoing ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(isOngoing ? 0.8 : 0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
                    .padding(.horizontal, -4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("\(event.title) — \(timeText)")
    }
}

// MARK: Empty and permission states

private struct CalendarEmptyState: View {
    let isToday: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Color.white.opacity(0.35))
            Text("No events")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            Text(isToday ? "Enjoy the free time" : "Nothing scheduled")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CalendarAccessPrompt: View {
    let symbol: String
    let message: String
    let buttonTitle: String
    var isBusy = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.5))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.accentColor.opacity(isBusy ? 0.4 : 1)))
            }
            .buttonStyle(CalendarPressStyle())
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The macOS 27 SDK also declares a `State` macro whose plugin ships only with Xcode; this alias
/// names the classic property wrapper directly so the module builds with the Command Line Tools too.
private typealias CalendarViewState = SwiftUI.State

/// Plain button with a subtle press-down effect.
private struct CalendarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
