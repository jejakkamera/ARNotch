import Foundation
import SwiftUI

/// User preferences, persisted in UserDefaults. Modules read these; SettingsView edits them.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Seconds the pointer must rest on the notch before it opens.
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    /// Album art + visualizer beside the closed notch while music plays.
    @Published var showMediaActivity: Bool { didSet { defaults.set(showMediaActivity, forKey: "showMediaActivity") } }
    /// Brief charging indicator beside the closed notch when power is connected.
    @Published var showChargingActivity: Bool { didSet { defaults.set(showChargingActivity, forKey: "showChargingActivity") } }
    @Published var showCalendar: Bool { didSet { defaults.set(showCalendar, forKey: "showCalendar") } }
    @Published var showMirror: Bool { didSet { defaults.set(showMirror, forKey: "showMirror") } }
    @Published var showBatteryInHeader: Bool { didSet { defaults.set(showBatteryInHeader, forKey: "showBatteryInHeader") } }
    /// Open straight to the Shelf tab when files are dragged onto the notch.
    @Published var openShelfOnDrag: Bool { didSet { defaults.set(openShelfOnDrag, forKey: "openShelfOnDrag") } }
    @Published var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            AppDelegate.shared?.setStatusItemVisible(showMenuBarIcon)
        }
    }

    private init() {
        defaults.register(defaults: [
            "hoverDelay": 0.12,
            "hapticsEnabled": true,
            "showMediaActivity": true,
            "showChargingActivity": true,
            "showCalendar": true,
            "showMirror": true,
            "showBatteryInHeader": true,
            "openShelfOnDrag": true,
            "showMenuBarIcon": true,
        ])
        hoverDelay = defaults.double(forKey: "hoverDelay")
        hapticsEnabled = defaults.bool(forKey: "hapticsEnabled")
        showMediaActivity = defaults.bool(forKey: "showMediaActivity")
        showChargingActivity = defaults.bool(forKey: "showChargingActivity")
        showCalendar = defaults.bool(forKey: "showCalendar")
        showMirror = defaults.bool(forKey: "showMirror")
        showBatteryInHeader = defaults.bool(forKey: "showBatteryInHeader")
        openShelfOnDrag = defaults.bool(forKey: "openShelfOnDrag")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
    }
}
