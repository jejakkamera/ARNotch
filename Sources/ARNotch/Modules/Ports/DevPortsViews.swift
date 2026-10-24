import AppKit
import SwiftUI

// MARK: - List

/// Ports panel shown inside the System tab's right-hand area (~340×110 pt): a header with the count,
/// "Show all" and refresh, then one row per listening server with Open / Copy / Stop.
/// Scans every 3 s while it is on screen.
struct DevPortsListView: View {
    @ObservedObject private var store = DevPortsStore.shared

    var body: some View {
        let rows = store.visibleEntries
        VStack(alignment: .leading, spacing: 5) {
            DevPortsHeader()
            if rows.isEmpty {
                DevPortsEmptyState()
                    .transition(.opacity)
            } else {
                DevPortsRows(rows: rows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rows.map(\.id))
        .onAppear { store.listDidAppear() }
        .onDisappear { store.listDidDisappear() }
    }
}

/// The scrolling rows. At ~110 pt three rows fit with the top of a fourth peeking out; when they
/// don't all fit, the bottom edge fades out and the content gets matching padding so the last row can
/// scroll clear of the fade.
private struct DevPortsRows: View {
    let rows: [DevPortEntry]

    static let rowHeight: CGFloat = 24
    static let spacing: CGFloat = 2
    private static let fade: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let count = CGFloat(rows.count)
            let contentHeight = count * Self.rowHeight + max(count - 1, 0) * Self.spacing
            let overflows = contentHeight > proxy.size.height + 0.5
            ScrollView(.vertical) {
                VStack(spacing: Self.spacing) {
                    ForEach(rows) { entry in
                        DevPortRow(entry: entry)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.bottom, overflows ? Self.fade : 0)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? Self.fade : 0)
                }
            }
        }
    }
}

/// "3 dev servers" + Show all + refresh.
private struct DevPortsHeader: View {
    @ObservedObject private var store = DevPortsStore.shared
    /// Plain `State` rather than `@State`: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
    private let spin = State(initialValue: 0.0)

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            showAllButton
            Button {
                store.refresh()
                withAnimation(.easeInOut(duration: 0.5)) { spin.wrappedValue += 360 }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(spin.wrappedValue))
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(DevPortsIconButtonStyle())
            .help("Scan again")
            .accessibilityLabel("Refresh")
        }
        .frame(height: 18)
    }

    /// "6 dev servers · 1 web": the web count is what the closed-notch indicator shows.
    private var title: String {
        guard store.hasScanned else { return "Scanning…" }
        let dev = store.devCount
        if store.showAll {
            return "\(store.entries.count) listening · \(dev) dev"
        }
        let web = store.webCount
        let servers: String
        switch dev {
        case 0: return "Dev servers"
        case 1: servers = "1 dev server"
        default: servers = "\(dev) dev servers"
        }
        return web > 0 && web != dev ? "\(servers) · \(web) web" : servers
    }

    private var showAllButton: some View {
        let isOn = store.showAll
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.showAll.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text("Show all")
                if !isOn && store.hiddenCount > 0 {
                    Text(verbatim: "\(store.hiddenCount)")
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.07)))
            .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Show dev servers only" : "Also show apps and system services")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct DevPortsEmptyState: View {
    @ObservedObject private var store = DevPortsStore.shared

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.3))
            Text(headline)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.8))
            Text("Start one (npm run dev, php artisan serve…) and it appears here")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: String {
        guard store.hasScanned else { return "Looking for dev servers…" }
        return store.showAll ? "No listening ports" : "No dev servers running"
    }
}

// MARK: - Row

/// One server: status dot, ":8888", "httpd · MAMP", LAN badge, Open / Copy, then Stop in its own column.
/// Every control sits in a fixed column, so they line up from row to row.
private struct DevPortRow: View {
    let entry: DevPortEntry
    @ObservedObject private var store = DevPortsStore.shared
    private let hover = State(initialValue: false)

    /// ":65535" in 13 pt semibold SF Mono is 48.2 pt wide.
    private static let portWidth: CGFloat = 49
    private static let stopWidth: CGFloat = 42

    var body: some View {
        let action = store.action(for: entry)
        let notice = store.notices[entry.id]

        HStack(spacing: 6) {
            DevPortStatusDot(color: dotColor(action), pulses: action == .stopping || action == .killing)
            Text(verbatim: ":\(entry.port)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.isDev ? Color.white : Color.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
                .frame(width: Self.portWidth, alignment: .leading)
            detail(action: action, notice: notice)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.isLAN && notice == nil && action == nil {
                lanBadge
            }
            HStack(spacing: 1) {
                if entry.isHTTP {
                    iconButton("arrow.up.right.square", label: "Open in browser") { store.open(entry) }
                } else {
                    // Keeps Copy and Stop in the same place on every row.
                    Color.clear.frame(width: 22, height: 22)
                }
                iconButton("doc.on.doc", label: "Copy \(entry.copyText)") { store.copy(entry) }
            }
            stopControl(action)
                .frame(width: Self.stopWidth)
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .frame(height: DevPortsRows.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hover.wrappedValue ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
        .animation(.easeInOut(duration: 0.2), value: notice)
        .animation(.easeInOut(duration: 0.2), value: action)
        .contextMenu { menu(action) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    // Details

    @ViewBuilder
    private func detail(action: DevPortAction?, notice: DevPortNotice?) -> some View {
        Group {
            if let notice {
                Text(verbatim: notice.text)
                    .foregroundStyle(color(for: notice.tone))
                    .truncationMode(.middle)
            } else if let action {
                switch action {
                case .stopping:
                    Text("Stopping…").foregroundStyle(Color.orange)
                case .needsKill:
                    Text("Still running — Kill forces it").foregroundStyle(Color.red.opacity(0.9))
                case .killing:
                    Text("Killing…").foregroundStyle(Color.red.opacity(0.9))
                }
            } else {
                Text(verbatim: subtitle)
                    .foregroundStyle(Color.white.opacity(entry.isDev ? 0.55 : 0.4))
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .id(notice?.id ?? -1)
        .transition(.opacity)
    }

    /// "node · dashboard-project · Vite", "httpd · MAMP", "mysqld · MAMP · MySQL X".
    private var subtitle: String {
        [entry.processName, entry.context, entry.serviceLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func dotColor(_ action: DevPortAction?) -> Color {
        switch action {
        case .stopping: return .orange
        case .needsKill, .killing: return .red
        case nil: return entry.isDev ? .green : Color.white.opacity(0.3)
        }
    }

    private func color(for tone: DevPortNotice.Tone) -> Color {
        switch tone {
        case .info: return Color.white.opacity(0.75)
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func isNeedsKill(_ action: DevPortAction?) -> Bool {
        if case .needsKill = action { return true }
        return false
    }

    // Controls

    /// Bound to every interface. Hovering shows that it copies the address other devices can use.
    private var lanBadge: some View {
        Button {
            store.copyLAN(entry)
        } label: {
            EmptyView()
        }
        .buttonStyle(DevPortsLANBadgeStyle())
        .help("Reachable from your network — click to copy the LAN address")
        .accessibilityLabel("Copy LAN address")
    }

    @ViewBuilder
    private func stopControl(_ action: DevPortAction?) -> some View {
        if !entry.isStoppable {
            iconButton("lock.fill", label: "Can't stop this from ARNotch", dimmed: true) { store.explainProtection(entry) }
        } else {
            switch action {
            case nil:
                pill("Stop", help: "Stop (SIGTERM)", fill: Color.white.opacity(hover.wrappedValue ? 0.12 : 0.07),
                     hoverFill: Color.white.opacity(0.22), foreground: Color.white.opacity(0.85)) { store.stop(entry) }
            case .stopping, .killing:
                LayerGlyph(.symbol("hourglass", size: 11, weight: .semibold),
                           color: action == .killing ? Color.red.opacity(0.9) : Color.orange, effect: .pulse(.standard))
                    .frame(width: 22, height: 22)
                    .accessibilityLabel(action == .killing ? "Killing" : "Stopping")
            case .needsKill:
                pill("Kill", help: "Force quit (SIGKILL)", fill: Color.red.opacity(0.85), hoverFill: Color.red,
                     foreground: .white) { store.forceKill(entry) }
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// Labelled step button, like the Apps list's Quit / Force Quit.
    private func pill(_ title: String, help: String, fill: Color, hoverFill: Color, foreground: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 10, weight: .bold))
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 20)
        }
        .buttonStyle(DevPortsPillStyle(fill: fill, hoverFill: hoverFill, foreground: foreground))
        .help(help)
        .accessibilityLabel(help)
    }

    private func iconButton(_ symbol: String, label: String, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(DevPortsIconButtonStyle(foreground: Color.white.opacity(dimmed ? 0.3 : 0.75)))
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func menu(_ action: DevPortAction?) -> some View {
        if let url = entry.browserURL {
            Button { store.open(entry) } label: { Text(verbatim: "Open \(url.absoluteString)") }
        }
        Button { store.copy(entry) } label: { Text(verbatim: "Copy \(entry.copyText)") }
        if entry.isLAN, let address = store.lanAddress {
            Button { store.copyLAN(entry) } label: { Text(verbatim: "Copy \(entry.lanText(address: address))") }
        }
        Button { store.copyPID(entry) } label: { Text(verbatim: "Copy PID \(entry.master.pid)") }
        if entry.projectPath != nil {
            Button { store.revealProject(entry) } label: { Text(verbatim: "Show “\(entry.context ?? "project")” in Finder") }
        }
        if entry.isStoppable {
            Divider()
            if isNeedsKill(action) {
                Button("Kill (SIGKILL)", role: .destructive) { store.forceKill(entry) }
            } else {
                Button("Stop (SIGTERM)") { store.stop(entry) }
                    .disabled(action != nil)
            }
        }
    }

    private var accessibilityText: String {
        var parts = ["Port \(entry.port)", subtitle]
        if entry.isLAN { parts.append("reachable from the network") }
        return parts.joined(separator: ", ")
    }
}

/// Small glowing status dot; pulses while a stop is in progress.
private struct DevPortStatusDot: View {
    var color: Color
    var pulses: Bool

    var body: some View {
        LayerPulsingDot(color: color, isPulsing: pulses, glowRadius: 2, glowOpacity: 0.6)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// Borderless icon button that gets a soft fill on hover and dims when pressed or disabled.
private struct DevPortsIconButtonStyle: ButtonStyle {
    var foreground: Color = Color.white.opacity(0.75)

    func makeBody(configuration: Configuration) -> some View {
        DevPortsIconButtonBody(configuration: configuration, foreground: foreground)
    }
}

/// The "LAN" capsule: outlined at rest; on hover it fills like the icon buttons and shows a copy glyph.
private struct DevPortsLANBadgeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DevPortsLANBadgeBody(isPressed: configuration.isPressed)
    }
}

private struct DevPortsLANBadgeBody: View {
    let isPressed: Bool
    private let hover = State(initialValue: false)

    var body: some View {
        let isHovering = hover.wrappedValue
        HStack(spacing: 2) {
            if isHovering {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 7, weight: .bold))
                    .transition(.opacity.combined(with: .scale))
            }
            Text("LAN")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(isHovering ? Color.white : Color.white.opacity(0.75))
        .padding(.horizontal, 4)
        .frame(height: 15)
        .background {
            Capsule().fill(Color.white.opacity(isHovering ? 0.16 : 0))
            Capsule().strokeBorder(Color.white.opacity(isHovering ? 0 : 0.3), lineWidth: 1)
        }
        .contentShape(Capsule())
        .fixedSize()
        .opacity(isPressed ? 0.6 : 1)
        .scaleEffect(isPressed ? 0.92 : 1)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }
}

/// Rounded fill that brightens on hover, matching the System tab's Quit / Force Quit pills.
private struct DevPortsPillStyle: ButtonStyle {
    var fill: Color
    var hoverFill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        DevPortsPillBody(configuration: configuration, style: self)
    }
}

private struct DevPortsPillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: DevPortsPillStyle
    @Environment(\.isEnabled) private var isEnabled
    private let hover = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let isHovering = hover.wrappedValue && isEnabled
        configuration.label
            .foregroundStyle(style.foreground)
            .background(shape.fill(isHovering ? style.hoverFill : style.fill))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { hover.wrappedValue = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct DevPortsIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let foreground: Color
    @Environment(\.isEnabled) private var isEnabled
    private let hover = State(initialValue: false)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .foregroundStyle(hover.wrappedValue && isEnabled ? Color.white : foreground)
            .background(shape.fill(hover.wrappedValue && isEnabled ? Color.white.opacity(0.12) : Color.clear))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { hover.wrappedValue = $0 }
            .animation(.easeOut(duration: 0.12), value: hover.wrappedValue)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Closed notch

/// Quiet 16-point wing for background servers: a small, steady status dot.
/// A terminal prompt with a blinking cursor ("›_") on a soft tile: clearly "something is running",
/// and unlike a plain dot it can't be mistaken for the camera indicator.
struct DevPortsLiveActivityLeading: View {
    @ObservedObject private var store = DevPortsStore.shared

    var body: some View {
        let ports = store.livePorts
        HStack(spacing: 1) {
            Text("›")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(DevPortsWing.tint)
            LayerGlyph(.text("_", size: 12, weight: .bold), color: DevPortsWing.tint,
                       effect: .pulse(LayerPulse(startOpacity: 1, endOpacity: 0.05, period: 1.1)))
                .frame(width: 7, height: 15)
                .offset(y: -1)
        }
        .frame(width: 26, height: 20)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DevPortsWing.tint.opacity(0.14)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, NotchMetrics.closedTopRadius)
        .help(DevPortsWing.summary(ports))
        .accessibilityLabel(ports.count == 1 ? "Web dev server running" : "\(ports.count) web dev servers running")
    }
}

/// Intentionally empty: the left wing says it all; port numbers stay in the tooltip and System → Ports.
struct DevPortsLiveActivityTrailing: View {
    var body: some View {
        Color.clear
    }
}

private enum DevPortsWing {
    /// Soft green, matching the calmer palette of the other wings.
    static let tint = Color(red: 0.45, green: 0.85, blue: 0.6)

    static func summary(_ ports: [UInt16]) -> String {
        ports.isEmpty ? "No dev servers" : "Dev servers: " + ports.map { "localhost:\($0)" }.joined(separator: ", ")
    }
}

// MARK: - Settings

/// Preferences for the Dev Ports module, placed inside the Settings window's Form.
struct DevPortsSettingsSection: View {
    @ObservedObject private var store = DevPortsStore.shared

    var body: some View {
        Section {
            Toggle("Show dev servers in closed notch", isOn: $store.showInClosedNotch)
            Toggle("Show all listening ports, not only dev servers", isOn: $store.showAll)
        } header: {
            Text("Dev servers")
        } footer: {
            Text("ARNotch finds servers you started (Node, PHP, Python, MAMP, Docker…) by looking at your own processes: every 3 seconds while the Ports list is open, and every 10 seconds for the closed-notch indicator, which counts web servers (not databases). Ports opened by root — for example MAMP's Apache on port 80 when started with admin rights — aren't visible without admin rights.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
