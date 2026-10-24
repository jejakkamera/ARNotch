import AppKit
import CoreGraphics

/// Mirror / extend through the public Quartz display-configuration API. Calls block while the
/// window server reconfigures, so callers run them off the main thread.
enum DisplayArrangement {
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { CGGetOnlineDisplayList(UInt32($0.count), $0.baseAddress, &count) }
        return status == .success ? Array(ids.prefix(Int(count))) : []
    }

    /// The built-in panel, if it is on (not in clamshell mode).
    static func builtInDisplay() -> CGDirectDisplayID? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Mirrors `external` onto the built-in display, so it shows the same picture.
    static func mirror(_ external: CGDirectDisplayID) -> Bool {
        guard let builtIn = builtInDisplay(), builtIn != external else { return false }
        return configure { config in
            CGConfigureDisplayMirrorOfDisplay(config, external, builtIn)
        }
    }

    /// Ends every mirror set so each display gets its own desktop again.
    static func extend() -> Bool {
        configure { config in
            var result = CGError.success
            for id in onlineDisplays() where CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
                let error = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
                if error != .success { result = error }
            }
            return result
        }
    }

    private static func configure(_ body: (CGDisplayConfigRef) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard body(config) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}

/// Covers chosen displays with a black panel, e.g. to hide a projector while preparing notes.
/// Independent of the Connectivity tab: blanking stays on after the notch closes and ends when
/// the display disconnects, when the user double-clicks the black screen, or when Crest quits.
@MainActor
final class DisplayBlanker: ObservableObject {
    static let shared = DisplayBlanker()

    @Published private(set) var blanked: Set<CGDirectDisplayID> = []
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func isBlanked(_ id: CGDirectDisplayID) -> Bool { blanked.contains(id) }

    func toggle(_ id: CGDirectDisplayID) {
        if blanked.contains(id) { unblank(id) } else { blank(id) }
    }

    func blank(_ id: CGDirectDisplayID) {
        guard panels[id] == nil, let screen = Self.screen(for: id) else { return }
        let panel = BlankPanel(screen: screen) { [weak self] in self?.unblank(id) }
        panel.orderFrontRegardless()
        panels[id] = panel
        blanked.insert(id)
        observeScreens()
    }

    func unblank(_ id: CGDirectDisplayID) {
        panels.removeValue(forKey: id)?.orderOut(nil)
        blanked.remove(id)
        if panels.isEmpty, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    func unblankAll() {
        for id in Array(panels.keys) { unblank(id) }
    }

    private func observeScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DisplayBlanker.shared.screensChanged() }
        }
    }

    /// Follows resolution changes; drops panels whose display left or joined a mirror set
    /// (a black window there would also hide the built-in screen).
    private func screensChanged() {
        for (id, panel) in panels {
            if let screen = Self.screen(for: id), CGDisplayIsInMirrorSet(id) == 0 {
                panel.setFrame(screen.frame, display: true)
            } else {
                unblank(id)
            }
        }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }
}

/// Opaque black, above full-screen apps and the menu bar, never takes focus, swallows clicks.
private final class BlankPanel: NSPanel {
    init(screen: NSScreen, onDoubleClick: @escaping () -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = DoubleClickView(onDoubleClick: onDoubleClick)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DoubleClickView: NSView {
    private let onDoubleClick: () -> Void

    init(onDoubleClick: @escaping () -> Void) {
        self.onDoubleClick = onDoubleClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { onDoubleClick() }
    }
}
