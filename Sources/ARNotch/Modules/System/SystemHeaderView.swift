import SwiftUI

/// Compact live metrics for the open-notch header, in a fixed 96×24 pt frame: network ↓/↑ on the
/// top line, CPU and memory (chip symbols; memory coloured by pressure) below. `onTap` switches the notch to the
/// System tab. Renders nothing while "Live metrics in notch header" is off.
struct SystemMetricsHeaderView: View {
    private let onTap: () -> Void
    @ObservedObject private var monitor = SystemMonitor.shared

    /// The view never grows beyond this; Core can reserve exactly this much space.
    static let size = CGSize(width: 96, height: 24)

    /// - Parameter onTap: Called on click; Core switches the notch to the System tab.
    init(onTap: @escaping () -> Void = {}) {
        self.onTap = onTap
    }

    var body: some View {
        if monitor.showsHeaderMetrics {
            SystemHeaderMetricsButton(onTap: onTap)
        }
    }
}

/// The clickable metrics; holds the sampling lease only while on screen.
private struct SystemHeaderMetricsButton: View {
    let onTap: () -> Void
    @ObservedObject private var monitor = SystemMonitor.shared
    @StateObject private var lease = SystemSamplingLease(.metrics)
    /// Plain `State` rather than `@State`: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: onTap) {
            SystemHeaderMetricsContent(metrics: monitor.metrics)
                .frame(width: SystemMetricsHeaderView.size.width, height: SystemMetricsHeaderView.size.height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hover.wrappedValue ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: SystemMetricsHeaderView.size.width, height: SystemMetricsHeaderView.size.height)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hover.wrappedValue = hovering }
        }
        .help(SystemHeaderMetricsContent.summary(monitor.metrics) + "\nClick for details")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("System metrics")
        .accessibilityValue(SystemHeaderMetricsContent.summary(monitor.metrics))
        .accessibilityHint("Shows the System tab")
        .accessibilityAddTraits(.isButton)
        .onAppear { lease.hold() }
        .onDisappear { lease.drop() }
    }
}

/// The two metric lines. Every label and value has a fixed frame, so changing numbers never shift the
/// layout, and every value fits at its full 10 pt size.
struct SystemHeaderMetricsContent: View {
    let metrics: SystemMetrics

    private static let cellWidth: CGFloat = 44
    private static let valueFont = Font.system(size: 10, weight: .medium).monospacedDigit()
    private static let arrowFont = Font.system(size: 7.5, weight: .bold)
    private static let symbolFont = Font.system(size: 9, weight: .bold)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                cell(labelWidth: 9, value: metrics.network.map { SystemFormat.compactRate($0.download) }) {
                    Image(systemName: "arrow.down")
                        .font(Self.arrowFont)
                        .foregroundStyle(SystemPalette.download)
                }
                cell(labelWidth: 9, value: metrics.network.map { SystemFormat.compactRate($0.upload) }) {
                    Image(systemName: "arrow.up")
                        .font(Self.arrowFont)
                        .foregroundStyle(SystemPalette.upload)
                }
            }
            .frame(height: 12)
            HStack(spacing: 4) {
                cell(labelWidth: 12, value: metrics.cpu.map(SystemFormat.percent)) {
                    Image(systemName: "cpu")
                        .font(Self.symbolFont)
                        .foregroundStyle((metrics.cpu ?? 0) >= 85 ? SystemPalette.cpu : Color.white.opacity(0.5))
                }
                cell(labelWidth: 12, value: metrics.memory.map { SystemFormat.percent($0.fraction * 100) }) {
                    Image(systemName: "memorychip")
                        .font(Self.symbolFont)
                        .foregroundStyle(metrics.memory.map { SystemPalette.pressure($0.pressure).opacity(0.9) } ?? Color.white.opacity(0.5))
                }
            }
            .frame(height: 12)
        }
        .frame(width: SystemMetricsHeaderView.size.width, height: SystemMetricsHeaderView.size.height)
    }

    /// Symbol (fixed width, leading) + value (right-aligned in the remaining fixed width). Widest values
    /// at 10 pt: "100%" 30 pt and "1.2G" 25 pt in the 32 pt CPU/RAM slot; "120M" 29 pt and "999K"
    /// 27 pt in the 35 pt network slot.
    private func cell<Label: View>(labelWidth: CGFloat, value: String?, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 0) {
            label()
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            Text(verbatim: value ?? "–")
                .font(Self.valueFont)
                .foregroundStyle(Color.white.opacity(value == nil ? 0.4 : 0.85))
                .lineLimit(1)
                .fixedSize()
                .frame(width: Self.cellWidth - labelWidth, alignment: .trailing)
        }
        .frame(width: Self.cellWidth)
    }

    /// Spoken / tooltip summary, e.g. "Download 1.2 MB/s, upload 34 KB/s · CPU 12% · Memory 11.2 of 16 GB (pressure normal)".
    static func summary(_ metrics: SystemMetrics) -> String {
        var parts: [String] = []
        if let network = metrics.network {
            parts.append("Download \(SystemFormat.rate(network.download)), upload \(SystemFormat.rate(network.upload))")
        }
        if let cpu = metrics.cpu {
            parts.append("CPU \(SystemFormat.percent(cpu))")
        }
        if let memory = metrics.memory {
            let used = SystemFormat.gigabytes(memory.used)
            let total = SystemFormat.installedGigabytes(memory.total)
            parts.append("Memory \(used) of \(total) GB (pressure \(memory.pressure.label.lowercased()))")
        }
        return parts.isEmpty ? "Measuring…" : parts.joined(separator: " · ")
    }
}
