import AppKit
import SwiftUI

/// System module preferences, meant to be placed inside the Settings window's `Form`.
struct SystemSettingsSection: View {
    @ObservedObject private var monitor = SystemMonitor.shared

    var body: some View {
        Section {
            Toggle(isOn: $monitor.detectsFrozenApps) {
                SettingsRowLabel(
                    "Detect frozen apps (needs Accessibility)",
                    subtitle: "Marks apps that stop responding in the System tab, with a Force Quit button.",
                    symbol: "snowflake", tint: .cyan
                )
            }

            if monitor.detectsFrozenApps {
                accessibilityStatus
            }
        } header: {
            Text("System")
        } footer: {
            SettingsFooter("Metrics are only measured while the notch is open. ARNotch never quits an app without a click. After rebuilding or updating ARNotch, macOS may need Accessibility access granted again: remove ARNotch from the list and add it back.")
        }
        .onAppear { monitor.refreshAccessibilityTrust() }
        // Coming back from System Settings re-activates Crest.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            monitor.refreshAccessibilityTrust()
        }
    }

    @ViewBuilder
    private var accessibilityStatus: some View {
        if monitor.isAccessibilityTrusted {
            HStack(spacing: 8) {
                PermissionStatusLine(status: .granted, prefix: "Accessibility")
                Spacer(minLength: 8)
                Button("Open Settings") { monitor.openAccessibilitySettings() }
                    .controlSize(.small)
            }
        } else {
            SettingsNotice(
                text: "Allow ARNotch in System Settings › Privacy & Security › Accessibility.",
                symbol: "hand.raised.fill", tint: .orange,
                actionTitle: "Grant Access…", action: { monitor.requestAccessibilityAccess() }
            )
        }
    }
}
