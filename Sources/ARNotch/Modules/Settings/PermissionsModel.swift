import AppKit
import AVFoundation
import CoreServices
import EventKit
import SwiftUI

/// Simplified privacy status shown in Settings.
enum PermissionStatus: Equatable {
    case checking
    case granted
    case denied
    case notDetermined
    case restricted
    /// Status can't be determined right now (e.g. the target app isn't running).
    case unavailable(String)

    var label: String {
        switch self {
        case .checking: "Checking…"
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not requested yet"
        case .restricted: "Restricted"
        case .unavailable(let reason): reason
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .denied, .restricted: .red
        case .notDetermined: .orange
        case .checking, .unavailable: .secondary
        }
    }
}

/// Privacy panes in System Settings › Privacy & Security.
enum PrivacyPane: String {
    case camera = "Privacy_Camera"
    case calendars = "Privacy_Calendars"
    case automation = "Privacy_Automation"

    var url: URL? { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") }

    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// An app Crest sends Apple Events to.
struct AutomationTarget: Identifiable, Equatable {
    let name: String
    let bundleID: String
    var status: PermissionStatus = .checking
    var id: String { bundleID }
}

/// Reads (and on request, asks for) the permissions Crest's modules rely on.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var camera: PermissionStatus = .checking
    @Published private(set) var calendars: PermissionStatus = .checking
    @Published private(set) var automation: [AutomationTarget] = [
        AutomationTarget(name: "Music", bundleID: "com.apple.Music"),
        AutomationTarget(name: "Spotify", bundleID: "com.spotify.client"),
    ]

    @Published private(set) var isRequestingCalendars = false

    private var automationGeneration = 0

    var canRequestCalendars: Bool { calendars == .notDetermined && !isRequestingCalendars }
    var canRequestAutomation: Bool { automation.contains { $0.status == .notDetermined } }

    func refresh() {
        camera = Self.status(AVCaptureDevice.authorizationStatus(for: .video))
        calendars = Self.status(EKEventStore.authorizationStatus(for: .event))
        refreshAutomation()
    }

    func requestCamera() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            refresh()
        }
    }

    /// The Calendar widget picks up the new status the next time it appears.
    func requestCalendars() {
        guard canRequestCalendars else { return }
        isRequestingCalendars = true
        Task {
            await Self.requestCalendarAccess()
            isRequestingCalendars = false
            refresh()
        }
    }

    /// Triggers the system consent prompt for every running target that hasn't been asked yet.
    func requestAutomation() {
        let pending = automation.filter { $0.status == .notDetermined }.map(\.bundleID)
        Task {
            for bundleID in pending {
                _ = await Self.automationStatus(bundleID: bundleID, askUser: true)
            }
            refreshAutomation()
        }
    }

    // MARK: Private

    private func refreshAutomation() {
        automationGeneration += 1
        let generation = automationGeneration
        let targets = automation.map(\.bundleID)
        Task {
            var results: [String: PermissionStatus] = [:]
            for bundleID in targets {
                results[bundleID] = await Self.automationStatus(bundleID: bundleID, askUser: false)
            }
            // Drop results from a refresh that has since been superseded.
            guard generation == automationGeneration else { return }
            for index in automation.indices {
                automation[index].status = results[automation[index].bundleID] ?? .unavailable("Unknown")
            }
        }
    }

    private static func status(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable("Unknown")
        }
    }

    private static func status(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .unavailable("Add-only access")
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        default: .unavailable("Unknown")
        }
    }

    /// EKEventStore setup connects to the calendar daemon, so the throwaway store is made off the main thread.
    private nonisolated static func requestCalendarAccess() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let store = EKEventStore()
                store.requestFullAccessToEvents { _, _ in
                    withExtendedLifetime(store) { continuation.resume() }
                }
            }
        }
    }

    /// Asks the Apple Event Manager without blocking the main thread; prompts only when `askUser` is set.
    private nonisolated static func automationStatus(bundleID: String, askUser: Bool) async -> PermissionStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: determineAutomation(bundleID: bundleID, askUser: askUser))
            }
        }
    }

    private nonisolated static func determineAutomation(bundleID: String, askUser: Bool) -> PermissionStatus {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return .unavailable("Not installed")
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return .unavailable("Unknown") }
        let result = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser
        )
        switch Int(result) {
        case Int(noErr): return .granted
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notDetermined
        case procNotFound: return .unavailable("Not running")
        default: return .unavailable("Unknown")
        }
    }
}
