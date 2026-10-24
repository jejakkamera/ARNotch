import AppKit
import AVFoundation

/// Lifecycle of the mirror camera as shown by MirrorWidgetView.
enum MirrorCameraState: Equatable {
    /// Camera off, ready to start.
    case idle
    /// Waiting for the user to answer the system camera prompt.
    case requestingAccess
    case starting
    case running
    /// Camera access denied or restricted in Privacy & Security.
    case denied
    /// No video capture device is connected.
    case unavailable
    /// The session could not be configured or stopped with a runtime error.
    case failed

    /// True while the camera is on or about to be.
    var isActive: Bool { self == .requestingAccess || self == .starting || self == .running }
}

/// Drives the mirror's permission flow and capture session. Shared so the session is configured once;
/// the widget calls `stop()` whenever it disappears so the camera never outlives the open notch.
@MainActor
final class MirrorCameraController: ObservableObject {
    static let shared = MirrorCameraController()

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    @Published private(set) var state: MirrorCameraState = .idle
    /// True while the system camera prompt is up and for a short grace period after it is answered.
    /// The pointer leaves the notch to click the prompt, so the widget holds the notch open meanwhile.
    @Published private(set) var holdsNotchOpen = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    /// Bumped on every photo so the widget can flash.
    @Published private(set) var shutterCount = 0
    /// Short confirmation ("Photo saved", "Video saved", errors); cleared after a few seconds.
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?

    /// Session for the preview layer. It is configured and started on a background queue.
    var session: AVCaptureSession { capture.session }

    private let capture = MirrorCaptureSession()
    /// Whether the user currently wants the camera on; async results arriving after a stop are dropped.
    private var wantsRunning = false
    /// Bumped on every start/stop so stale completions can be recognised.
    private var generation = 0
    private var activeDeviceID: String?
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: MirrorScreenLockObserver?
    private var holdRelease: Task<Void, Never>?

    /// Time the pointer gets to come back from the camera prompt before the notch may auto-close.
    private static let promptGracePeriod: Duration = .seconds(3)

    private init() {
        observeInterruptions()
    }

    // MARK: Public API

    func toggle() {
        state.isActive ? stop() : start()
    }

    /// Re-reads permission and camera presence; call when the widget appears.
    func refresh() {
        guard !state.isActive else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            state = .denied
            return
        default:
            break
        }
        let gen = generation
        capture.checkForCamera { [weak self] present in
            Task { @MainActor in
                guard let self, gen == self.generation, !self.state.isActive else { return }
                self.state = present ? .idle : .unavailable
            }
        }
    }

    func start() {
        guard !state.isActive else { return }
        wantsRunning = true
        generation &+= 1
        let gen = generation
        setHoldsNotchOpen(false)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(gen)
        case .notDetermined:
            state = .requestingAccess
            setHoldsNotchOpen(true)
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                // The notch may have closed while the prompt was up; only continue if still wanted.
                guard gen == self.generation, self.wantsRunning else { return }
                self.releaseNotchAfterGracePeriod()
                if granted {
                    self.startSession(gen)
                } else {
                    self.wantsRunning = false
                    self.state = .denied
                }
            }
        case .denied, .restricted:
            wantsRunning = false
            state = .denied
        @unknown default:
            wantsRunning = false
            state = .denied
        }
    }

    /// Turns the camera off. Safe to call at any time, including when it is already off.
    func stop() {
        generation &+= 1
        wantsRunning = false
        activeDeviceID = nil
        setHoldsNotchOpen(false)
        if state.isActive { state = .idle }
        if isRecording { capture.stopRecording() }
        capture.stop()
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(Self.privacySettingsURL)
    }

    // MARK: Photo & video

    /// Saves a JPEG to ~/Pictures/Crest and puts it on the Shelf.
    func takePhoto() {
        guard state == .running else { return }
        shutterCount &+= 1
        NSSound(named: "Tink")?.play()
        let url = Self.newFile(in: .picturesDirectory, prefix: "ARNotch Photo", ext: "jpg")
        capture.capturePhoto(to: url) { [weak self] success in
            Task { @MainActor in self?.saved(url, success: success, kind: "Photo") }
        }
    }

    /// Starts or stops a movie in ~/Movies/Crest (with the microphone when allowed).
    func toggleRecording() {
        if isRecording {
            capture.stopRecording()
            return
        }
        guard state == .running else { return }
        Task {
            let withAudio = await Self.microphoneAllowed()
            guard self.state == .running, !self.isRecording else { return }
            let url = Self.newFile(in: .moviesDirectory, prefix: "ARNotch Video", ext: "mov")
            self.isRecording = true
            self.recordingStartedAt = Date()
            self.capture.startRecording(to: url, withAudio: withAudio) { [weak self] success in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRecording = false
                    self.recordingStartedAt = nil
                    self.saved(url, success: success, kind: "Video")
                }
            }
        }
    }

    private func saved(_ url: URL, success: Bool, kind: String) {
        if success {
            ShelfStore.shared.add(urls: [url])
            show("\(kind) saved · on Shelf")
        } else {
            show("Couldn't save \(kind.lowercased())")
        }
    }

    private func show(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static func newFile(in directory: FileManager.SearchPathDirectory, prefix: String, ext: String) -> URL {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent("ARNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return base.appendingPathComponent("\(prefix) \(formatter.string(from: Date())).\(ext)")
    }

    // MARK: Private

    private func setHoldsNotchOpen(_ hold: Bool) {
        holdRelease?.cancel()
        holdRelease = nil
        if holdsNotchOpen != hold { holdsNotchOpen = hold }
    }

    private func releaseNotchAfterGracePeriod() {
        holdRelease?.cancel()
        holdRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.promptGracePeriod)
            guard !Task.isCancelled, let self else { return }
            self.holdRelease = nil
            self.holdsNotchOpen = false
        }
    }

    private func startSession(_ gen: Int) {
        state = .starting
        // Enqueued synchronously so a later stop() is always ordered after this start on the session queue.
        capture.start { [weak self] result in
            Task { @MainActor in self?.finishStart(result, gen: gen) }
        }
    }

    private func finishStart(_ result: MirrorCaptureSession.StartResult, gen: Int) {
        guard gen == generation, wantsRunning else { return }
        switch result {
        case .started(let deviceID):
            activeDeviceID = deviceID
            state = .running
        case .noCamera:
            wantsRunning = false
            state = .unavailable
        case .failed:
            wantsRunning = false
            state = .failed
            capture.stop()
        }
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isActive else { return }
                self.stop()
                self.state = .failed
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: capture.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        // A session restarts by itself after an interruption ends; never let the camera come on unwanted.
        observers.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: capture.session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.wantsRunning else { return }
                self.capture.stop()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            let deviceID = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state.isActive, deviceID == nil || deviceID == self.activeDeviceID { self.stop() }
                self.refresh()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .unavailable else { return }
                self.refresh()
            }
        })

        // Never leave the camera on across sleep, display sleep, a user switch or the lock screen.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        lockObserver = MirrorScreenLockObserver { [weak self] in self?.stop() }
    }
}

/// Reports the screen locking. Delivered immediately: AppKit otherwise holds distributed notifications back
/// while an accessory app like Crest is inactive.
private final class MirrorScreenLockObserver: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenLocked),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func screenLocked() {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler() }
        }
    }
}

/// Owns the AVCaptureSession. All configuration and start/stop calls run on a private serial queue,
/// so the main thread never blocks and requests are applied in the order they were made.
final class MirrorCaptureSession: @unchecked Sendable {
    enum StartResult: Sendable {
        case started(deviceID: String)
        case noCamera
        case failed
    }

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "app.crest.mirror.capture", qos: .userInitiated)
    /// Only touched on `queue`.
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var photoDelegates: [PhotoSaver] = []
    private var movieDelegate: MovieSaver?

    /// Preferred presets: 720p keeps photos and videos sharp at modest cost; fall back for older cameras.
    private static let presets: [AVCaptureSession.Preset] = [.hd1280x720, .high, .medium, .vga640x480]

    func capturePhoto(to url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard self.session.isRunning, self.session.outputs.contains(self.photoOutput) else { return completion(false) }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            var saver: PhotoSaver!
            saver = PhotoSaver(url: url) { [weak self] success in
                self?.queue.async { self?.photoDelegates.removeAll { $0 === saver } }
                completion(success)
            }
            self.photoDelegates.append(saver)
            self.photoOutput.capturePhoto(with: settings, delegate: saver)
        }
    }

    func startRecording(to url: URL, withAudio: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            guard self.session.isRunning, self.session.outputs.contains(self.movieOutput), !self.movieOutput.isRecording else {
                return completion(false)
            }
            if withAudio { self.addMicrophone() }
            self.mirrorConnections()
            let saver = MovieSaver { [weak self] success in
                self?.queue.async {
                    self?.movieDelegate = nil
                    self?.removeMicrophone()
                }
                completion(success)
            }
            self.movieDelegate = saver
            self.movieOutput.startRecording(to: url, recordingDelegate: saver)
        }
    }

    func stopRecording() {
        queue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } }
    }

    private func addMicrophone() {
        guard audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        session.commitConfiguration()
    }

    /// The microphone (and its privacy indicator) is only on while recording.
    private func removeMicrophone() {
        guard let audioInput else { return }
        session.beginConfiguration()
        session.removeInput(audioInput)
        session.commitConfiguration()
        self.audioInput = nil
    }

    func start(completion: @escaping @Sendable (StartResult) -> Void) {
        queue.async { completion(self.startOnQueue()) }
    }

    /// Always calls `stopRunning`: an interrupted session reports `isRunning == false` but keeps its start
    /// request and restarts on its own when the interruption ends, unless it is explicitly stopped.
    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func checkForCamera(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { completion(AVCaptureDevice.default(for: .video) != nil) }
    }

    private func startOnQueue() -> StartResult {
        guard let device = AVCaptureDevice.default(for: .video) else {
            session.stopRunning()
            return .noCamera
        }
        if input?.device.uniqueID != device.uniqueID || input?.device.isConnected == false {
            guard configure(with: device) else { return .failed }
        }
        mirrorConnections()
        if !session.isRunning { session.startRunning() }
        guard session.isRunning else {
            // Drop the pending start request so a busy camera cannot switch on later by itself.
            session.stopRunning()
            return .failed
        }
        return .started(deviceID: device.uniqueID)
    }

    private func configure(with device: AVCaptureDevice) -> Bool {
        guard let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input {
            session.removeInput(input)
            self.input = nil
        }
        // Ask the device, not the (now empty) session, which accepts any preset; a device that cannot
        // do the session's preset cannot be added. The small square tile needs little resolution, and
        // a 4:3 preset crops less than 16:9.
        if let preset = Self.presets.first(where: device.supportsSessionPreset), session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
        guard session.canAddInput(newInput) else { return false }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        return true
    }

    /// Mirrors every connection (including preview layers attached before the input was added).
    private func mirrorConnections() {
        for connection in session.connections where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

/// Writes one captured photo to disk.
private final class PhotoSaver: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let url: URL
    private let completion: @Sendable (Bool) -> Void

    init(url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        self.url = url
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return completion(false) }
        completion((try? data.write(to: url, options: .atomic)) != nil)
    }
}

/// Reports when a movie file has been finalized.
private final class MovieSaver: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let completion: @Sendable (Bool) -> Void

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // Stopping the session also ends a recording; the file is still complete in that case.
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        completion(finished && FileManager.default.fileExists(atPath: outputFileURL.path))
    }
}
