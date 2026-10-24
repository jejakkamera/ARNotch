import AppKit
import SwiftUI

/// Three independent scroll columns keep categories in place even when many devices are attached.
struct ConnectivityTabView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var store = ConnectivityStore.shared
    @ObservedObject private var blanker = DisplayBlanker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LayerPulsingDot(color: .green.opacity(0.7), isPulsing: store.count > 0, pulse: .slow)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text("CONNECTED TO YOUR MAC")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                Button { store.enableBluetooth() } label: {
                    Label(store.bluetoothStatus, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(store.bluetoothEnabled ? 0.7 : 0.45))
                .disabled(store.isRequestingBluetooth)
                .help("Read connected Bluetooth devices. No pairing or discovery scan.")
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(SystemPillStyle())
                .disabled(store.isRefreshing)
                .accessibilityLabel("Refresh connected devices")
            }

            HStack(alignment: .top, spacing: 8) {
                category("Audio", symbol: "headphones", count: store.audio.filter(\.hasOutput).count, tint: Color(red: 0.55, green: 0.75, blue: 0.85)) {
                    if store.audio.isEmpty {
                        emptyState("speaker.slash", title: store.hasLoaded ? "No audio devices" : "Reading devices…",
                                   detail: "Outputs and microphones appear here.")
                    } else {
                        ForEach(store.visibleAudio) { device in audioRow(device) }
                    }
                } action: { store.openSoundSettings() }

                category("Displays", symbol: "display", count: store.displays.count, tint: Color(red: 0.72, green: 0.65, blue: 0.85)) {
                    if store.displays.isEmpty {
                        emptyState("display", title: "No external display", detail: "Connect a monitor, projector, or AirPlay display.")
                    } else {
                        ForEach(store.displays) { display in displayRow(display) }
                    }
                } action: { store.openDisplaySettings() }

                category("Peripherals", symbol: "computermouse.fill", count: store.visiblePeripherals.count, tint: Color(red: 0.6, green: 0.8, blue: 0.72)) {
                    if store.visiblePeripherals.isEmpty {
                        emptyState("cable.connector", title: store.hasLoaded ? "No peripherals found" : "Reading devices…",
                                   detail: "USB and HID devices appear here. Allow Bluetooth to include other accessories.")
                    } else {
                        ForEach(store.visiblePeripherals) { device in peripheralRow(device) }
                        if !store.bluetoothEnabled {
                            Text("Include Bluetooth to read wireless batteries")
                                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                                .padding(.leading, 2)
                        }
                    }
                } action: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.audio.map(\.id))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.displays.map(\.id))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: store.visiblePeripherals.map(\.id))

            if let message = store.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .onAppear {
            store.appear { requesting in
                if requesting { vm.hold(.connectivityPrompt) }
                else { vm.release(.connectivityPrompt) }
            }
        }
        .onDisappear {
            vm.release(.connectivityPrompt)
            vm.release(.connectivityVolume)
            store.disappear()
        }
    }

    private func category<Content: View>(_ title: String, symbol: String, count: Int, tint: Color,
                                        @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint.opacity(0.65))
                Text(title).fontWeight(.semibold)
                Text("\(count)").foregroundStyle(.white.opacity(0.4)).monospacedDigit()
                Spacer(minLength: 0)
                Button(action: action) {
                    Image(systemName: "arrow.up.right").font(.system(size: 8))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .accessibilityLabel("Open \(title) settings")
            }
            .font(.system(size: 10))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(9)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Neutral cards; the category colour only appears, softened, on the header icon.
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    // MARK: Audio — one line per device; only the active output gets a volume slider.

    @ViewBuilder
    private func audioRow(_ device: ConnectedAudio) -> some View {
        if device.hasOutput {
            outputRow(device)
        } else {
            inputRow(device)
        }
    }

    private func outputRow(_ device: ConnectedAudio) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { if !device.isDefault { store.select(device) } } label: {
                HStack(spacing: 7) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(device.isDefault ? 0.9 : 0.45))
                        .frame(width: 18)
                    Text(device.name)
                        .font(.system(size: 10, weight: device.isDefault ? .semibold : .regular))
                        .foregroundStyle(device.isDefault ? Color.white : .white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let battery = device.batteries.first { batteryBadge(battery) }
                    Image(systemName: device.isDefault ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(device.isDefault ? 0.85 : 0.22))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(device.isDefault ? "\(device.name) · \(device.transport) · current output" : "Use \(device.name) (\(device.transport))")
            .accessibilityLabel(device.isDefault ? "\(device.name), current output" : "Use \(device.name) as output")

            if device.isDefault {
                if device.canSetVolume {
                    HStack(spacing: 5) {
                        Button { store.toggleMute(device) } label: {
                            Image(systemName: device.isMuted == true ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .font(.system(size: 9)).frame(width: 18, height: 16)
                        }
                        .buttonStyle(.plain)
                        .disabled(!device.canMute)
                        .foregroundStyle(device.isMuted == true ? Color.orange : .white.opacity(0.6))
                        .accessibilityLabel(device.isMuted == true ? "Unmute \(device.name)" : "Mute \(device.name)")
                        Slider(value: Binding(get: { store.displayedVolume(device) }, set: { store.setVolume($0, on: device) }), in: 0...1) { editing in
                            if editing { vm.hold(.connectivityVolume) }
                            else { vm.release(.connectivityVolume) }
                        }
                        .controlSize(.mini)
                        .tint(Color.white.opacity(0.75))
                        .accessibilityLabel("\(device.name) volume")
                        Text("\(Int((store.displayedVolume(device) * 100).rounded()))")
                            .font(.system(size: 9).monospacedDigit())
                            .frame(width: 20, alignment: .trailing)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    Text("Volume is set on the device")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                        .padding(.leading, 25)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(device.isDefault ? 0.07 : 0.025)))
        .transition(.opacity)
    }

    private func inputRow(_ device: ConnectedAudio) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill").font(.system(size: 10)).frame(width: 18)
            Text(device.name).font(.system(size: 9)).lineLimit(1)
            Spacer(minLength: 0)
            if let battery = device.batteries.first { batteryBadge(battery) }
        }
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 7)
        .help("\(device.name) · \(device.transport) · microphone")
        .transition(.opacity)
    }

    // MARK: Displays — Extend / Mirror / Blank

    private func displayRow(_ display: ConnectedDisplay) -> some View {
        let blanked = blanker.isBlanked(display.id)
        let busy = store.arrangingDisplay == display.id
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: blanked ? "display.trianglebadge.exclamationmark" : "display")
                    .font(.system(size: 16))
                    .foregroundStyle(blanked ? Color.orange.opacity(0.85) : .white.opacity(0.7))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Text(blanked ? "Screen hidden · double-click it to show" : display.detail)
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(blanked ? Color.orange.opacity(0.85) : .white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 4) {
                modeButton("Extend", symbol: "rectangle.split.2x1", selected: !display.isMirrored && !blanked,
                           enabled: !busy && display.isMirrored) { store.extend(display) }
                modeButton("Mirror", symbol: "rectangle.on.rectangle", selected: display.isMirrored,
                           enabled: !busy && !display.isMirrored && store.builtInOnline) { store.mirror(display) }
                modeButton(blanked ? "Show" : "Blank", symbol: blanked ? "eye.fill" : "eye.slash.fill", selected: blanked,
                           tint: .orange, enabled: !busy && !display.isMirrored) { store.toggleBlank(display) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(blanked ? Color.orange.opacity(0.08) : .white.opacity(0.035)))
        .transition(.opacity)
    }

    private func modeButton(_ title: String, symbol: String, selected: Bool, tint: Color = .white,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 8, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? tint.opacity(0.16) : .white.opacity(0.04)))
            .foregroundStyle(selected ? Color.white : .white.opacity(enabled ? 0.75 : 0.3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hit-testing instead of .disabled so the selected mode keeps full brightness.
        .allowsHitTesting(enabled && (!selected || title == "Show"))
        .help(modeHelp(title))
    }

    private func modeHelp(_ title: String) -> String {
        switch title {
        case "Extend": "Use the display as a separate desktop"
        case "Mirror": store.builtInOnline ? "Show the same picture as the MacBook screen" : "Open the lid to mirror"
        case "Blank": "Turn the display black until you show it again"
        default: "Show the display again"
        }
    }

    // MARK: Peripherals

    private func peripheralRow(_ device: ConnectedPeripheral) -> some View {
        HStack(spacing: 7) {
            Image(systemName: peripheralSymbol(device))
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(device.transport).font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 4)
            if device.batteries.isEmpty {
                Image(systemName: device.transport == "USB" ? "powerplug.fill" : "minus")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
                    .help(device.transport == "USB" ? "Powered over USB" : "This device doesn't report its battery")
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(device.batteries) { batteryBadge($0) }
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.035)))
        .help(device.batteries.isEmpty ? device.name : device.name + " · " + device.batteries.map { "\($0.label) \($0.percent)%" }.joined(separator: ", "))
        .transition(.opacity)
    }

    /// The registry reports some mice (e.g. Logitech MX Master) with a keyboard usage; the name is a better hint.
    private func peripheralSymbol(_ device: ConnectedPeripheral) -> String {
        let name = device.name.lowercased()
        if name.contains("mouse") || name.contains("mx master") || name.contains("mx anywhere") { return "computermouse.fill" }
        return device.symbol
    }

    /// Battery glyph + percentage; orange at 20% or less.
    private func batteryBadge(_ part: ConnectionBattery) -> some View {
        let low = part.percent <= 20
        return HStack(spacing: 3) {
            if part.label != "Battery" {
                Text(part.label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            BatteryGlyph(level: Double(part.percent) / 100, fill: low ? .orange : Color.green.opacity(0.75))
                .frame(width: 18, height: 9)
            Text("\(part.percent)%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(low ? Color.orange : .white.opacity(0.85))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(part.label), \(part.percent) percent")
    }

    private func emptyState(_ symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LayerGlyph(.symbol(symbol, size: 23), color: .white.opacity(0.18))
                .frame(width: 30, height: 32).accessibilityHidden(true)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.3)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Closed-notch wings while a display is blanked

struct DisplayBlankLiveActivityLeading: View {
    var body: some View {
        Image(systemName: "eye.slash.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .accessibilityLabel("External display hidden")
    }
}

struct DisplayBlankLiveActivityTrailing: View {
    var body: some View {
        Text("Blank")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
    }
}
