import AppKit
import SwiftUI

/// Content of the Timer tab (~600×135 pt): a creation panel on the left, running items on the right.
/// While something rings, the whole tab becomes the ringing screen.
struct TimerTabView: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        ZStack {
            if store.isRinging {
                TimerRingingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                HStack(spacing: 14) {
                    TimerComposerView()
                        .frame(width: 272)
                    Divider().overlay(Color.white.opacity(0.12))
                    TimerListView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.isRinging)
    }
}

// MARK: Composer

private enum TimerComposerMode: String, CaseIterable, Identifiable {
    case timer, alarm, pomodoro
    var id: String { rawValue }

    var title: String {
        switch self {
        case .timer: "Timer"
        case .alarm: "Alarm"
        case .pomodoro: "Pomodoro"
        }
    }

    var symbol: String {
        switch self {
        case .timer: "timer"
        case .alarm: "alarm"
        case .pomodoro: "brain.head.profile"
        }
    }
}

/// Left side: Timer/Alarm switch, presets or time picker, label field and start button.
/// Everything works with the mouse alone; typing a label is optional.
private struct TimerComposerView: View {
    @ObservedObject private var store = TimerStore.shared
    @AppStorage("timer.composerMode") private var mode: TimerComposerMode = .timer
    @AppStorage("timer.customMinutes") private var customMinutes = 25
    @AppStorage("timer.alarmHour") private var alarmHour = 7
    @AppStorage("timer.alarmMinute") private var alarmMinute = 0
    /// Plain `State` rather than `@State`: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
    private let labelState = State(initialValue: "")
    private var label: String { labelState.wrappedValue }
    /// Last preset started and when, so a double-click does not start it twice.
    private let lastPresetState = State(initialValue: (minutes: 0, date: Date.distantPast))

    private static let presets = [1, 5, 10, 15, 30, 60]
    /// Repeat clicks on the same preset within this interval are ignored.
    private static let presetDebounce: TimeInterval = 0.6

    private var minutes: Int { min(max(customMinutes, 1), 1440) }
    private var hour: Int { min(max(alarmHour, 0), 23) }
    private var minute: Int { min(max(alarmMinute, 0), 59) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                modePicker
                Spacer(minLength: 4)
                // Only worth showing when the limit is getting close.
                if store.items.count >= 4 {
                    Text(verbatim: "\(store.items.count) of \(TimerStore.maxItems)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(store.canAddItem ? Color.white.opacity(0.6) : Color.orange)
                        .help("Active timers and alarms (maximum \(TimerStore.maxItems))")
                }
            }

            if mode == .pomodoro {
                PomodoroComposerView()
                Spacer(minLength: 0)
            } else {
                switch mode {
                case .alarm: alarmSection
                default: presetSection
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if mode == .timer { minuteStepper }
                    labelField
                    startButton
                }
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(TimerComposerMode.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { mode = item }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(mode == item ? Color.white.opacity(0.18) : Color.clear))
                        .foregroundStyle(mode == item ? Color.white : Color.white.opacity(0.55))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    // Timer mode

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        startPreset(preset)
                    } label: {
                        VStack(spacing: 0) {
                            Text(verbatim: preset >= 60 ? "\(preset / 60)" : "\(preset)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(preset >= 60 ? "hour" : "min")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                    }
                    .buttonStyle(TimerPillStyle())
                    .disabled(!store.canAddItem)
                    .help("Start a \(TimerFormat.minutes(preset)) timer")
                }
            }
            Text(store.canAddItem ? "Click a preset, or set a custom length below" : "Limit reached — cancel one to add more")
                .font(.system(size: 10))
                .foregroundStyle(store.canAddItem ? Color.white.opacity(0.55) : Color.orange)
                .lineLimit(1)
        }
    }

    private var minuteStepper: some View {
        HStack(spacing: 0) {
            stepButton("minus", help: "Shorter") { customMinutes = Self.steppedMinutes(minutes, up: false) }
            Text(verbatim: TimerFormat.relative(TimeInterval(minutes * 60)))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 50)
            stepButton("plus", help: "Longer") { customMinutes = Self.steppedMinutes(minutes, up: true) }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func stepButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 26)
        }
        .buttonStyle(TimerPillStyle(fill: .clear, hoverFill: Color.white.opacity(0.12), foreground: Color.white.opacity(0.8)))
        .buttonRepeatBehavior(.enabled)
        .help(help)
    }

    /// 1-minute steps below 10, 5-minute steps up to an hour, then 15-minute steps (max 24 h).
    private static func steppedMinutes(_ value: Int, up: Bool) -> Int {
        let current = min(max(value, 1), 1440)
        let next: Int
        if up {
            next = current < 10 ? current + 1 : current < 60 ? (current / 5 + 1) * 5 : (current / 15 + 1) * 15
        } else {
            next = current <= 10 ? current - 1 : current <= 60 ? ((current - 1) / 5) * 5 : ((current - 1) / 15) * 15
        }
        return min(max(next, 1), 1440)
    }

    // Alarm mode

    private var alarmSection: some View {
        HStack(spacing: 6) {
            TimerDigitColumn(
                text: hourText,
                help: "Change the hour",
                up: { alarmHour = (hour + 1) % 24 },
                down: { alarmHour = (hour + 23) % 24 }
            )
            Text(verbatim: ":")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
            TimerDigitColumn(
                text: minute < 10 ? "0\(minute)" : "\(minute)",
                help: "Change by 5 minutes (Option-click for 1 minute)",
                up: { alarmMinute = Self.steppedAlarmMinute(minute, up: true) },
                down: { alarmMinute = Self.steppedAlarmMinute(minute, up: false) }
            )
            if TimerFormat.uses12HourClock {
                Button {
                    alarmHour = (hour + 12) % 24
                } label: {
                    Text(hour < 12 ? Calendar.current.amSymbol : Calendar.current.pmSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.92)
                        .frame(width: 34, height: 26)
                }
                .buttonStyle(TimerPillStyle())
                .help("Switch AM/PM")
            }
            alarmPreview
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Moves to the next/previous multiple of 5, or by 1 while Option is held; wraps within the hour.
    private static func steppedAlarmMinute(_ value: Int, up: Bool) -> Int {
        let step = NSEvent.modifierFlags.contains(.option) ? 1 : 5
        let next: Int
        if up {
            next = (value / step + 1) * step
        } else {
            next = value % step == 0 ? value - step : (value / step) * step
        }
        return (next % 60 + 60) % 60
    }

    private var hourText: String {
        if TimerFormat.uses12HourClock {
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return "\(twelve)"
        }
        return hour < 10 ? "0\(hour)" : "\(hour)"
    }

    private var alarmPreview: some View {
        TimelineView(.everyMinute) { _ in
            let next = TimerStore.nextAlarmDate(hour: hour, minute: minute)
            VStack(alignment: .leading, spacing: 2) {
                Text(next.map(Self.dayAndTime) ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(next.map { "in \(TimerFormat.relative($0.timeIntervalSinceNow))" } ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.orange)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.92)
        }
    }

    private static func dayAndTime(_ date: Date) -> String {
        let day = Calendar.current.isDateInToday(date) ? "Today" : "Tomorrow"
        return "\(day) \(TimerFormat.timeOfDay(date))"
    }

    // Shared bottom row

    private var labelField: some View {
        TextField("Label", text: labelState.projectedValue)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(minWidth: 50, maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .onSubmit { start() }
            .help("Optional label")
    }

    private var startButton: some View {
        Button {
            start()
        } label: {
            Label(mode == .timer ? "Start" : "Set Alarm", systemImage: mode == .timer ? "play.fill" : "alarm.fill")
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 26)
        }
        .buttonStyle(TimerPillStyle(fill: .orange, hoverFill: Color.orange.opacity(0.85), foreground: .black))
        .disabled(!store.canAddItem)
        .help(mode == .timer ? "Start a \(TimerFormat.minutes(minutes)) timer" : "Set the alarm")
    }

    /// Starts the custom timer or the alarm. At the item limit it beeps and keeps the typed label.
    private func start() {
        guard store.canAddItem else {
            NSSound.beep()
            return
        }
        let started: TimerItem?
        switch mode {
        case .timer:
            started = store.startCountdown(duration: TimeInterval(minutes * 60), label: label)
        case .alarm:
            started = store.startAlarm(hour: hour, minute: minute, label: label)
        case .pomodoro:
            return // Pomodoro has its own start button.
        }
        if started != nil { labelState.wrappedValue = "" }
    }

    /// Starts a preset countdown with the typed label; a quick repeat of the same preset is ignored.
    private func startPreset(_ preset: Int) {
        let now = Date()
        let last = lastPresetState.wrappedValue
        guard last.minutes != preset || now.timeIntervalSince(last.date) >= Self.presetDebounce else { return }
        guard store.canAddItem else {
            NSSound.beep()
            return
        }
        if store.startCountdown(duration: TimeInterval(preset * 60), label: label) != nil {
            lastPresetState.wrappedValue = (minutes: preset, date: now)
            labelState.wrappedValue = ""
        }
    }
}

/// Two-digit value with up/down chevrons; hold a chevron to repeat.
private struct TimerDigitColumn: View {
    let text: String
    let help: String
    let up: () -> Void
    let down: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            chevron("chevron.up", action: up)
            Text(verbatim: text)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 40, height: 26)
            chevron("chevron.down", action: down)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func chevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 40, height: 15)
        }
        .buttonStyle(TimerPillStyle(fill: .clear, hoverFill: Color.white.opacity(0.12), foreground: Color.white.opacity(0.7), cornerRadius: 6))
        .buttonRepeatBehavior(.enabled)
        .help(help)
    }
}

// MARK: Active list

/// Right side: pending items, then one row for everything missed (scrolls when there are more than two rows).
private struct TimerListView: View {
    @ObservedObject private var store = TimerStore.shared

    private var rowCount: Int { store.items.count + (store.hasMissed ? 1 : 0) }

    var body: some View {
        Group {
            if rowCount == 0 {
                VStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.3))
                    Text("No timers running")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text("Pick a preset or set an alarm")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(store.items) { item in
                            TimerItemRow(item: item)
                        }
                        if store.hasMissed {
                            TimerMissedRow(missed: store.missed)
                        }
                    }
                }
                .scrollIndicators(rowCount > 2 ? .automatic : .never)
                .scrollDisabled(rowCount <= 2)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.items.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.missed.map(\.id))
    }
}

private struct TimerItemRow: View {
    let item: TimerItem
    @ObservedObject private var store = TimerStore.shared
    @ObservedObject private var clock = TimerStore.shared.clock

    var body: some View {
        let remaining = item.remaining(at: clock.now)
        HStack(spacing: 10) {
            TimerProgressRing(
                fraction: item.remainingFraction(at: clock.now),
                symbol: item.isPaused ? "pause.fill" : (item.kind == .alarm ? "alarm.fill" : "timer"),
                dimmed: item.isPaused
            )
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: TimerFormat.clock(remaining))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.isPaused ? Color.white.opacity(0.55) : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // No per-tick animation: animating every second kept the hosting view rendering a quarter
                    // of the time. Digits roll only when a change arrives in an animated transaction.
                    .contentTransition(.numericText(countsDown: true))
                TimerSubtitle(lead: subtitle.lead, time: subtitle.time)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if item.kind == .countdown {
                    TimerIconButton(symbol: item.isPaused ? "play.fill" : "pause.fill", help: item.isPaused ? "Resume" : "Pause") {
                        store.togglePause(item.id)
                    }
                }
                Button {
                    store.extend(item.id)
                } label: {
                    Text(verbatim: "+1m")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .frame(width: 30, height: 24)
                }
                .buttonStyle(TimerPillStyle(cornerRadius: 12))
                .help("Add 1 minute")
                TimerIconButton(symbol: "xmark", help: "Cancel") {
                    store.cancel(item.id)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(TimerFormat.clock(remaining)) left")
    }

    /// Label part (may truncate) and time part (always shown), e.g. ("Tea", " · ends 07:45").
    private var subtitle: (lead: String, time: String) {
        let time = TimerFormat.timeOfDay(item.fireDate)
        switch item.kind {
        case .alarm:
            let day = Calendar.current.isDateInTomorrow(item.fireDate) ? " tomorrow" : ""
            let trimmed = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? ("Alarm", " \(time)\(day)") : (trimmed, " · \(time)\(day)")
        case .countdown:
            return (item.title, item.isPaused ? " · paused" : " · ends \(time)")
        }
    }
}

/// One-line row subtitle: a label that truncates first, then a time that never does.
private struct TimerSubtitle: View {
    let lead: String
    let time: String

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: lead)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: time)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.55))
    }
}

/// All missed items collapsed into one row, with a Clear button.
private struct TimerMissedRow: View {
    let missed: [FiredTimer]
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.orange.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: missed.count == 1 ? "Missed" : "\(missed.count) missed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange)
                TimerSubtitle(lead: missed.map(\.item.title).joined(separator: ", "), time: dueText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.dismissAllMissed()
            } label: {
                Text("Clear")
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 24)
            }
            .buttonStyle(TimerPillStyle(cornerRadius: 12))
            .help(missed.count == 1 ? "Dismiss" : "Dismiss all missed")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        )
    }

    /// " · due 07:30" for one item, " · since 07:30" (the earliest) for several.
    private var dueText: String {
        guard let earliest = missed.map(\.dueDate).min() else { return "" }
        let time = TimerFormat.timeOfDay(earliest)
        return missed.count == 1 ? " · due \(time)" : " · since \(time)"
    }
}

/// Thin ring showing the remaining share, with the item's glyph inside. The ring eases over each 1 s tick in
/// Core Animation, so a running countdown doesn't re-render the notch every frame.
private struct TimerProgressRing: View {
    let fraction: Double
    let symbol: String
    let dimmed: Bool

    var body: some View {
        ZStack {
            LayerProgressRing(fraction: fraction, color: Color.orange.opacity(dimmed ? 0.45 : 1),
                              trackColor: Color.white.opacity(0.12), lineWidth: 3)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange.opacity(dimmed ? 0.5 : 1))
        }
    }
}

private struct TimerIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(TimerPillStyle(cornerRadius: 12))
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Ringing

/// Replaces the tab while something rings: pulsing bell, what finished, Stop and Snooze.
private struct TimerRingingView: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                // Grows while it fades, like a ripple (in Core Animation: no per-frame work).
                LayerPulsingDot(color: Color.orange.opacity(0.2),
                                pulse: LayerPulse(endOpacity: 0.45, startScale: 0.82, endScale: 1, period: 1.4))
                TimerBellGlyph(size: 34)
            }
            .frame(width: 78, height: 78)

            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: detail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let note {
                    Text(verbatim: note)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                Button {
                    store.stopRinging()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 150, height: 42)
                }
                .buttonStyle(TimerPillStyle(fill: .orange, hoverFill: Color.orange.opacity(0.85), foreground: .black, cornerRadius: 21))
                .keyboardShortcut(.defaultAction)

                Button {
                    store.snoozeRinging()
                } label: {
                    Label("Snooze \(store.snoozeMinutes) min", systemImage: "zzz")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: 150, height: 32)
                }
                .buttonStyle(TimerPillStyle(fill: Color.white.opacity(0.14), hoverFill: Color.white.opacity(0.22), cornerRadius: 16))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        let allLate = !store.ringing.isEmpty && store.ringing.allSatisfy(\.wasLate)
        return allLate ? "Missed while away" : "Time's up!"
    }

    private var detail: String {
        let titles = store.ringing.map(\.item.title)
        if titles.count <= 1 { return titles.first ?? "" }
        return "\(titles.count) finished: " + titles.joined(separator: ", ")
    }

    private var note: String? {
        guard let late = store.ringing.filter(\.wasLate).map(\.dueDate).min() else { return nil }
        return "Was due at \(TimerFormat.timeOfDay(late))"
    }
}

// MARK: Button style

/// Rounded fill that brightens on hover and dims when disabled.
private struct TimerPillStyle: ButtonStyle {
    var fill: Color = Color.white.opacity(0.1)
    var hoverFill: Color = Color.white.opacity(0.2)
    var foreground: Color = .white
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        TimerPillBody(configuration: configuration, style: self)
    }
}

private struct TimerPillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: TimerPillStyle
    @Environment(\.isEnabled) private var isEnabled
    private let hover = State(initialValue: false)
    private var isHovering: Bool { hover.wrappedValue }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(style.foreground)
            .background(shape.fill(isHovering && isEnabled ? style.hoverFill : style.fill))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { hover.wrappedValue = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
