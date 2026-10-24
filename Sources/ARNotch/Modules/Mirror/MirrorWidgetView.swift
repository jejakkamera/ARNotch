import SwiftUI

/// Camera "mirror" on the Home tab (120×120 pt). Click to turn the camera on or off;
/// it always turns off when the widget disappears (notch closes, tab changes, widget hidden).
struct MirrorWidgetView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var camera = MirrorCameraController.shared
    /// Plain `State` rather than `@State`: with the macOS 27 SDK `@State` is a macro whose plugin
    /// ships only with Xcode, not the Command Line Tools this project builds with.
    private let hover = State(initialValue: false)
    private var isHovering: Bool { hover.wrappedValue }
    private let flash = State(initialValue: false)

    private let cornerRadius: CGFloat = 16
    private var tile: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        ZStack {
            tile.fill(Color.white.opacity(isHovering && camera.state != .running ? 0.12 : 0.08))

            // Attach the preview only once startRunning has returned: attaching it from the main thread
            // while the capture queue is starting the session mutates the session's connection list
            // mid-enumeration, which AVFoundation answers with an exception (crash).
            if camera.state == .running {
                MirrorPreviewView(session: camera.session, isRunning: true, cornerRadius: cornerRadius)
                    .transition(.opacity)
            }

            overlay

            // Shutter flash.
            Color.white
                .opacity(flash.wrappedValue ? 0.85 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            if camera.isRecording {
                tile.strokeBorder(Color.red.opacity(0.85), lineWidth: 2)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(tile)
        .contentShape(tile)
        .onTapGesture(perform: handleTap)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeInOut(duration: 0.25), value: camera.state)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(helpText)
        .onAppear { camera.refresh() }
        .onDisappear(perform: turnOff)
        // Belt and braces: onDisappear can lag behind the close animation.
        .onChange(of: vm.isOpen) { _, isOpen in
            if !isOpen { turnOff() }
        }
        .onChange(of: vm.tab) { _, tab in
            if tab != .home { turnOff() }
        }
        // Keep the notch open while the user answers the camera prompt outside it.
        .onChange(of: camera.holdsNotchOpen) { _, hold in
            hold ? vm.hold(.mirrorPrompt) : vm.release(.mirrorPrompt)
        }
        // Keep the notch open for the whole recording, so the movie isn't cut short by the pointer leaving.
        .onChange(of: camera.isRecording) { _, recording in
            recording ? vm.hold(.mirrorRecording) : vm.release(.mirrorRecording)
        }
        .onChange(of: camera.shutterCount) { _, _ in
            flash.wrappedValue = true
            withAnimation(.easeOut(duration: 0.35)) { flash.wrappedValue = false }
        }
    }

    // MARK: States

    @ViewBuilder
    private var overlay: some View {
        switch camera.state {
        case .idle:
            placeholder(symbol: "person.crop.square", title: "Mirror")
        case .requestingAccess, .starting:
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text(camera.state == .requestingAccess ? "Waiting for access" : "Starting…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .transition(.opacity)
        case .running:
            ZStack {
                if isHovering && !camera.isRecording { stopBadge }
                if camera.isRecording { recordingBadge }
                if isHovering || camera.isRecording { captureControls }
                if let notice = camera.notice { noticeLabel(notice) }
            }
            .transition(.opacity)
        case .denied:
            deniedView
        case .unavailable:
            placeholder(symbol: "video.slash", title: "No camera")
        case .failed:
            placeholder(symbol: "exclamationmark.triangle", title: "Camera error", subtitle: "Click to retry")
        }
    }

    private func placeholder(symbol: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.white.opacity(isHovering ? 0.85 : 0.6))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 8)
        .transition(.opacity)
    }

    private var stopBadge: some View {
        Image(systemName: "video.slash.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Bottom bar: shutter (photo) and record / stop (video).
    private var captureControls: some View {
        HStack(spacing: 10) {
            if !camera.isRecording {
                Button(action: camera.takePhoto) {
                    ZStack {
                        Circle().strokeBorder(Color.white, lineWidth: 2)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Take photo (saved to Pictures › ARNotch)")
                .accessibilityLabel("Take photo")
            }
            Button(action: camera.toggleRecording) {
                ZStack {
                    Circle().strokeBorder(Color.white, lineWidth: 2)
                    Image(systemName: camera.isRecording ? "stop.fill" : "video.fill")
                        .font(.system(size: camera.isRecording ? 9 : 10, weight: .semibold))
                        .foregroundStyle(Color.red)
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(camera.isRecording ? "Stop recording" : "Record video (saved to Movies › ARNotch)")
            .accessibilityLabel(camera.isRecording ? "Stop recording" : "Record video")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// "● 0:12" while recording.
    private var recordingBadge: some View {
        TimelineView(.periodic(from: camera.recordingStartedAt ?? Date(), by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(camera.recordingStartedAt ?? context.date))
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.5)))
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func noticeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var deniedView: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.6))
            Text("Camera access\nis turned off")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Button {
                camera.openPrivacySettings()
                vm.close()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .transition(.opacity)
    }

    // MARK: Actions

    private func turnOff() {
        camera.stop()
        vm.release(.mirrorPrompt)
    }

    private func handleTap() {
        switch camera.state {
        case .denied:
            break // The "Open Settings" button handles this state.
        case .unavailable:
            camera.refresh()
        default:
            if camera.isRecording { camera.toggleRecording() } else { camera.toggle() }
        }
    }

    private var helpText: String {
        switch camera.state {
        case .running: return camera.isRecording ? "Recording… click the stop button to finish" : "Click to turn off · use the buttons to take a photo or record"
        case .starting, .requestingAccess: return "Turn off camera"
        case .denied: return "Allow camera access in System Settings"
        case .unavailable: return "No camera found"
        default: return "Turn on camera"
        }
    }
}
