import SwiftUI

/// Pomodoro panel inside the Timer tab's left column (~272×105 pt below the mode switch).
struct PomodoroComposerView: View {
    @ObservedObject private var store = PomodoroStore.shared

    private struct Preset: Hashable {
        let name: String
        let focus: Int
        let shortBreak: Int
        let longBreak: Int
    }

    private static let presets = [
        Preset(name: "Classic", focus: 25, shortBreak: 5, longBreak: 15),
        Preset(name: "Deep work", focus: 50, shortBreak: 10, longBreak: 20),
        Preset(name: "Quick", focus: 15, shortBreak: 3, longBreak: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 12) {
                    ring(at: context.date)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(store.phase.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(store.phase.color)
                            if store.isPaused {
                                Text("Paused").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        Text(PomodoroFormat.clock(store.remaining(at: context.date)))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                        sessionDots
                    }
                    Spacer(minLength: 0)
                    settingsMenu
                }
            }

            HStack(spacing: 6) {
                circleButton("arrow.counterclockwise", help: "Reset cycle") { store.reset() }
                    .disabled(!store.isActive && store.completedInCycle == 0 && store.phase == .focus)
                circleButton("forward.end.fill", help: "Skip to \(nextTitle)") { store.skip() }
                Spacer(minLength: 4)
                Button(action: store.togglePause) {
                    Label(primaryTitle, systemImage: store.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 118, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(store.phase.color.opacity(store.isRunning ? 0.25 : 0.9)))
                        .foregroundStyle(store.isRunning ? Color.white : .black)
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ring(at date: Date) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
            Circle()
                .trim(from: 0, to: store.progress(at: date))
                .stroke(store.phase.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: store.phase.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(store.phase.color.opacity(0.9))
        }
        .frame(width: 54, height: 54)
    }

    /// One dot per focus session in the cycle; filled when done.
    private var sessionDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<PomodoroStore.sessionsPerCycle, id: \.self) { index in
                Circle()
                    .fill(index < store.completedInCycle ? PomodoroStore.Phase.focus.color : Color.white.opacity(0.15))
                    .frame(width: 6, height: 6)
            }
            if store.completedToday > 0 {
                Text("\(store.completedToday) today")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 3)
            }
        }
        .help("\(store.completedInCycle) of \(PomodoroStore.sessionsPerCycle) focus sessions before the long break")
    }

    private var settingsMenu: some View {
        Menu {
            ForEach(Self.presets, id: \.self) { preset in
                Button {
                    store.focusMinutes = preset.focus
                    store.shortBreakMinutes = preset.shortBreak
                    store.longBreakMinutes = preset.longBreak
                } label: {
                    let current = store.focusMinutes == preset.focus && store.shortBreakMinutes == preset.shortBreak
                        && store.longBreakMinutes == preset.longBreak
                    Text("\(current ? "✓ " : "")\(preset.name) — \(preset.focus) / \(preset.shortBreak) / \(preset.longBreak) min")
                }
            }
            Divider()
            Toggle("Start next phase automatically", isOn: $store.autoContinue)
        } label: {
            VStack(spacing: 1) {
                Text("\(store.focusMinutes)/\(store.shortBreakMinutes)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 40, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Focus / break length")
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .foregroundStyle(.white.opacity(0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var primaryTitle: String {
        if store.isRunning { return "Pause" }
        if store.isPaused { return "Resume" }
        return store.phase == .focus ? "Start Focus" : "Start Break"
    }

    private var nextTitle: String {
        if store.phase != .focus { return "focus" }
        return store.completedInCycle + 1 >= PomodoroStore.sessionsPerCycle ? "long break" : "break"
    }
}

enum PomodoroFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Closed-notch wings

struct PomodoroLiveActivityLeading: View {
    @ObservedObject private var store = PomodoroStore.shared

    var body: some View {
        Image(systemName: store.phase.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(store.phase.color.opacity(store.isPaused ? 0.5 : 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, NotchMetrics.closedTopRadius)
            .accessibilityLabel("Pomodoro \(store.phase.title)")
    }
}

struct PomodoroLiveActivityTrailing: View {
    @ObservedObject private var store = PomodoroStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(PomodoroFormat.clock(store.remaining(at: context.date)))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(store.phase.color.opacity(store.isPaused ? 0.5 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, NotchMetrics.closedTopRadius)
    }
}
