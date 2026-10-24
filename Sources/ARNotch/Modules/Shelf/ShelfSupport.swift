import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: Actions

/// File actions shared by tiles, buttons and context menus.
@MainActor
enum ShelfActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Opens the system AirDrop sheet for the given files; beeps when there is nothing AirDrop can send.
    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else {
            NSSound.beep()
            return
        }
        // We are an accessory app; bring the AirDrop window to the front.
        NSApp.activate()
        service.perform(withItems: urls)
    }
}

// MARK: Keeping the notch open

/// Holds the notch open for shelf interactions that leave the notch area (drag-outs, context menus, share
/// pickers). Each maps to its own `NotchViewModel.HoldReason`, so releasing never drops anyone else's hold.
@MainActor
final class ShelfKeepOpen {
    static let shared = ShelfKeepOpen()

    enum Reason: Hashable, CaseIterable {
        case dragOut, menu, sharing

        var holdReason: NotchViewModel.HoldReason {
            switch self {
            case .dragOut: .shelfDragOut
            case .menu: .shelfMenu
            case .sharing: .shelfSharing
            }
        }
    }

    private weak var viewModel: NotchViewModel?
    private var menuDepth = 0

    func hold(_ reason: Reason, on viewModel: NotchViewModel) {
        self.viewModel = viewModel
        viewModel.hold(reason.holdReason)
    }

    func release(_ reason: Reason) {
        viewModel?.release(reason.holdReason)
    }

    func releaseAll() {
        menuDepth = 0
        Reason.allCases.forEach(release)
    }

    /// Menus (context menus, share pickers) extend below the notch; keep it open while one is tracking.
    func menuDidBeginTracking(on viewModel: NotchViewModel) {
        menuDepth += 1
        if menuDepth == 1 { hold(.menu, on: viewModel) }
    }

    func menuDidEndTracking() {
        menuDepth = max(0, menuDepth - 1)
        if menuDepth == 0 { release(.menu) }
    }
}

/// Keeps the notch open while a tile is dragged out, until the next left mouse-up.
@MainActor
final class ShelfDragOut {
    static let shared = ShelfDragOut()

    private var monitors: [Any] = []
    private var fallbackTimer: Timer?

    func begin(viewModel: NotchViewModel) {
        ShelfKeepOpen.shared.hold(.dragOut, on: viewModel)
        guard monitors.isEmpty else { return }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.end() }
            return event
        }) {
            monitors.append(local)
        }
        // AppKit's drag loop may consume the mouse-up before any monitor sees it, so also watch the button
        // state while (and only while) the drag lasts.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.end() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func end() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        ShelfKeepOpen.shared.release(.dragOut)
    }
}

// MARK: Sharing

/// Presents NSSharingServicePicker anchored to a view and keeps the notch open while any picker or chosen
/// service's UI (which may be a popover on that view) is up. Overlapping shares are tracked separately, and
/// `.sharing` is released only when the last one finishes.
@MainActor
final class ShelfSharePicker: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let shared = ShelfSharePicker()

    /// One share in flight: its picker while that is up, then the chosen service until it reports back.
    private final class Session {
        let picker: NSSharingServicePicker
        var service: NSSharingService?
        var safetyRelease: DispatchWorkItem?

        init(picker: NSSharingServicePicker) { self.picker = picker }
    }

    private var sessions: [Session] = []

    func show(_ urls: [URL], from view: NSView?, viewModel: NotchViewModel) {
        guard !urls.isEmpty, let view, view.window != nil else {
            NSSound.beep()
            return
        }
        if !viewModel.isHeld(by: .shelfSharing) {
            // The notch was closed (or the shelf hidden) since earlier shares began, so they no longer hold it; forget them.
            sessions.forEach { $0.safetyRelease?.cancel() }
            sessions.removeAll()
        }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        sessions.append(Session(picker: picker))
        ShelfKeepOpen.shared.hold(.sharing, on: viewModel)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private func finish(_ session: Session) {
        session.safetyRelease?.cancel()
        session.safetyRelease = nil
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        if sessions.isEmpty { ShelfKeepOpen.shared.release(.sharing) }
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        MainActor.assumeIsolated { self }
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        MainActor.assumeIsolated {
            guard let session = sessions.first(where: { $0.picker === sharingServicePicker }) else { return }
            guard let service else { return finish(session) }
            session.service = service
            // The service reports back via didShare/didFail; don't let a silent service pin the notch forever.
            session.safetyRelease?.cancel()
            let work = DispatchWorkItem { [weak self, weak session] in
                MainActor.assumeIsolated {
                    if let self, let session { self.finish(session) }
                }
            }
            session.safetyRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finishService(sharingService)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        finishService(sharingService)
    }

    private func finishService(_ service: NSSharingService) {
        guard let session = sessions.first(where: { $0.service === service }) else { return }
        finish(session)
    }
}

/// Weak handle to an AppKit view inside SwiftUI, used to anchor share pickers.
@MainActor
final class ShelfViewAnchor {
    weak var view: NSView?
}

struct ShelfAnchorView: NSViewRepresentable {
    let anchor: ShelfViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

// MARK: Thumbnails

/// Quick Look thumbnails with a file-icon fallback, cached in memory.
enum ShelfThumbnails {
    @MainActor private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    @MainActor static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    @MainActor static func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    @MainActor static func evict(_ urls: [URL]) {
        urls.forEach { cache.removeObject(forKey: $0 as NSURL) }
    }

    static func icon(for url: URL) async -> NSImage {
        await Task.detached(priority: .utility) {
            NSWorkspace.shared.icon(forFile: url.path)
        }.value
    }

    /// A real content thumbnail, or nil when the file type has none (folders, archives…).
    static func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}
