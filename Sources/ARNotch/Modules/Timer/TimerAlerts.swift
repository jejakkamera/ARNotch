import AppKit
import UserNotifications

/// Alert sounds the user can pick for alarms (system, local and user sound folders).
enum TimerSounds {
    private static let fileExtensions: Set<String> = ["aiff", "aif", "caf", "wav", "m4a", "mp3"]

    private static var directories: [URL] {
        [
            URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
            URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true),
        ]
    }

    /// Always shipped with macOS; used when nothing else can be loaded.
    static let fallbackName = "Glass"

    /// Sorted, de-duplicated sound names (file names without extension).
    static let available: [String] = {
        var names = Set<String>()
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where fileExtensions.contains(file.pathExtension.lowercased()) {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        names.insert(fallbackName)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    /// "Radar" when installed, otherwise "Glass".
    static var defaultName: String {
        available.contains("Radar") ? "Radar" : fallbackName
    }

    /// A fresh (unshared) sound instance, so looping one never affects another.
    static func makeSound(named name: String) -> NSSound? {
        for directory in directories {
            for ext in fileExtensions {
                let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: url.path),
                   let sound = NSSound(contentsOf: url, byReference: true) {
                    return sound
                }
            }
        }
        return NSSound(named: NSSound.Name(name))?.copy() as? NSSound
    }
}

/// Plays the looping alarm and one-shot previews.
@MainActor
final class TimerAlertPlayer {
    private var ringSound: NSSound?
    private var previewSound: NSSound?

    /// Starts the looping alarm unless it is already playing.
    func startRinging(soundName: String) {
        guard ringSound == nil else { return }
        stopPreview()
        guard let sound = TimerSounds.makeSound(named: soundName) ?? TimerSounds.makeSound(named: TimerSounds.fallbackName) else {
            NSSound.beep()
            return
        }
        sound.loops = true
        sound.play()
        ringSound = sound
    }

    func stopRinging() {
        ringSound?.stop()
        ringSound = nil
    }

    /// Plays a sound once (Settings preview, alarms that went off while the Mac was asleep).
    func playOnce(soundName: String) {
        stopPreview()
        guard ringSound == nil,
              let sound = TimerSounds.makeSound(named: soundName) ?? TimerSounds.makeSound(named: TimerSounds.fallbackName)
        else { return }
        sound.loops = false
        sound.play()
        previewSound = sound
    }

    private func stopPreview() {
        previewSound?.stop()
        previewSound = nil
    }
}

/// Posts "time's up" banners through Notification Center. Every call is a no-op when Crest
/// does not run from an app bundle (UNUserNotificationCenter traps without one).
@MainActor
final class TimerNotifier {
    private var didRequestAuthorization = false
    private var deliveredIdentifiers: [String] = []

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks for permission once per launch; denial is fine, banners are just skipped.
    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization, isAvailable else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts one banner for `fired`. Banners for `missed` items (long overdue, never rang) stay in
    /// Notification Center; the others are removed once the user handles the alarm in the notch.
    func post(_ fired: [FiredTimer], missed: Bool = false) {
        guard isAvailable, let first = fired.first else { return }
        let content = UNMutableNotificationContent()
        if fired.count == 1 {
            if missed {
                content.title = first.item.kind == .alarm ? "Missed alarm" : "Missed timer"
            } else {
                content.title = first.item.kind == .alarm ? "Alarm" : "Time's up!"
            }
            content.body = first.wasLate
                ? "\(first.item.title) — was due at \(TimerFormat.timeOfDay(first.dueDate))"
                : first.item.title
        } else {
            content.title = missed ? "\(fired.count) missed timers" : "\(fired.count) timers finished"
            content.body = fired.map(\.item.title).joined(separator: ", ")
        }
        // Crest plays its own looping sound.
        content.sound = nil

        let identifier = "crest.timer.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        if !missed { deliveredIdentifiers.append(identifier) }
    }

    /// Removes banners for alarms the user already handled in the notch.
    func removeDelivered() {
        guard isAvailable, !deliveredIdentifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        deliveredIdentifiers.removeAll()
    }

    /// Keeps the banners (e.g. for missed alarms) but stops tracking them.
    func forgetDelivered() {
        deliveredIdentifiers.removeAll()
    }
}
