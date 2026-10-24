import SwiftUI

/// Colours shared by the System header metrics and tab.
enum SystemPalette {
    static let cpu = Color.orange
    static let download = Color(red: 0.36, green: 0.76, blue: 1.0)
    static let upload = Color(red: 0.78, green: 0.58, blue: 1.0)

    static func pressure(_ pressure: SystemMemoryPressure?) -> Color {
        switch pressure {
        case .warning: .orange
        case .critical: .red
        case .normal, nil: .green
        }
    }
}

/// Rounded fill that brightens on hover and dims when disabled (the System module's button look).
struct SystemPillStyle: ButtonStyle {
    var fill: Color = Color.white.opacity(0.1)
    var hoverFill: Color = Color.white.opacity(0.2)
    var foreground: Color = .white
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        SystemPillBody(configuration: configuration, style: self)
    }
}

private struct SystemPillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: SystemPillStyle
    @Environment(\.isEnabled) private var isEnabled
    /// Plain `State` rather than `@State`: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
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

/// Right-aligned line chart of recent readings; the newest value sits at the right edge and nil
/// entries leave gaps. Each series is scaled against `maxValue`.
struct SystemSparkline: View {
    struct Series {
        var values: [Double?]
        var color: Color
        /// Draws a soft gradient under the line.
        var filled = false
    }

    let series: [Series]
    let maxValue: Double
    var capacity = SystemMetrics.historyLength

    var body: some View {
        Canvas { context, size in
            guard capacity > 1, maxValue > 0, size.width > 0, size.height > 2 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let usableHeight = size.height - 1.5

            for item in series {
                let start = capacity - item.values.count
                var segments: [[CGPoint]] = []
                var current: [CGPoint] = []
                for (index, value) in item.values.enumerated() {
                    guard let value, value.isFinite else {
                        if !current.isEmpty { segments.append(current) }
                        current = []
                        continue
                    }
                    let level = CGFloat(min(max(value / maxValue, 0), 1))
                    current.append(CGPoint(x: CGFloat(start + index) * step, y: size.height - 0.75 - level * usableHeight))
                }
                if !current.isEmpty { segments.append(current) }

                for points in segments where points.count > 1 {
                    var line = Path()
                    line.addLines(points)
                    if item.filled, let first = points.first, let last = points.last {
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: size.height))
                        area.addLine(to: CGPoint(x: first.x, y: size.height))
                        area.closeSubpath()
                        context.fill(area, with: .linearGradient(
                            Gradient(colors: [item.color.opacity(0.32), item.color.opacity(0.02)]),
                            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
                        ))
                    }
                    context.stroke(line, with: .color(item.color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Thin capsule gauge, 0...1.
struct SystemBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: clamped > 0 ? max(proxy.size.width * clamped, proxy.size.height) : 0)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
