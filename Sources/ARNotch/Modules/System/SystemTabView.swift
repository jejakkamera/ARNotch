import AppKit
import SwiftUI

/// Content of the System tab (~600×135 pt): four live metric cards on the left; on the right the
/// heaviest apps (with Quit / Force Quit and a shortcut to Activity Monitor) or, when Core supplies
/// one, a ports panel behind an "Apps | Ports" switch.
///
///     SystemTabView()                          // Apps only
///     SystemTabView { DevPortsListView() }     // Apps | Ports
///
/// The ports panel gets the space under the switch row (about 340×107 pt in a 600×135 tab). The
/// process sweep only runs while the Apps list is showing.
struct SystemTabView<PortsPanel: View>: View {
    private let portsPanel: PortsPanel?
    @ObservedObject private var monitor = SystemMonitor.shared
    @StateObject private var lease = SystemSamplingLease(.metrics, .apps)

    /// Width of the metric cards column.
    static var cardsWidth: CGFloat { 236 }

    /// Apps | Ports switch, with `portsPanel` shown for Ports.
    init(@ViewBuilder portsPanel: () -> PortsPanel) {
        self.portsPanel = portsPanel()
    }

    var body: some View {
        HStack(spacing: 12) {
            SystemMetricCards()
                .frame(width: Self.cardsWidth)
            Divider().overlay(Color.white.opacity(0.12))
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .onAppear { lease.hold() }
        .onDisappear { lease.drop() }
    }

    /// Apps unless a ports panel exists and Ports was chosen.
    private var shownPanel: SystemPanel { portsPanel == nil ? .apps : monitor.panel }

    @ViewBuilder
    private var rightPanel: some View {
        let panel = shownPanel
        VStack(alignment: .leading, spacing: 6) {
            SystemPanelHeader(panel: panel, hasPortsPanel: portsPanel != nil)
            Group {
                if panel == .ports, let portsPanel {
                    portsPanel
                        .transition(.opacity)
                } else {
                    SystemAppsList()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.18), value: panel)
    }
}

extension SystemTabView where PortsPanel == EmptyView {
    /// Apps list only, without the Apps | Ports switch.
    init() {
        portsPanel = nil
    }
}

// MARK: Metric cards

/// 2×2 grid: CPU, Memory, Network, Battery (Uptime on Macs without a battery).
private struct SystemMetricCards: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        let metrics = monitor.metrics
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                cpuCard(metrics)
                memoryCard(metrics)
            }
            HStack(spacing: 6) {
                networkCard(metrics)
                if battery.hasBattery { batteryCard } else { uptimeCard }
            }
        }
    }

    private func cpuCard(_ metrics: SystemMetrics) -> some View {
        SystemCard(symbol: "cpu", title: "CPU", tint: SystemPalette.cpu) {
            SystemCardValue(text: metrics.cpu.map(SystemFormat.percent))
        } content: {
            SystemSparkline(
                series: [.init(values: metrics.cpuHistory, color: SystemPalette.cpu, filled: true)],
                maxValue: 100
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU")
        .accessibilityValue(metrics.cpu.map { "\(SystemFormat.percent($0)) busy" } ?? "Measuring")
    }

    private func memoryCard(_ metrics: SystemMetrics) -> some View {
        let memory = metrics.memory
        let tint = SystemPalette.pressure(memory?.pressure)
        return SystemCard(symbol: "memorychip", title: "Memory", tint: tint) {
            SystemCardValue(text: memory.map { SystemFormat.percent($0.fraction * 100) })
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                SystemCardDetail(
                    text: memory.map { "\(SystemFormat.gigabytes($0.used))/\(SystemFormat.installedGigabytes($0.total)) GB" } ?? "–",
                    compactText: memory.map { "\(SystemFormat.gigabytes($0.used))/\(SystemFormat.installedGigabytes($0.total))" },
                    badge: memory?.pressure.label,
                    badgeColor: tint
                )
                SystemBar(fraction: memory?.fraction ?? 0, color: tint)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue(memory.map {
            "\(SystemFormat.gigabytes($0.used)) of \(SystemFormat.installedGigabytes($0.total)) gigabytes used, pressure \($0.pressure.label.lowercased())"
        } ?? "Measuring")
    }

    private func networkCard(_ metrics: SystemMetrics) -> some View {
        let network = metrics.network
        let peak = metrics.networkHistory.reduce(0.0) { max($0, $1?.download ?? 0, $1?.upload ?? 0) }
        return SystemCard(symbol: "network", title: "Network", tint: SystemPalette.download) {
            EmptyView()
        } content: {
            // Rates stacked in a fixed column, so they keep one size and never shift as values change.
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    rate(network?.download, symbol: "arrow.down", tint: SystemPalette.download)
                    rate(network?.upload, symbol: "arrow.up", tint: SystemPalette.upload)
                }
                .frame(width: 58, alignment: .leading)
                SystemSparkline(
                    series: [
                        .init(values: metrics.networkHistory.map { $0?.download }, color: SystemPalette.download, filled: true),
                        .init(values: metrics.networkHistory.map { $0?.upload }, color: SystemPalette.upload),
                    ],
                    // Floor of 50 KB/s so an idle connection draws a flat line instead of noise.
                    maxValue: max(peak, 50_000) * 1.15
                )
                .frame(height: 22)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network")
        .accessibilityValue(network.map {
            "Download \(SystemFormat.rate($0.download)), upload \(SystemFormat.rate($0.upload))"
        } ?? "Measuring")
    }

    private func rate(_ value: Double?, symbol: String, tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
            Text(verbatim: value.map(SystemFormat.rate) ?? "–")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(value == nil ? 0.4 : 0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: 12)
    }

    private var batteryCard: some View {
        let tint = battery.glyphFillColor
        return SystemCard(symbol: batterySymbol, title: "Battery", tint: tint) {
            SystemCardValue(text: "\(battery.percentage)%")
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                SystemCardDetail(
                    text: battery.shortStatus,
                    badge: battery.isLowPowerMode ? "Low Power" : nil,
                    compactBadge: "Low Pwr",
                    badgeColor: .yellow
                )
                if let health = battery.health {
                    batteryHealthLine(health)
                } else {
                    SystemBar(fraction: Double(battery.percentage) / 100, color: tint == .white ? Color.white.opacity(0.8) : tint)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .help(battery.health.map(batteryHealthHelp) ?? battery.statusDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(battery.statusDescription + (battery.health.map { ", " + batteryHealthHelp($0) } ?? ""))
    }

    /// "♥ 82% · 496 cycles": maximum capacity and cycle count from AppleSmartBattery.
    private func batteryHealthLine(_ health: BatteryHealth) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.system(size: 7))
                .foregroundStyle(health.needsService ? Color.orange : Color.white.opacity(0.45))
            if let capacity = health.maximumCapacity {
                Text("\(capacity)%")
                    .foregroundStyle(health.needsService ? Color.orange : Color.white.opacity(0.8))
            }
            if let cycles = health.cycleCount {
                Text("· \(cycles) cycles").foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 12)
    }

    private func batteryHealthHelp(_ health: BatteryHealth) -> String {
        var parts: [String] = []
        if let capacity = health.maximumCapacity {
            var text = "Maximum capacity \(capacity)%"
            if let full = health.fullChargeCapacity, let design = health.designCapacity { text += " (\(full) of \(design) mAh)" }
            parts.append(text)
        }
        if let cycles = health.cycleCount {
            parts.append(health.designCycleCount.map { "\(cycles) of \($0) cycles" } ?? "\(cycles) cycles")
        }
        parts.append("Condition: " + health.condition)
        return parts.joined(separator: " · ")
    }

    /// Charging bolt, or a battery glyph filled to the nearest quarter.
    private var batterySymbol: String {
        if battery.isCharging { return "bolt.fill" }
        switch battery.percentage {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var uptimeCard: some View {
        let boot = SystemMonitor.bootDate
        return SystemCard(symbol: "clock", title: "Uptime", tint: Color.white.opacity(0.7)) {
            SystemCardValue(text: boot.map { SystemFormat.duration(Date().timeIntervalSince($0)) })
        } content: {
            Text(verbatim: boot.map { "Since " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Small rounded card: symbol + title (+ a value on the right), content filling the rest.
private struct SystemCard<Accessory: View, Content: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Spacing is explicit: "Battery" + "100%" need all of the 99 pt.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .fixedSize()
                    .frame(minWidth: 11)
                    .padding(.trailing, 3)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 3)
                accessory()
                // Same line height and baseline in every card, with or without a value.
                SystemCardValue.strut
            }
            .frame(height: 17)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// A card's detail line: text on the left, an optional coloured badge on the right. When both don't
/// fit, the shorter forms are tried (badge first, then text) before the text shrinks.
private struct SystemCardDetail: View {
    let text: String
    var compactText: String?
    var badge: String?
    var compactBadge: String?
    var badgeColor: Color = .white

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(text, badge)
            if let compactBadge, badge != nil { line(text, compactBadge) }
            if let compactText { line(compactText, compactBadge ?? badge) }
            line(compactText ?? text, compactBadge ?? badge, shrinks: true)
        }
    }

    private func line(_ text: String, _ badge: String?, shrinks: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: text)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(shrinks ? 0.8 : 1)
                .fixedSize(horizontal: !shrinks, vertical: false)
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The large number in a card's title row. 13 pt, so "Battery" and "100%" fit side by side (16 + 3 +
/// 38 + 3 + 38 of 99 pt); it scales down a little rather than truncate the title.
private struct SystemCardValue: View {
    let text: String?

    static let font = Font.system(size: 13, weight: .semibold, design: .rounded)

    /// Invisible, zero-width text that gives a title row the value's height and baseline.
    static var strut: some View {
        Text(verbatim: "0").font(font).hidden().fixedSize().frame(width: 0)
    }

    var body: some View {
        Text(verbatim: text ?? "–")
            .font(Self.font)
            .monospacedDigit()
            .foregroundStyle(text == nil ? Color.white.opacity(0.4) : Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

// MARK: Right panel header

/// The row above the right panel: the Apps | Ports switch (when a ports panel exists), the sort
/// switch and running-app count for Apps, and Activity Monitor.
private struct SystemPanelHeader: View {
    let panel: SystemPanel
    let hasPortsPanel: Bool
    @ObservedObject private var monitor = SystemMonitor.shared

    /// How much of the header's text fits; ViewThatFits picks the first (roomiest) variant that fits.
    private struct Style: Hashable {
        enum MonitorLabel: Hashable { case full, short, icon }
        var monitorLabel = MonitorLabel.full
        var shortSort = false
        var shortCount = false
    }

    private static let styles: [Style] = [
        Style(),
        Style(monitorLabel: .short),
        Style(monitorLabel: .short, shortCount: true),
        Style(monitorLabel: .short, shortSort: true, shortCount: true),
        Style(monitorLabel: .icon, shortSort: true, shortCount: true),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.styles, id: \.self) { style in
                row(style)
            }
        }
        .frame(height: 22)
    }

    private func row(_ style: Style) -> some View {
        HStack(spacing: 6) {
            if hasPortsPanel {
                panelSwitch
            }
            if panel == .apps {
                sortPicker(short: style.shortSort)
                // With the switch, the count sits in its Apps segment instead. Zero only means
                // the first snapshot hasn't arrived (Finder always runs), so nothing is shown then.
                if !hasPortsPanel, monitor.runningAppCount > 0 {
                    Text(verbatim: appCountText(short: style.shortCount))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.55))
                        .fixedSize()
                }
            }
            Spacer(minLength: 4)
            activityMonitorButton(style.monitorLabel)
        }
    }

    private func appCountText(short: Bool) -> String {
        let count = monitor.runningAppCount
        if short { return count == 1 ? "1 app" : "\(count) apps" }
        return count == 1 ? "1 app running" : "\(count) apps running"
    }

    /// "Apps 12 | Ports", in the same capsule style as the sort switch.
    private var panelSwitch: some View {
        SystemSegmentedSwitch(
            items: SystemPanel.allCases,
            selection: panel,
            select: { item in
                withAnimation(.easeInOut(duration: 0.18)) { monitor.panel = item }
            },
            label: { item, selected in
                HStack(spacing: 4) {
                    Text(item.title)
                    if item == .apps, monitor.runningAppCount > 0 {
                        Text(verbatim: "\(monitor.runningAppCount)")
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(selected ? 0.6 : 0.4))
                    }
                }
            },
            help: { item in
                item == .apps ? "Apps using the most CPU or memory" : "Development servers listening on ports"
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel")
    }

    private func sortPicker(short: Bool) -> some View {
        SystemSegmentedSwitch(
            items: SystemProcessSort.allCases,
            selection: monitor.sort,
            select: { item in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { monitor.sort = item }
            },
            label: { item, _ in
                Text(short && item == .memory ? "Mem" : item.title)
            },
            help: { item in "Sort by \(item.title)" }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort apps by")
    }

    private func activityMonitorButton(_ label: Style.MonitorLabel) -> some View {
        Button {
            monitor.openActivityMonitor()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                if label != .icon {
                    Text(label == .short ? "Monitor" : "Activity Monitor")
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()
                }
            }
            .padding(.horizontal, label == .icon ? 6 : 8)
            .frame(height: 22)
        }
        .buttonStyle(SystemPillStyle(cornerRadius: 11))
        .help("Open Activity Monitor")
        .accessibilityLabel("Open Activity Monitor")
    }
}

/// Capsule segmented control used for Apps | Ports and CPU | Memory.
private struct SystemSegmentedSwitch<Item: Hashable, Label: View>: View {
    let items: [Item]
    let selection: Item
    let select: (Item) -> Void
    @ViewBuilder let label: (Item, Bool) -> Label
    let help: (Item) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    if !selected { select(item) }
                } label: {
                    label(item, selected)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Color.clear))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(item))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

// MARK: Apps list

/// The heaviest apps, frozen apps first. Runs the process sweep while on screen.
private struct SystemAppsList: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @StateObject private var lease = SystemSamplingLease(.processes)

    private static let topAnchor = "system.apps.top"

    var body: some View {
        VStack(spacing: 4) {
            if monitor.showsFrozenAppsBanner {
                SystemFrozenAppsBanner()
                    .transition(.opacity)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.18), value: monitor.showsFrozenAppsBanner)
        .onAppear { lease.hold() }
        .onDisappear {
            lease.drop()
            monitor.holdOrder(false)
        }
    }

    /// The CPU-sorted list waits for the second sweep: the first has no CPU figures, so its order
    /// (by memory) would be wrong and reshuffle a moment later.
    private var isMeasuring: Bool {
        !monitor.hasProcessSample || (monitor.sort == .cpu && !monitor.hasProcessCPU)
    }

    @ViewBuilder
    private var content: some View {
        if isMeasuring {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if monitor.topApps.isEmpty {
            Text("No apps to show")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(monitor.topApps) { entry in
                            SystemAppRow(
                                entry: entry,
                                sort: monitor.sort,
                                action: monitor.action(for: entry),
                                icon: monitor.icon(for: entry),
                                hasCPU: monitor.hasProcessCPU
                            )
                        }
                    }
                    .id(Self.topAnchor)
                }
                .scrollIndicators(.automatic)
                // Animate membership only: pure reorders from the 2 s sweeps snap, so a CPU sort that reshuffles
                // on most sweeps doesn't replay a spring (and every row's numericText) each time. Sort changes
                // still animate through their own withAnimation.
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: Set(monitor.topApps.map(\.id)))
                // Over the name column of the last visible row, never over a Quit button.
                .overlay(alignment: .bottomLeading) {
                    if monitor.hiddenFrozenCount > 0 {
                        frozenPill(proxy)
                            .padding(4)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: monitor.hiddenFrozenCount)
                // Rows keep their places while the pointer is over the list (pill included), so a click
                // never lands on a moved row. Continuous hover also catches a pointer that was resting
                // there before the rows appeared.
                .onContinuousHover { phase in
                    switch phase {
                    case .active: monitor.holdOrder(true)
                    case .ended: monitor.holdOrder(false)
                    }
                }
            }
        }
    }

    /// Shown while the held order keeps newly frozen apps out of view; releases the order and scrolls up.
    private func frozenPill(_ proxy: ScrollViewProxy) -> some View {
        let count = monitor.hiddenFrozenCount
        return Button {
            monitor.showFrozenApps()
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(verbatim: count == 1 ? "1 not responding" : "\(count) not responding")
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize()
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
        }
        .buttonStyle(SystemPillStyle(fill: Color.red.opacity(0.9), hoverFill: Color.red, foreground: .white, cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
        .accessibilityLabel(count == 1 ? "1 app not responding, show it" : "\(count) apps not responding, show them")
    }
}

/// One-line request for Accessibility access at the top of the Apps list; can be closed.
private struct SystemFrozenAppsBanner: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "snowflake")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
            Text("Allow Accessibility to detect frozen apps")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button {
                monitor.requestAccessibilityAccess()
            } label: {
                Text("Allow")
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 18)
            }
            .buttonStyle(SystemPillStyle(
                fill: Color.orange.opacity(0.22), hoverFill: Color.orange.opacity(0.36), foreground: .orange, cornerRadius: 9
            ))
            .accessibilityLabel("Allow Accessibility access")
            .accessibilityHint("Opens the macOS prompt so ARNotch can detect frozen apps")
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { monitor.dismissFrozenAppsBanner() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(SystemPillStyle(
                fill: Color.clear, hoverFill: Color.white.opacity(0.12), foreground: Color.white.opacity(0.6), cornerRadius: 9
            ))
            .accessibilityLabel("Hide")
            .accessibilityHint("Turn frozen-app detection back on in Settings to see this again")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

/// One app: icon, name, the sorted metric (or "Not Responding") and a Quit / Force Quit button. The
/// action column always keeps its width, so values line up whether or not a row has a button.
private struct SystemAppRow: View {
    let entry: SystemAppEntry
    let sort: SystemProcessSort
    let action: SystemRowAction
    let icon: NSImage?
    let hasCPU: Bool
    /// Plain `State` rather than `@State`: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
    private let hover = State(initialValue: false)

    /// Fits "Force Quit" (10 pt bold + padding, about 70 pt).
    static let actionWidth: CGFloat = 72

    var body: some View {
        HStack(spacing: 7) {
            iconView
                .frame(width: 16, height: 16)
            HStack(spacing: 5) {
                Text(verbatim: entry.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let tag {
                    Text(verbatim: tag)
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize()
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            valueView
            ZStack(alignment: .trailing) {
                Color.clear
                actionButton
            }
            .frame(width: Self.actionWidth, height: 20)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill)
        )
        .opacity(entry.hasEnded ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    /// "process" for a loose process, "×26" for added-up processes of one executable.
    private var tag: String? {
        switch entry.kind {
        case .app: nil
        case .process: "process"
        case .processGroup: "×\(entry.processCount)"
        }
    }

    private var rowFill: Color {
        if entry.isUnresponsive { return Color.red.opacity(hover.wrappedValue ? 0.16 : 0.1) }
        return Color.white.opacity(hover.wrappedValue && !entry.hasEnded ? 0.07 : 0)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: entry.kind == .processGroup ? "square.stack.3d.up.fill" : "gearshape.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }

    /// The sorted metric; for a frozen app "Not Responding" instead (its figures matter less than its name).
    @ViewBuilder
    private var valueView: some View {
        if entry.isUnresponsive {
            Text("Not Responding")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
                .lineLimit(1)
                .fixedSize()
                // Wider than the 52 pt value column; claims its full width before the name truncates.
                .layoutPriority(2)
        } else {
            Text(verbatim: valueText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .contentTransition(.numericText())
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var valueText: String {
        switch sort {
        case .cpu: entry.cpu.map(SystemFormat.processCPU) ?? (hasCPU ? "0.0%" : "–")
        case .memory: SystemFormat.memory(entry.memory)
        }
    }

    private var valueColor: Color {
        if sort == .cpu, (entry.cpu ?? 0) >= 80, !entry.hasEnded { return SystemPalette.cpu }
        return Color.white.opacity(0.85)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch action {
        case .none:
            EmptyView()
        case .ended:
            Text("Ended")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .fixedSize()
        case .quit:
            Button {
                SystemMonitor.shared.quit(entry)
            } label: {
                Text("Quit")
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 20)
            }
            .buttonStyle(SystemPillStyle(
                fill: Color.white.opacity(hover.wrappedValue ? 0.12 : 0.07), hoverFill: Color.white.opacity(0.22),
                foreground: Color.white.opacity(0.85), cornerRadius: 10
            ))
            .help(entry.kind == .app ? "Quit \(entry.name)" : "End \(entry.name) (SIGTERM)")
            .accessibilityLabel("Quit \(entry.name)")
        case .quitting:
            Text("Quitting…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize()
        case .forceQuitArming, .forceQuit:
            Button {
                SystemMonitor.shared.forceQuit(entry)
            } label: {
                Text("Force Quit")
                    .font(.system(size: 10, weight: .bold))
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(height: 20)
            }
            .buttonStyle(SystemPillStyle(
                fill: Color.red.opacity(0.85), hoverFill: Color.red, foreground: .white, cornerRadius: 10
            ))
            // Ignores clicks for a moment after it appears (drawn dimmed meanwhile).
            .disabled(action == .forceQuitArming)
            .help("Force quit \(entry.name). Unsaved changes are lost.")
            .accessibilityLabel("Force quit \(entry.name)")
        }
    }

    private var accessibilityText: String {
        var text = entry.name
        if entry.kind == .processGroup { text += ", \(entry.processCount) processes" }
        if entry.hasEnded { return text + ", ended" }
        if entry.isUnresponsive { text += ", not responding" }
        text += ", " + (entry.cpu.map { "CPU \(SystemFormat.processCPU($0))" } ?? "CPU measuring")
        text += ", memory \(SystemFormat.memory(entry.memory))"
        return text
    }
}
