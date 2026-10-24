import AppKit
import Combine
import SwiftUI

/// A player app Crest can read and control through its public scripting interface.
enum MediaSource: String, CaseIterable, Identifiable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var id: String { rawValue }
    var bundleID: String { rawValue }
    var displayName: String { self == .music ? "Music" : "Spotify" }

    /// Distributed notification the player posts on every play, pause, stop and track change.
    var playerInfoNotification: Notification.Name {
        switch self {
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    /// Thread-safe; never launches the app.
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// The player an NSWorkspace launch/terminate notification is about, if it is a supported one.
    static func from(workspaceNotification note: Notification) -> MediaSource? {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier.flatMap(MediaSource.init(rawValue:))
    }
}

enum MediaPlaybackState: String, Sendable {
    case playing, paused, stopped
}

/// Last known state of one player; the position is interpolated from `elapsed` at `timestamp`.
struct MediaSnapshot: Equatable, Sendable {
    var state: MediaPlaybackState = .stopped
    var title = ""
    var artist = ""
    var album = ""
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var timestamp = Date()

    var isPlaying: Bool { state == .playing }
    var hasTrack: Bool { state != .stopped && !title.isEmpty }
    /// Identity of the track (persistent IDs differ in format between notifications and AppleScript).
    var trackKey: String { [title, artist, album].joined(separator: "\u{1F}") }

    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let value = elapsed + max(0, date.timeIntervalSince(timestamp))
        return duration > 0 ? min(value, duration) : value
    }
}

/// Now-playing state and playback control for Apple Music and Spotify.
///
/// Uses only public mechanisms: the players' distributed notifications push changes, and AppleScript
/// (on a background queue, only while the player is already running) supplies position and artwork and
/// sends commands. A slow fallback poll (for position drift) runs only while a supported player is playing.
@MainActor
final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    /// Track length in seconds (0 when unknown, e.g. live streams).
    @Published private(set) var duration: TimeInterval = 0
    /// Position at `elapsedTimestamp`; use `currentElapsed(at:)` for the live value.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var elapsedTimestamp = Date()
    @Published private(set) var source: MediaSource?
    @Published private(set) var sourceIcon: NSImage?
    /// Artwork-derived tint, already brightened for the black notch.
    @Published private(set) var accentColor: Color = MediaAccent.neutralColor
    /// macOS refused Crest's Apple Events (Automation permission off) for `automationDeniedSource`.
    @Published private(set) var automationDenied = false
    @Published private(set) var automationDeniedSource: MediaSource?
    /// Supported players installed on this Mac, for the empty state's launch buttons.
    @Published private(set) var installedSources: [MediaSource] = []

    var hasTrack: Bool { !title.isEmpty }
    var sourceBundleID: String? { source?.bundleID }
    /// Name of the app shown in the player: any app when the system bridge is live, else Music/Spotify.
    var sourceName: String? { bridgeAppName ?? source?.displayName }
    @Published private(set) var bridgeAppName: String?

    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    private static let pollInterval: TimeInterval = 3
    private static let maxArtworkAttempts = 3

    private let runner = MediaScriptRunner()
    private let bridge = MediaNowPlayingBridge()
    /// True once the system-wide now-playing bridge delivers data; AppleScript then stays idle.
    private var useBridge = false
    private var bridgeState: MediaNowPlayingBridge.State?
    private var bridgeArtworkID: Int?
    private var started = false
    private var snapshots: [MediaSource: MediaSnapshot] = [:]
    private var runningSources: Set<MediaSource> = []
    /// Players whose last broadcast was "Stopped" (often posted while quitting): not polled, so no
    /// Apple Event can reach a dying process and relaunch it. Their next broadcast wakes them.
    private var quietSources: Set<MediaSource> = []
    private var deniedSources: Set<MediaSource> = []
    private var lastActive: MediaSource?
    private var refreshing: Set<MediaSource> = []
    private var pendingRefresh: [MediaSource: DispatchWorkItem] = [:]
    /// Poll results requested before the last command are stale and dropped.
    private var lastCommandAt: [MediaSource: Date] = [:]
    private var pollTimer: Timer?
    private var broadcastObserver: MediaBroadcastObserver?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var iconCache: [MediaSource: NSImage] = [:]

    private var artworkKey: String?
    private var artworkLoadingKey: String?
    private var artworkAttempts: [String: Int] = [:]
    private let artworkCache: NSCache<NSString, MediaArtworkEntry> = {
        let cache = NSCache<NSString, MediaArtworkEntry>()
        cache.countLimit = 24
        return cache
    }()

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshInstalledPlayers()

        broadcastObserver = MediaBroadcastObserver { [weak self] source, broadcast in
            self?.handleBroadcast(broadcast, from: source)
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let source = MediaSource.from(workspaceNotification: note) else { return }
            MainActor.assumeIsolated { self?.playerLaunched(source) }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let source = MediaSource.from(workspaceNotification: note) else { return }
            MainActor.assumeIsolated { self?.playerTerminated(source) }
        })

        runningSources = Set(MediaSource.allCases.filter(\.isRunning))

        bridge.onUpdate = { [weak self] state, artwork in self?.applyBridge(state, artwork: artwork) }
        bridge.onUnavailable = { [weak self] in self?.bridgeUnavailable() }
        bridge.start()
        // AppleScript is the fallback: one initial read only if the bridge hasn't answered by then
        // (which also avoids an Automation prompt when it isn't needed).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.useBridge else { return }
            self.runningSources.forEach(self.refresh)
        }
    }

    func refreshInstalledPlayers() {
        let installed = MediaSource.allCases.filter { $0.applicationURL != nil }
        if installed != installedSources { installedSources = installed }
    }

    /// Live playback position, interpolated locally between updates.
    func currentElapsed(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let value = elapsed + max(0, date.timeIntervalSince(elapsedTimestamp))
        return duration > 0 ? min(value, duration) : value
    }

    // MARK: Commands

    func playPause() {
        if useBridge, var state = bridgeState {
            let now = Date()
            state.elapsed = bridgePosition(state, at: now)
            state.timestamp = now
            state.isPlaying.toggle()
            bridgeState = state
            recompute()
            bridge.send(state.isPlaying ? "play" : "pause")
            return
        }
        guard let source else { return }
        let now = Date()
        let shouldPlay = !(snapshots[source]?.isPlaying ?? isPlaying)
        if var snapshot = snapshots[source] {
            snapshot.elapsed = snapshot.position(at: now)
            snapshot.timestamp = now
            snapshot.state = shouldPlay ? .playing : .paused
            snapshots[source] = snapshot
        }
        lastActive = source
        recompute()
        // An explicit target rather than a toggle, so taps coalesced behind a busy queue end where the UI shows.
        send(shouldPlay ? .play : .pause, to: source)
    }

    func next() {
        skip(.next)
    }

    func previous() {
        skip(.previous)
    }

    func seek(to time: TimeInterval) {
        if useBridge, var state = bridgeState, state.duration > 0 {
            let target = min(max(0, time), state.duration)
            state.elapsed = target
            state.timestamp = Date()
            bridgeState = state
            elapsed = target
            elapsedTimestamp = state.timestamp
            bridge.send("seek \(target)")
            return
        }
        guard let source, duration > 0 else { return }
        let target = min(max(0, time), duration)
        let now = Date()
        if var snapshot = snapshots[source] {
            snapshot.elapsed = target
            snapshot.timestamp = now
            snapshots[source] = snapshot
        }
        elapsed = target
        elapsedTimestamp = now
        send(.seek(target), to: source)
    }

    /// Brings a player to the front, launching it if needed (only ever on an explicit user action).
    func openPlayer(_ player: MediaSource) {
        guard let url = player.applicationURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// Brings the app that is playing to the front (the source badge in the player).
    func openCurrentPlayer() {
        if useBridge, let pid = bridgeState?.pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else if let source {
            openPlayer(source)
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(Self.automationSettingsURL)
    }

    private func skip(_ command: MediaCommand) {
        if useBridge {
            if case .next = command { bridge.send("next") } else { bridge.send("prev") }
            return
        }
        guard let source else { return }
        let now = Date()
        if var snapshot = snapshots[source] {
            snapshot.elapsed = 0
            snapshot.timestamp = now
            snapshots[source] = snapshot
        }
        elapsed = 0
        elapsedTimestamp = now
        lastActive = source
        send(command, to: source)
    }

    /// Commands are coalesced in the runner's mailbox; only one drain per player waits in the queue.
    private func send(_ command: MediaCommand, to source: MediaSource) {
        guard source.isRunning else { return }
        lastCommandAt[source] = Date()
        wake(source)
        guard runner.mailbox.post(command, to: source) else { return }
        onScriptQueue({ $0.drainCommands(for: source) }) { [weak self] result in
            guard let self, let result else { return }
            if case .failure(.denied) = result { self.setDenied(source, true) }
            self.scheduleRefresh(source, after: 0.35)
        }
    }

    // MARK: Player lifecycle

    private func playerLaunched(_ source: MediaSource) {
        runningSources.insert(source)
        quietSources.remove(source)
        refreshInstalledPlayers()
        updatePolling()
        // Give the app a moment to become scriptable; its own notification may arrive sooner.
        scheduleRefresh(source, after: 1.5)
    }

    private func playerTerminated(_ source: MediaSource) {
        runningSources.remove(source)
        quietSources.remove(source)
        snapshots[source] = nil
        pendingRefresh.removeValue(forKey: source)?.cancel()
        runner.mailbox.discard(for: source)
        if lastActive == source { lastActive = nil }
        updatePolling()
        recompute()
    }

    private func wake(_ source: MediaSource) {
        guard quietSources.remove(source) != nil else { return }
        updatePolling()
    }

    /// Players worth polling: running, not quiet or denied, and playing. A paused or stopped player is idle, and
    /// its next play/pause/track change arrives as a broadcast anyway.
    private var pollableSources: Set<MediaSource> {
        runningSources.subtracting(quietSources).subtracting(deniedSources).filter { snapshots[$0]?.isPlaying == true }
    }

    /// The fallback poll exists only while some player is pollable. Re-evaluated on every snapshot change.
    private func updatePolling() {
        if useBridge || pollableSources.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }

    private func poll() {
        pollableSources.forEach(refresh)
    }

    // MARK: Updates

    private func handleBroadcast(_ broadcast: MediaBroadcast, from source: MediaSource) {
        let now = Date()
        let previous = snapshots[source]
        let state = broadcast.state ?? previous?.state ?? .stopped

        if state == .stopped {
            quietSources.insert(source)
        } else {
            quietSources.remove(source)
            runningSources.insert(source)
        }
        updatePolling()

        if state == .stopped {
            snapshots[source] = MediaSnapshot(state: .stopped, timestamp: now)
            // Nothing left to read, and the player may be quitting: an Apple Event now could relaunch it.
            pendingRefresh.removeValue(forKey: source)?.cancel()
        } else {
            var snapshot = previous ?? MediaSnapshot()
            snapshot.state = state
            snapshot.title = broadcast.title ?? snapshot.title
            snapshot.artist = broadcast.artist ?? snapshot.artist
            snapshot.album = broadcast.album ?? snapshot.album
            let sameTrack = previous?.trackKey == snapshot.trackKey
            if let duration = broadcast.duration, duration > 0 {
                snapshot.duration = duration
            } else if !sameTrack {
                snapshot.duration = 0
            }
            // Music's broadcast has no position: carry it over within a track, assume 0 for a new one.
            snapshot.elapsed = broadcast.position ?? (sameTrack ? previous?.position(at: now) ?? 0 : 0)
            snapshot.timestamp = now
            snapshots[source] = snapshot
        }
        if state == .playing { lastActive = source }
        recompute()
        // Fetch the exact position and artwork the broadcast lacks.
        if state != .stopped { scheduleRefresh(source, after: 0.25) }
    }

    private func scheduleRefresh(_ source: MediaSource, after delay: TimeInterval) {
        pendingRefresh[source]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingRefresh[source] = nil
                self?.refresh(source)
            }
        }
        pendingRefresh[source] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refresh(_ source: MediaSource) {
        guard !useBridge else { return }
        guard source.isRunning else {
            if runningSources.contains(source) { playerTerminated(source) }
            return
        }
        // Coalesce: while a read is in flight (or blocked on the permission prompt) don't queue more.
        guard !quietSources.contains(source), !refreshing.contains(source) else { return }
        refreshing.insert(source)
        let requestedAt = Date()
        onScriptQueue({ $0.readState(of: source) }) { [weak self] result in
            self?.finishRefresh(source, result: result, requestedAt: requestedAt)
        }
    }

    private func finishRefresh(_ source: MediaSource, result: Result<MediaStateReading, MediaScriptError>, requestedAt: Date) {
        refreshing.remove(source)
        switch result {
        case .success(let reading):
            setDenied(source, false)
            // A "Stopped" broadcast arrived meanwhile; this reading predates it.
            if quietSources.contains(source) { return }
            if let commandAt = lastCommandAt[source], requestedAt < commandAt {
                scheduleRefresh(source, after: 0.3)
                return
            }
            apply(reading, from: source)
        case .failure(.denied):
            setDenied(source, true)
        case .failure(.notRunning):
            snapshots[source] = nil
            recompute()
        case .failure(.failed):
            break
        }
    }

    private func apply(_ reading: MediaStateReading, from source: MediaSource) {
        let previous = snapshots[source]
        var snapshot = MediaSnapshot(
            state: reading.state,
            title: reading.title,
            artist: reading.artist,
            album: reading.album,
            duration: reading.duration,
            elapsed: reading.position ?? 0,
            timestamp: reading.readAt
        )
        if reading.state == .stopped {
            snapshot = MediaSnapshot(state: .stopped, timestamp: reading.readAt)
        } else {
            // The track's details couldn't be read (some streams): keep what the broadcast supplied.
            if reading.title.isEmpty, let previous, previous.hasTrack {
                snapshot.title = previous.title
                snapshot.artist = previous.artist
                snapshot.album = previous.album
                if snapshot.duration <= 0 { snapshot.duration = previous.duration }
            }
            if reading.position == nil, let previous, previous.trackKey == snapshot.trackKey {
                snapshot.elapsed = previous.position(at: reading.readAt)
            }
        }
        if snapshot.isPlaying && previous?.isPlaying != true { lastActive = source }
        snapshots[source] = snapshot
        recompute()
    }

    private func setDenied(_ source: MediaSource, _ denied: Bool) {
        guard deniedSources.contains(source) != denied else { return }
        if denied {
            deniedSources.insert(source)
        } else {
            deniedSources.remove(source)
            artworkAttempts = [:]
        }
        recompute()
    }

    /// Picks the player to show (the one playing, preferring the most recently active) and publishes it.
    private func recompute() {
        // Every snapshot or permission change ends up here, so the poll starts and stops in step with playback.
        updatePolling()
        if useBridge {
            publishBridge()
            return
        }
        assign(\.bridgeAppName, nil)
        let withTrack = MediaSource.allCases.filter { snapshots[$0]?.hasTrack == true }
        let chosen: MediaSource?
        if let last = lastActive, snapshots[last]?.isPlaying == true {
            chosen = last
        } else if let playing = withTrack.first(where: { snapshots[$0]?.isPlaying == true }) {
            chosen = playing
        } else if let last = lastActive, withTrack.contains(last) {
            chosen = last
        } else {
            chosen = withTrack.first
        }

        let denied: MediaSource?
        if let chosen {
            denied = deniedSources.contains(chosen) ? chosen : nil
        } else {
            denied = MediaSource.allCases.first { deniedSources.contains($0) && runningSources.contains($0) }
        }
        assign(\.automationDeniedSource, denied)
        assign(\.automationDenied, denied != nil)

        guard let chosen, let snapshot = snapshots[chosen] else {
            clearTrack()
            return
        }

        let now = Date()
        let trackChanged = source != chosen || title != snapshot.title || artist != snapshot.artist || album != snapshot.album
        // Only republish the position when it really moved, so the notch doesn't re-render on every poll.
        if trackChanged || isPlaying != snapshot.isPlaying || duration != snapshot.duration
            || abs(currentElapsed(at: now) - snapshot.position(at: now)) > 1 {
            elapsed = snapshot.elapsed
            elapsedTimestamp = snapshot.timestamp
        }
        assign(\.source, chosen)
        assign(\.sourceIcon, icon(for: chosen))
        assign(\.title, snapshot.title)
        assign(\.artist, snapshot.artist)
        assign(\.album, snapshot.album)
        assign(\.duration, snapshot.duration)
        assign(\.isPlaying, snapshot.isPlaying)
        updateArtwork(source: chosen, snapshot: snapshot)
    }

    // MARK: System now-playing bridge

    private func applyBridge(_ state: MediaNowPlayingBridge.State, artwork: Data?) {
        if !useBridge {
            useBridge = true
            pendingRefresh.values.forEach { $0.cancel() }
            pendingRefresh.removeAll()
        }
        bridgeState = state
        if let artwork, let id = state.artworkID {
            DispatchQueue.global(qos: .userInitiated).async {
                let decoded = MediaArtworkProcessor.decode(artwork)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { MediaController.shared.finishBridgeArtwork(id: id, decoded: decoded) }
                }
            }
        }
        recompute()
    }

    private func finishBridgeArtwork(id: Int, decoded: MediaDecodedArtwork?) {
        guard bridgeState?.artworkID == id, let decoded else { return }
        bridgeArtworkID = id
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        withAnimation(.easeInOut(duration: 0.3)) { setArtwork(image, accent: decoded.accent.color) }
    }

    private func bridgeUnavailable() {
        guard useBridge || bridgeState == nil else { return }
        useBridge = false
        bridgeState = nil
        runningSources.forEach(refresh)
        recompute()
    }

    private func bridgePosition(_ state: MediaNowPlayingBridge.State, at date: Date) -> TimeInterval {
        guard state.isPlaying else { return state.elapsed }
        let value = state.elapsed + max(0, date.timeIntervalSince(state.timestamp))
        return state.duration > 0 ? min(value, state.duration) : value
    }

    private func publishBridge() {
        assign(\.automationDeniedSource, nil)
        assign(\.automationDenied, false)
        guard let state = bridgeState, state.hasTrack else {
            clearTrack()
            bridgeArtworkID = nil
            return
        }
        let app = state.pid > 0 ? NSRunningApplication(processIdentifier: state.pid) : nil
        let now = Date()
        let trackChanged = title != state.title || artist != state.artist || album != state.album
        let position = bridgePosition(state, at: now)
        if trackChanged || isPlaying != state.isPlaying || duration != state.duration
            || abs(currentElapsed(at: now) - position) > 1 {
            elapsed = position
            elapsedTimestamp = now
        }
        assign(\.source, app?.bundleIdentifier.flatMap(MediaSource.init(rawValue:)))
        assign(\.bridgeAppName, app?.localizedName)
        if sourceIcon !== app?.icon { sourceIcon = app?.icon }
        assign(\.title, state.title)
        assign(\.artist, state.artist)
        assign(\.album, state.album)
        assign(\.duration, state.duration)
        assign(\.isPlaying, state.isPlaying)
        if state.artworkID == nil || (trackChanged && state.artworkID != bridgeArtworkID) {
            bridgeArtworkID = nil
            setArtwork(nil, accent: MediaAccent.neutralColor)
        }
    }

    private func clearTrack() {
        assign(\.source, nil)
        assign(\.sourceIcon, nil)
        assign(\.title, "")
        assign(\.artist, "")
        assign(\.album, "")
        assign(\.duration, 0)
        assign(\.isPlaying, false)
        if elapsed != 0 { elapsed = 0 }
        assign(\.artwork, nil)
        assign(\.accentColor, MediaAccent.neutralColor)
        artworkKey = nil
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MediaController, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func icon(for source: MediaSource) -> NSImage? {
        if let cached = iconCache[source] { return cached }
        guard let url = source.applicationURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[source] = icon
        return icon
    }

    // MARK: Artwork

    private func updateArtwork(source: MediaSource, snapshot: MediaSnapshot) {
        let key = source.rawValue + "\u{1E}" + snapshot.trackKey
        if key != artworkKey {
            artworkKey = key
            artworkAttempts = [:]
            if let cached = artworkCache.object(forKey: key as NSString) {
                setArtwork(cached.image, accent: cached.accent)
                return
            }
            setArtwork(nil, accent: MediaAccent.neutralColor)
        }
        // Retry a few times on later updates: Spotify's artwork URL can lag behind a track change.
        guard artwork == nil, artworkLoadingKey != key, !deniedSources.contains(source),
              artworkAttempts[key, default: 0] < Self.maxArtworkAttempts else { return }
        loadArtwork(key: key, source: source, title: snapshot.title)
    }

    private func loadArtwork(key: String, source: MediaSource, title: String) {
        artworkLoadingKey = key
        artworkAttempts[key, default: 0] += 1
        let runner = self.runner
        runner.queue.async { [weak self] in
            let reading = runner.readArtwork(of: source)
            switch reading {
            case .success(.data(let artTitle, let data)) where artTitle == title:
                let decoded = MediaArtworkProcessor.decode(data)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishArtwork(key: key, decoded: decoded) }
                }
            case .success(.url(let artTitle, let url)) where artTitle == title:
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
                MediaArtworkProcessor.session.dataTask(with: request) { data, _, _ in
                    let decoded = data.flatMap { MediaArtworkProcessor.decode($0) }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.finishArtwork(key: key, decoded: decoded) }
                    }
                }.resume()
            case .failure(.denied):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.finishArtwork(key: key, decoded: nil)
                        self?.setDenied(source, true)
                    }
                }
            default:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishArtwork(key: key, decoded: nil) }
                }
            }
        }
    }

    private func finishArtwork(key: String, decoded: MediaDecodedArtwork?) {
        if artworkLoadingKey == key { artworkLoadingKey = nil }
        guard let decoded else { return }
        let entry = MediaArtworkEntry(
            image: NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height)),
            accent: decoded.accent.color
        )
        artworkCache.setObject(entry, forKey: key as NSString)
        guard key == artworkKey else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            setArtwork(entry.image, accent: entry.accent)
        }
    }

    private func setArtwork(_ image: NSImage?, accent: Color) {
        if artwork !== image { artwork = image }
        assign(\.accentColor, accent)
    }

    // MARK: Helpers

    /// Runs `work` on the AppleScript queue and delivers its result on the main actor, in order.
    private func onScriptQueue<Value: Sendable>(
        _ work: @escaping @Sendable (MediaScriptRunner) -> Value,
        then completion: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        let runner = self.runner
        runner.queue.async {
            let value = work(runner)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(value) }
            }
        }
    }
}

/// Player broadcast payload (Music "playerInfo", Spotify "PlaybackStateChanged").
struct MediaBroadcast: Sendable {
    var state: MediaPlaybackState?
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var position: TimeInterval?

    init(userInfo: [AnyHashable: Any]?, source: MediaSource) {
        let info = userInfo ?? [:]
        switch (info["Player State"] as? String)?.lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        case "stopped": state = .stopped
        default: state = nil
        }
        title = info["Name"] as? String
        artist = info["Artist"] as? String
        album = info["Album"] as? String
        // Both report the length in milliseconds; only Spotify includes the position (seconds).
        let milliseconds = info[source == .music ? "Total Time" : "Duration"] as? NSNumber
        duration = milliseconds.map { $0.doubleValue / 1000 }
        position = source == .spotify ? (info["Playback Position"] as? NSNumber)?.doubleValue : nil
    }
}

/// Receives player broadcasts immediately. AppKit otherwise holds distributed notifications back
/// while the app is inactive, which an accessory app like Crest almost always is.
private final class MediaBroadcastObserver: NSObject {
    private let handler: @MainActor (MediaSource, MediaBroadcast) -> Void

    init(handler: @escaping @MainActor (MediaSource, MediaBroadcast) -> Void) {
        self.handler = handler
        super.init()
        let center = DistributedNotificationCenter.default()
        for source in MediaSource.allCases {
            center.addObserver(
                self,
                selector: #selector(receive(_:)),
                name: source.playerInfoNotification,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func receive(_ note: Notification) {
        guard let source = MediaSource.allCases.first(where: { $0.playerInfoNotification == note.name }) else { return }
        let broadcast = MediaBroadcast(userInfo: note.userInfo, source: source)
        let handler = self.handler
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(source, broadcast) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(source, broadcast) }
            }
        }
    }
}
