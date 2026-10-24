import AppKit
import SwiftUI

@main
enum CrestMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MediaController.shared.start()
        BatteryMonitor.shared.start()
        TimerStore.shared.start()
        PomodoroStore.shared.start()
        DevPortsStore.shared.start()
        notchController = NotchWindowController()
        setupStatusItem()

        // Debug aids: `Crest --debug-open [home|shelf|timer]` opens the notch and keeps it open;
        // `Crest --debug-timer <seconds>` starts a short countdown.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--debug-timer"),
           args.indices.contains(index + 1), let seconds = TimeInterval(args[index + 1]) {
            _ = TimerStore.shared.startCountdown(duration: seconds, label: "Debug")
        }
        if let index = args.firstIndex(of: "--debug-open") {
            let tab = args.indices.contains(index + 1) ? NotchTab(rawValue: args[index + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.notchController?.viewModel.hold(.debug)
                self?.notchController?.viewModel.open(tab: tab ?? .home)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "ARNotch")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Notch", action: #selector(openNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ARNotch", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        item.isVisible = AppSettings.shared.showMenuBarIcon
        statusItem = item
    }

    func setStatusItemVisible(_ visible: Bool) {
        statusItem?.isVisible = visible
    }

    @objc private func openNotch() {
        notchController?.openWithoutPointer(tab: .home)
    }

    @objc func openSettings() {
        notchController?.viewModel.close()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(AppSettings.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ARNotch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
