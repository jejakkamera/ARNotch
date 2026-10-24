import AppKit
import SwiftUI

/// Preferences window content. Shown in a regular window; AppSettings is in the environment.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var permissions = PermissionsModel()
    @Environment(\.controlActiveState) private var controlActiveState
    /// Plain `State` rather than `@State`: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
    private let heightState = State(initialValue: SettingsView.fittingHeight())
    private var height: CGFloat { heightState.wrappedValue }

    var body: some View {
        Form {
            generalSection
            liveActivitiesSection
            nookSection
            shelfSection
            TimerSettingsSection()
            DevPortsSettingsSection()
            SystemSettingsSection()
            permissionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: height)
        .background(CenterWindowOnce())
        .onAppear(perform: refreshSystemState)
        // Re-read system state whenever the window comes forward, e.g. after visiting System Settings.
        .onChange(of: controlActiveState) { _, state in
            if state == .key { refreshSystemState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            updateHeight()
        }
    }

    private func refreshSystemState() {
        launchAtLogin.refresh()
        permissions.refresh()
        updateHeight()
    }

    private func updateHeight() {
        let fitting = Self.fittingHeight()
        if fitting != height { heightState.wrappedValue = fitting }
    }

    /// The window isn't resizable, so on small or scaled displays it shrinks (the form scrolls)
    /// rather than letting the bottom rows spill off-screen or behind the Dock.
    private static func fittingHeight() -> CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return 620 }
        // Leaves room for the title bar plus a small margin.
        return max(320, min(620, (visible - 60).rounded(.down)))
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle(isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })) {
                SettingsRowLabel("Launch at login", symbol: "power", tint: .indigo)
            }
            .disabled(launchAtLogin.isBusy)

            if let error = launchAtLogin.errorMessage {
                SettingsNotice(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if launchAtLogin.needsApproval {
                SettingsNotice(
                    text: "Allow ARNotch in System Settings › General › Login Items.",
                    symbol: "hand.raised.fill", tint: .orange,
                    actionTitle: "Open Login Items", action: launchAtLogin.openLoginItemsSettings
                )
            }

            Toggle(isOn: $settings.showMenuBarIcon) {
                SettingsRowLabel(
                    "Show menu bar icon", subtitle: "Settings stay reachable from the open notch.",
                    symbol: "menubar.rectangle", tint: .blue
                )
            }

            Toggle(isOn: Binding(get: { settings.hapticsEnabled }, set: setHaptics)) {
                SettingsRowLabel("Haptic feedback", subtitle: "Trackpad tap when the notch opens.", symbol: "hand.tap.fill", tint: .orange)
            }

            LabeledContent {
                HStack(spacing: 8) {
                    // No `step:` — on macOS that draws a tick mark for every step.
                    Slider(value: Binding(
                        get: { settings.hoverDelay },
                        set: { settings.hoverDelay = ($0 * 100).rounded() / 100 }
                    ), in: 0...0.5)
                    .labelsHidden()
                    .frame(width: 140)

                    Text(hoverDelayLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            } label: {
                SettingsRowLabel("Hover delay", subtitle: "Rest time before the notch opens.", symbol: "cursorarrow.rays", tint: .purple)
            }
        }
    }

    private var hoverDelayLabel: String {
        settings.hoverDelay < 0.005 ? "Instant" : String(format: "%.2f s", settings.hoverDelay)
    }

    private func setHaptics(_ enabled: Bool) {
        settings.hapticsEnabled = enabled
        if enabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    // MARK: Live activities

    private var liveActivitiesSection: some View {
        Section {
            Toggle(isOn: $settings.showMediaActivity) {
                SettingsRowLabel("Now playing", subtitle: "Artwork and visualizer while music plays.", symbol: "music.note", tint: .pink)
            }
            Toggle(isOn: $settings.showChargingActivity) {
                SettingsRowLabel("Charging", subtitle: "Brief indicator when power connects.", symbol: "bolt.fill", tint: .green)
            }
        } header: {
            Text("Live activities")
        } footer: {
            SettingsFooter("Shown beside the closed notch.")
        }
    }

    // MARK: Nook

    private var nookSection: some View {
        Section("Nook") {
            Toggle(isOn: $settings.showCalendar) {
                SettingsRowLabel("Calendar widget", symbol: "calendar", tint: .red)
            }
            Toggle(isOn: $settings.showMirror) {
                SettingsRowLabel("Mirror widget", subtitle: "Camera preview, only while the notch is open.", symbol: "person.crop.square", tint: .teal)
            }
            Toggle(isOn: $settings.showBatteryInHeader) {
                SettingsRowLabel("Battery in header", symbol: "battery.75percent", tint: .green)
            }
        }
    }

    // MARK: Shelf

    private var shelfSection: some View {
        Section("Shelf") {
            Toggle(isOn: $settings.openShelfOnDrag) {
                SettingsRowLabel(
                    "Open shelf when dragging files",
                    subtitle: "Drop files onto the notch to keep them handy.",
                    symbol: "tray.and.arrow.down.fill", tint: .blue
                )
            }
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            PermissionRow(
                title: "Camera", symbol: "camera.fill", tint: .gray, pane: .camera,
                canRequest: permissions.camera == .notDetermined, request: permissions.requestCamera
            ) {
                PermissionStatusLine(status: permissions.camera)
            }
            PermissionRow(
                title: "Calendars", symbol: "calendar", tint: .red, pane: .calendars,
                canRequest: permissions.canRequestCalendars, request: permissions.requestCalendars
            ) {
                PermissionStatusLine(status: permissions.calendars)
            }
            PermissionRow(
                title: "Automation", symbol: "music.note.list", tint: .pink, pane: .automation,
                canRequest: permissions.canRequestAutomation, request: permissions.requestAutomation
            ) {
                ForEach(permissions.automation) { target in
                    PermissionStatusLine(status: target.status, prefix: target.name)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            SettingsFooter("ARNotch only asks when a feature needs access. Changes apply right away.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            HStack(spacing: 12) {
                if LaunchAtLoginController.isRunningFromAppBundle, let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                } else {
                    CrestGlyph().frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name).font(.headline)
                    Text("Version \(AppInfo.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Free & open — no registration, no license key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Link(destination: URL(string: "https://adirp.id")!) {
                        Label("adirp.id", systemImage: "globe")
                    }
                    .font(.caption)
                    .help("Open adirp.id")
                }
                Spacer(minLength: 8)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Centres the hosting window once, at its final size. The window is created before SwiftUI has sized it,
/// so a `center()` at creation centres a tiny frame that then grows off-centre and against the menu bar.
/// Idempotent if the window is already centred; later reopenings keep wherever the user moved it.
private struct CenterWindowOnce: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var didCenter = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didCenter, window != nil else { return }
            didCenter = true
            // Next turn of the main loop, after the window has been created and ordered front.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                if let size = window.contentView?.fittingSize, size.width > 0, size.height > 0 {
                    window.setContentSize(size)
                }
                window.center()
            }
        }
    }
}

/// Name and version from the bundle, with fallbacks for unbundled runs.
enum AppInfo {
    static var name: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "ARNotch"
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

// MARK: - Building blocks

/// Miniature of the app icon, for unbundled runs where AppKit only has a generic icon.
struct CrestGlyph: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.33, green: 0.27, blue: 0.92), Color(red: 0.03, green: 0.03, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: 36, height: 36)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.black)
                    .frame(width: 22, height: 7)
                    .overlay(alignment: .leading) {
                        Circle().fill(Color.green).frame(width: 3, height: 3).padding(.leading, 3)
                    }
                    .padding(.top, 5)
            }
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// System Settings–style coloured rounded square with a white symbol.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 22, height: 22)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Icon + title (+ optional one-line subtitle) used as a form row label.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let tint: Color

    init(_ title: String, subtitle: String? = nil, symbol: String, tint: Color) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Inline warning row with an optional action button.
struct SettingsNotice: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
    }
}

/// Section footer text styled like System Settings.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Coloured dot + status label, optionally prefixed with an app name.
struct PermissionStatusLine: View {
    let status: PermissionStatus
    var prefix: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(prefix.map { "\($0): \(status.label)" } ?? status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// A permission with its status lines, an optional "Request" button and a deep link to System Settings.
struct PermissionRow<Status: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let pane: PrivacyPane
    let canRequest: Bool
    let request: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                status()
            }
            Spacer(minLength: 8)
            if canRequest {
                Button("Request", action: request).controlSize(.small)
            }
            Button("Open Settings") { pane.open() }.controlSize(.small)
        }
    }
}
