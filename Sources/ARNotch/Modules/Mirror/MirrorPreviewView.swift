import AVFoundation
import SwiftUI

/// Live camera feed for the mirror: horizontally mirrored, aspect-fill, clipped to rounded corners.
struct MirrorPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    /// Flips when the session starts. The layer's connection only exists once the session has an input,
    /// and SwiftUI calls `updateNSView` only when an input changes, so this re-applies mirroring then.
    var isRunning: Bool
    var cornerRadius: CGFloat = 16

    func makeNSView(context: Context) -> MirrorPreviewNSView {
        let view = MirrorPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.cornerRadius = cornerRadius
        view.mirrorIfNeeded()
        return view
    }

    func updateNSView(_ view: MirrorPreviewNSView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        if view.previewLayer.cornerRadius != cornerRadius { view.previewLayer.cornerRadius = cornerRadius }
        view.mirrorIfNeeded()
    }
}

/// Layer-backed view whose backing layer is the capture preview layer.
final class MirrorPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    init() {
        super.init(frame: .zero)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.cornerCurve = .continuous
        previewLayer.masksToBounds = true
    }

    override func makeBackingLayer() -> CALayer { previewLayer }

    /// Clicks fall through to the SwiftUI tile that hosts this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mirrorIfNeeded() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
        if !connection.isVideoMirrored { connection.isVideoMirrored = true }
    }
}
