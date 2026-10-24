import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: NotchMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        allowsToolTipsWhenApplicationIsInactive = true
        ignoresMouseEvents = true
        // Clicks on buttons must not take keyboard focus from the user's app; only text fields make it key.
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that never asks the panel to become key for its own (SwiftUI-drawn) controls.
/// Embedded AppKit text fields still do, so the Timer label stays editable.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override var needsPanelToBecomeKey: Bool { false }
}

/// Owns the notch panel and decides when it opens and closes based on the pointer position.
@MainActor
final class NotchWindowController {
    let viewModel = NotchViewModel()

    private let panel = NotchPanel()
    /// Invisible drop target over the hardware notch: Finder drags never reach the mouse monitors,
    /// so this is what notices a file arriving and opens the Shelf.
    private let dropCatcher = NotchDropCatcher()
    /// True from the moment a drag enters the notch until the mouse button is released.
    private var dragActive = false
    private var screen: NSScreen?
    private var monitors: [Any] = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var exitTimer: Timer?
    /// Set when the notch was opened by a command rather than the pointer: until then it doesn't auto-close.
    private var pointerDeadline: Date?
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount
    private var cancellables = Set<AnyCancellable>()

    init() {
        let root = NotchRootView()
            .environmentObject(viewModel)
            .environmentObject(AppSettings.shared)
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting

        dropCatcher.onDragEntered = { [weak self] in self?.dragEntered() }
        dropCatcher.onDrop = { [weak self] pasteboard in self?.dropped(pasteboard) ?? false }
        dropCatcher.onPointer = { [weak self] in self?.handlePointer(isDragging: false) }

        reposition()
        panel.orderFrontRegardless()
        dropCatcher.orderFrontRegardless()
        installMouseMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.panel.orderFrontRegardless() }
            .store(in: &cancellables)

        viewModel.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.statusChanged(status) }
            .store(in: &cancellables)
    }

    private func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        self.screen = screen
        viewModel.updateGeometry(for: screen)
        let size = NotchMetrics.panelSize
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        let notch = viewModel.notchSize
        dropCatcher.setFrame(NSRect(x: screen.frame.midX - notch.width / 2, y: screen.frame.maxY - notch.height,
                                    width: notch.width, height: notch.height), display: false)
    }

    // MARK: File drags onto the notch

    private func dragEntered() {
        guard AppSettings.shared.openShelfOnDrag || viewModel.isOpen else { return }
        dragActive = true
        cancelOpen()
        viewModel.open(tab: .shelf)
        // The opened panel must sit above the catcher and accept the drop itself.
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    /// A drop that landed on the catcher itself (before the panel took over).
    private func dropped(_ pasteboard: NSPasteboard) -> Bool {
        dragActive = false
        viewModel.open(tab: .shelf)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            ShelfStore.shared.add(urls: urls)
            return true
        }
        let providers = (pasteboard.pasteboardItems ?? []).compactMap { item -> NSItemProvider? in
            if let text = item.string(forType: .string) { return NSItemProvider(object: text as NSString) }
            if let data = item.data(forType: .png) ?? item.data(forType: .tiff), let image = NSImage(data: data) {
                return NSItemProvider(object: image)
            }
            return nil
        }
        return !providers.isEmpty && ShelfStore.shared.handleDrop(providers)
    }

    /// Opens the notch from a command (the menu bar item) while the pointer is elsewhere. It stays open until
    /// the pointer has visited it once, or for a few seconds if it never does.
    func openWithoutPointer(tab: NotchTab) {
        pointerDeadline = Date().addingTimeInterval(4)
        viewModel.open(tab: tab)
    }

    private func statusChanged(_ status: NotchViewModel.Status) {
        exitTimer?.invalidate()
        exitTimer = nil
        if status == .closed {
            panel.ignoresMouseEvents = true
            pointerDeadline = nil
            // Typing in the Timer label made the panel key; hand keyboard focus back to the user's app.
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        } else {
            updateMouseCapture()
            // Mouse events stop reaching the global monitor once the pointer is over our own panel,
            // so poll while open to notice the pointer leaving reliably.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.handlePointer(isDragging: NSEvent.pressedMouseButtons & 1 != 0) }
            }
            RunLoop.main.add(timer, forMode: .common)
            exitTimer = timer
        }
    }

    // MARK: Pointer tracking

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        case .leftMouseUp:
            dragActive = false
            handlePointer(isDragging: false)
        case .leftMouseDragged:
            handlePointer(isDragging: true)
        default:
            handlePointer(isDragging: false)
        }
    }

    private func handlePointer(isDragging: Bool) {
        guard let screen else { return }
        let point = NSEvent.mouseLocation

        switch viewModel.status {
        case .closed:
            let size = viewModel.shapeSize
            let hot = NSRect(
                x: screen.frame.midX - size.width / 2 - 6,
                y: screen.frame.maxY - size.height - 4,
                width: size.width + 12,
                height: size.height + 4
            )
            guard NSMouseInRect(point, hot, false) else {
                cancelOpen()
                return
            }
            if isDragging {
                // Only react to real drag sessions (files, text…), not window moves or selections.
                let fileDrag = NSPasteboard(name: .drag).changeCount != dragPasteboardCount
                if fileDrag && AppSettings.shared.openShelfOnDrag {
                    cancelOpen()
                    viewModel.open(tab: .shelf)
                }
                return
            }
            scheduleOpen()

        case .open:
            updateMouseCapture()
            let shape = openShapeRect(on: screen)
            let area = NSRect(x: shape.minX - 10, y: shape.minY - 10, width: shape.width + 20, height: shape.height + 10)
            // NSMouseInRect (unlike CGRect.contains) counts the top screen edge, where a pushed-up pointer rests.
            let inside = NSMouseInRect(point, area, false)
            if inside { pointerDeadline = nil }
            let awaitingPointer = pointerDeadline.map { Date() < $0 } ?? false
            if inside || viewModel.keepOpen || awaitingPointer || dragActive {
                cancelClose()
            } else {
                scheduleClose()
            }
        }
    }

    private func openShapeRect(on screen: NSScreen) -> NSRect {
        let size = viewModel.openSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// While open, take mouse events only over the visible shape (or during a drag, for drops and drag-outs).
    /// An explicit `ignoresMouseEvents = false` would make the panel's transparent margins swallow clicks.
    /// Only call while open (`statusChanged` runs before `viewModel.status` itself changes).
    private func updateMouseCapture() {
        guard let screen else { return }
        if dragActive && NSEvent.pressedMouseButtons & 1 == 0 { dragActive = false }
        let ignores = !dragActive && NSEvent.pressedMouseButtons & 1 == 0
            && !NSMouseInRect(NSEvent.mouseLocation, openShapeRect(on: screen), false)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func scheduleOpen() {
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openWork = nil
            self.viewModel.open()
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.hoverDelay, execute: work)
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            self.viewModel.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }
}

/// Transparent window over the hardware notch that only cares about drags. It never draws and
/// covers just the notch cutout, where the menu bar has nothing to click.
final class NotchDropCatcher: NSPanel {
    var onDragEntered: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?
    /// The pointer moved over the catcher: those events no longer reach the global mouse monitor.
    var onPointer: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = DropView()
        view.owner = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class DropView: NSView {
        weak var owner: NotchDropCatcher?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { owner?.onPointer?() }
        override func mouseMoved(with event: NSEvent) { owner?.onPointer?() }
        override func mouseExited(with event: NSEvent) { owner?.onPointer?() }
        // A click on the bare notch opens it too (there is nothing else to click there).
        override func mouseDown(with event: NSEvent) { owner?.onPointer?() }

        required init?(coder: NSCoder) { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            owner?.onDragEntered?()
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            owner?.onDrop?(sender.draggingPasteboard) ?? false
        }
    }
}
