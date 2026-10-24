import SwiftUI

/// Compact battery percentage + icon for the open notch header.
/// Hovering reveals the time estimate to its left. This replaces a `.help` tooltip, which AppKit
/// suppresses in the non-activating notch panel while another app is active.
struct BatteryIndicatorView: View {
    @ObservedObject private var monitor = BatteryMonitor.shared
    /// Plain `State` rather than `@State`: the macOS 27 SDK makes `@State` a macro whose plugin ships only with Xcode.
    private let hover = State(initialValue: false)

    var body: some View {
        if monitor.hasBattery {
            HStack(spacing: 5) {
                Text(verbatim: "\(monitor.percentage)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText(value: Double(monitor.percentage)))
                BatteryGlyph(
                    level: Double(monitor.percentage) / 100,
                    fill: monitor.glyphFillColor,
                    showsBolt: monitor.isCharging
                )
                .frame(width: 25, height: 12)
            }
            .frame(height: 20)
            // Drawn as an overlay so revealing it never shifts the header; it extends into the
            // empty space between the hardware notch and the indicator.
            .overlay(alignment: .leading) {
                if hover.wrappedValue {
                    hoverDetail
                        .alignmentGuide(.leading) { $0[.trailing] + 4 }
                        .transition(.opacity.combined(with: .offset(x: 4)))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { hover.wrappedValue = hovering }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery")
            .accessibilityValue(monitor.statusDescription)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: monitor.state)
            .animation(.easeInOut(duration: 0.25), value: monitor.isLowPowerMode)
        }
    }

    /// Short status (e.g. "2:15 to full") plus a Low Power Mode line; at most ~77 pt of text.
    private var hoverDetail: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: monitor.shortStatus)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.6))
            if monitor.isLowPowerMode {
                Text("Low Power Mode")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.9))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 100, alignment: .trailing)
        // Opaque so it cleanly covers the live metrics that sit to the indicator's left.
        .background(Color.black)
        .allowsHitTesting(false)
    }
}

/// Left wing of the closed notch while the charging activity is shown: a glowing bolt that pulses
/// (in Core Animation, so the always-on pulse costs no per-frame work).
struct BatteryLiveActivityLeading: View {
    var body: some View {
        LayerGlyph(.symbol("bolt.fill", size: 14, weight: .semibold), color: .green,
                   effect: .pulse(.standard), glowRadius: 4, glowOpacity: 0.55)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keep clear of the notch's concave top corner.
            .padding(.leading, NotchMetrics.closedTopRadius)
            .accessibilityLabel("Charging")
    }
}

/// Right wing of the closed notch while the charging activity is shown.
struct BatteryLiveActivityTrailing: View {
    @ObservedObject private var monitor = BatteryMonitor.shared

    var body: some View {
        Text(verbatim: "\(monitor.percentage)%")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.green)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(value: Double(monitor.percentage)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, NotchMetrics.closedTopRadius)
            .accessibilityLabel("Battery \(monitor.percentage) percent")
            .animation(.default, value: monitor.percentage)
    }
}

/// Battery outline with a fill proportional to `level` (0...1), a terminal nub and an optional charging bolt.
/// Designed for roughly 25 x 12 pt; the body stretches to the proposed size.
struct BatteryGlyph: View {
    var level: Double
    var fill: Color
    var showsBolt = false

    private let outline = Color.white.opacity(0.45)

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(outline, lineWidth: 1)
                GeometryReader { proxy in
                    let clamped = min(max(level, 0), 1)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(fill)
                        .frame(width: clamped > 0 ? max(proxy.size.width * clamped, 2) : 0)
                }
                .padding(2)
            }
            .mask { boltKnockout }
            .overlay {
                if showsBolt {
                    bolt.foregroundStyle(Color.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                .fill(outline)
                .frame(width: 1.5, height: 4)
        }
    }

    private var bolt: some View {
        Image(systemName: "bolt.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 8)
    }

    /// Cuts a gap around the bolt so it stays legible over both the fill and the outline.
    private var boltKnockout: some View {
        ZStack {
            Rectangle()
            if showsBolt {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) * .pi / 4
                    bolt.offset(x: cos(angle) * 1.1, y: sin(angle) * 1.1)
                }
                .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }
}

extension BatteryMonitor {
    /// Fill colour of the battery glyph: green on power, yellow in Low Power Mode, red when low, white otherwise.
    var glyphFillColor: Color {
        if isPluggedIn { return .green }
        if isLowPowerMode { return .yellow }
        if percentage <= 20 { return .red }
        return .white
    }

    /// Compact status for the header hover detail, e.g. "2:15 to full" or "3:40 left".
    var shortStatus: String {
        if isCharging {
            return timeToFull.map { "\(Self.formatMinutes($0)) to full" } ?? "Charging"
        }
        if isPluggedIn {
            return state.isCharged || percentage >= 100 ? "Charged" : "Not charging"
        }
        return timeToEmpty.map { "\(Self.formatMinutes($0)) left" } ?? "On battery"
    }

    /// Human-readable status, e.g. "82% · Charging, 2:15 until full".
    var statusDescription: String {
        var detail: String
        if isCharging {
            detail = timeToFull.map { "Charging, \(Self.formatMinutes($0)) until full" } ?? "Charging"
        } else if isPluggedIn {
            detail = state.isCharged || percentage >= 100 ? "Fully charged" : "Plugged in, not charging"
        } else {
            detail = timeToEmpty.map { "\(Self.formatMinutes($0)) remaining" } ?? "On battery"
        }
        if isLowPowerMode { detail += " · Low Power Mode" }
        return "\(percentage)% · \(detail)"
    }

    /// Formats minutes as "h:mm".
    nonisolated static func formatMinutes(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
