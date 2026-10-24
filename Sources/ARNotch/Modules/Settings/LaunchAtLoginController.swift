import Foundation
import ServiceManagement

/// Registers Crest as a login item via SMAppService. Service calls run off the main thread.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isBusy = false
    /// Last failure, shown under the toggle.
    @Published private(set) var errorMessage: String?

    /// Registered, possibly still awaiting the user's approval in System Settings.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// SMAppService only works for a real .app bundle, not the bare `swift run` executable.
    static var isRunningFromAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func refresh() {
        guard !isBusy else { return }
        Task {
            status = await Self.offMain { SMAppService.mainApp.status }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy, enabled != isEnabled else { return }
        guard Self.isRunningFromAppBundle else {
            // Assigning republishes, which also snaps the toggle back.
            errorMessage = "Only available when running ARNotch.app, not the bare executable."
            return
        }
        isBusy = true
        errorMessage = nil
        Task {
            let (newStatus, failure) = await Self.offMain { () -> (SMAppService.Status, String?) in
                let service = SMAppService.mainApp
                do {
                    if enabled { try service.register() } else { try service.unregister() }
                    return (service.status, nil)
                } catch {
                    return (service.status, error.localizedDescription)
                }
            }
            status = newStatus
            errorMessage = failure.map { "Couldn't update the login item: \($0)" }
            isBusy = false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
