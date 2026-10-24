import SwiftUI

/// Timer & alarm preferences, meant to be placed inside the Settings window's `Form`.
struct TimerSettingsSection: View {
    @ObservedObject private var store = TimerStore.shared

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Picker("Alarm sound", selection: $store.alarmSoundName) {
                    ForEach(TimerSounds.available, id: \.self) { name in
                        Text(verbatim: name).tag(name)
                    }
                }
                Button {
                    store.previewAlarmSound()
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play sound")
            }
            .onChange(of: store.alarmSoundName) {
                store.previewAlarmSound()
            }

            Stepper(value: $store.snoozeMinutes, in: 1...60) {
                Text("Snooze length: \(store.snoozeMinutes) min")
            }
        } header: {
            Text("Timer & Alarm")
        } footer: {
            Text("Alarms ring for up to a minute, even if ARNotch's notch is closed. While one is due within 3 hours, the Mac doesn't idle-sleep (the display still can).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
