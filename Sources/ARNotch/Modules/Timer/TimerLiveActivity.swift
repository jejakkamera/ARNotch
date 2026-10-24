import SwiftUI

/// Left wing of the closed notch while a timer runs, rings or was missed (44×notchHeight pt).
/// Timer or alarm glyph (with a red dot if something was missed); a wiggling bell while ringing;
/// a still bell when only missed items are left.
struct TimerLiveActivityLeading: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        Group {
            if store.isRinging {
                TimerBellGlyph(size: 14)
            } else if store.soonestItem == nil, store.hasMissed {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(store.soonestItem?.isPaused == true ? 0.5 : 1))
                    .overlay(alignment: .topTrailing) {
                        if store.hasMissed {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 5, height: 5)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Keep clear of the notch's concave top corner.
        .padding(.leading, NotchMetrics.closedTopRadius)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if store.isRinging { return "Timer ringing" }
        let missed = store.hasMissed ? "\(store.missedCount) missed" : ""
        guard store.soonestItem != nil else { return missed }
        return missed.isEmpty ? "Timer running" : "Timer running, \(missed)"
    }

    private var symbol: String {
        guard let item = store.soonestItem else { return "timer" }
        if item.isPaused { return "pause.circle.fill" }
        return item.kind == .alarm ? "alarm.fill" : "timer"
    }
}

/// Right wing of the closed notch while a timer runs, rings or was missed (44×notchHeight pt):
/// remaining time of the soonest item ("4:59", or "1:05h" from an hour up), a flashing "0:00" while
/// ringing, or the number of missed items when nothing else is pending.
struct TimerLiveActivityTrailing: View {
    @ObservedObject private var store = TimerStore.shared
    @ObservedObject private var clock = TimerStore.shared.clock

    var body: some View {
        Group {
            if store.isRinging {
                // Flashes red ↔ dim orange in Core Animation, so the always-on flash costs no per-frame work.
                LayerGlyph(.text("0:00", size: 12, weight: .semibold), color: .red,
                           effect: .flash(.orange, LayerPulse(endOpacity: 0.35, period: 0.9)))
            } else if let item = store.soonestItem {
                let compact = TimerFormat.compact(item.remaining(at: clock.now))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: compact.text)
                    if compact.inHours {
                        Text(verbatim: "h")
                            .font(.system(size: 10, weight: .semibold))
                            .fixedSize()
                    }
                }
                .foregroundStyle(item.isPaused ? Color.white.opacity(0.55) : Color.orange)
            } else if store.hasMissed {
                Text(verbatim: "\(store.missedCount)")
                    .foregroundStyle(Color.orange)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .lineLimit(1)
        // Never below ~10 pt.
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.trailing, NotchMetrics.closedTopRadius)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if store.isRinging { return "Time's up" }
        guard let item = store.soonestItem else { return store.hasMissed ? "\(store.missedCount) missed" : "" }
        return "\(TimerFormat.clock(item.remaining(at: clock.now))) left"
    }
}

/// Orange bell that rings: a quick wiggle from its top, a short rest, repeat. The wiggle runs in Core
/// Animation, so ringing costs no per-frame work.
struct TimerBellGlyph: View {
    var size: CGFloat

    var body: some View {
        LayerGlyph(.symbol("bell.fill", size: size, weight: .semibold), color: .orange, effect: .wiggle(.bell))
            .accessibilityLabel("Ringing")
    }
}
