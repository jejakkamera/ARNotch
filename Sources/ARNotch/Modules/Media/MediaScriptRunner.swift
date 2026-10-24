import AppKit
import Foundation

enum MediaScriptError: Error, Sendable {
    case notRunning
    /// macOS refused the Apple Event: Automation access for this player is off (error -1743).
    case denied
    case failed(Int)

    /// The player can't be reached right now (gone, refused or not answering), so queued commands are moot.
    var isUnreachable: Bool {
        switch self {
        case .notRunning, .denied, .failed(MediaScripts.timeoutError): true
        case .failed: false
        }
    }
}

enum MediaCommand: Sendable {
    /// Toggle; the controller sends explicit `play` / `pause` so coalesced taps keep their meaning.
    case playPause
    case play, pause, next, previous
    case seek(TimeInterval)
}

/// Player state as read through AppleScript.
struct MediaStateReading: Sendable {
    var state: MediaPlaybackState
    var title = ""
    var artist = ""
    var album = ""
    var duration: TimeInterval = 0
    var position: TimeInterval?
    var readAt: Date
}

enum MediaArtworkReading: Sendable {
    /// Image bytes plus the title of the track they belong to.
    case data(title: String, Data)
    case url(title: String, URL)
    case none
}

/// Runs player AppleScripts on one private serial queue (NSAppleScript must not be used concurrently).
/// Every script re-checks that the player is running, so nothing here can launch a player, and every
/// Apple Event has a short timeout, so a busy player can't hold the queue for long.
/// All methods other than `queue` and `mailbox` must be called on `queue`.
final class MediaScriptRunner: @unchecked Sendable {
    let queue = DispatchQueue(label: "id.crest.media.scripts", qos: .userInitiated)
    /// Commands waiting for `queue`; post here, then drain on `queue` with `drainCommands(for:)`.
    let mailbox = MediaCommandMailbox()

    /// Compiled scripts by key; only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    func readState(of source: MediaSource) -> Result<MediaStateReading, MediaScriptError> {
        execute(MediaScripts.state(for: source), cacheKey: "state.\(source.rawValue)", source: source)
            .flatMap { descriptor in
                let readAt = Date()
                let items = MediaDescriptorList(descriptor)
                switch items.string(1) {
                case "playing", "paused":
                    return .success(MediaStateReading(
                        state: items.string(1) == "playing" ? .playing : .paused,
                        title: items.string(2),
                        artist: items.string(3),
                        album: items.string(4),
                        duration: Self.seconds(fromDuration: max(0, items.number(5) ?? 0), source: source),
                        position: items.number(6).flatMap { $0 >= 0 ? $0 : nil },
                        readAt: readAt
                    ))
                case "stopped":
                    return .success(MediaStateReading(state: .stopped, readAt: readAt))
                default:
                    return .failure(.notRunning)
                }
            }
    }

    func readArtwork(of source: MediaSource) -> Result<MediaArtworkReading, MediaScriptError> {
        execute(MediaScripts.artwork(for: source), cacheKey: "artwork.\(source.rawValue)", source: source)
            .map { descriptor in
                let items = MediaDescriptorList(descriptor)
                guard items.count >= 2, let payload = items.descriptor(2) else { return .none }
                let title = items.string(1)
                switch source {
                case .music:
                    let data = payload.data
                    return data.isEmpty ? .none : .data(title: title, data)
                case .spotify:
                    guard let text = payload.stringValue, var components = URLComponents(string: text),
                          components.scheme == "https" || components.scheme == "http" else { return .none }
                    components.scheme = "https" // App Transport Security blocks plain http.
                    return components.url.map { .url(title: title, $0) } ?? .none
                }
            }
    }

    func perform(_ command: MediaCommand, on source: MediaSource) -> Result<Void, MediaScriptError> {
        let body: String
        var cacheKey: String?
        switch command {
        case .playPause:
            body = "playpause"
            cacheKey = "playpause.\(source.rawValue)"
        case .play:
            body = "play"
            cacheKey = "play.\(source.rawValue)"
        case .pause:
            body = "pause"
            cacheKey = "pause.\(source.rawValue)"
        case .next:
            body = "next track"
            cacheKey = "next.\(source.rawValue)"
        case .previous:
            body = "previous track"
            cacheKey = "previous.\(source.rawValue)"
        case .seek(let seconds):
            // String(format:) is locale-independent, so the decimal separator is always ".".
            body = "set player position to \(String(format: "%.2f", max(0, seconds)))"
        }
        let script = MediaScripts.guarded(source, timeout: MediaScripts.commandTimeout, body, fallback: "")
        return execute(script, cacheKey: cacheKey, source: source).map { _ in }
    }

    /// Runs the commands posted for `source` in order, including ones posted while it runs.
    /// Returns the last result, or nil when another drain already took them.
    func drainCommands(for source: MediaSource) -> Result<Void, MediaScriptError>? {
        var last: Result<Void, MediaScriptError>?
        while let command = mailbox.take(for: source) {
            let result = perform(command, on: source)
            last = result
            if case .failure(let error) = result, error.isUnreachable {
                mailbox.discard(for: source)
                break
            }
        }
        return last
    }

    // MARK: Execution

    private func execute(_ text: String, cacheKey: String?, source: MediaSource) -> Result<NSAppleEventDescriptor, MediaScriptError> {
        dispatchPrecondition(condition: .onQueue(queue))
        // Checked again here because work may wait in the queue; the script itself checks a third time.
        guard source.isRunning else { return .failure(.notRunning) }

        let script: NSAppleScript
        if let cacheKey, let cached = compiled[cacheKey] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: text) else { return .failure(.failed(-1)) }
            var compileError: NSDictionary?
            guard fresh.compileAndReturnError(&compileError) else { return .failure(Self.error(from: compileError, source: source)) }
            if let cacheKey { compiled[cacheKey] = fresh }
            script = fresh
        }

        var runError: NSDictionary?
        // Declared optional on purpose: the method returns nil on failure despite its signature.
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&runError)
        if runError != nil { return .failure(Self.error(from: runError, source: source)) }
        guard let result else { return .failure(.failed(-1)) }
        return .success(result)
    }

    /// Music reports track duration in seconds. Spotify's dictionary says seconds too, but it actually
    /// returns milliseconds; values under 1000 can only be seconds, in case that ever gets fixed.
    private static func seconds(fromDuration value: Double, source: MediaSource) -> TimeInterval {
        source == .spotify && value >= 1000 ? value / 1000 : value
    }

    private static func error(from info: NSDictionary?, source: MediaSource) -> MediaScriptError {
        let code = (info?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        switch code {
        case -1743, -1744: return .denied
        // Process gone / connection invalid. Also seen while a player is still launching, so only
        // trust it when the app really is gone; otherwise it is a transient failure.
        case -600, -609: return source.isRunning ? .failed(code) : .notRunning
        default: return .failed(code)
        }
    }
}

/// Commands waiting for the script queue, coalesced per player so taps made while the queue is blocked
/// don't fire later in a burst: a newer play/pause or seek replaces a pending one, and skips are capped.
/// Thread-safe.
final class MediaCommandMailbox: @unchecked Sendable {
    private static let maxPendingSkips = 3

    private let lock = NSLock()
    private var pending: [MediaSource: [MediaCommand]] = [:]

    /// Adds `command`. Returns true when nothing was pending, i.e. the caller must schedule a drain.
    func post(_ command: MediaCommand, to source: MediaSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var commands = pending[source] ?? []
        let wasEmpty = commands.isEmpty
        switch command {
        case .playPause:
            // Two pending toggles cancel out.
            if let index = commands.firstIndex(where: \.isPlayback), case .playPause = commands[index] {
                commands.remove(at: index)
            } else {
                commands.removeAll(where: \.isPlayback)
                commands.append(command)
            }
        case .play, .pause:
            commands.removeAll(where: \.isPlayback)
            commands.append(command)
        case .seek:
            commands.removeAll(where: \.isSeek)
            commands.append(command)
        case .next, .previous:
            // A pending seek belonged to the track being skipped.
            commands.removeAll(where: \.isSeek)
            if commands.filter(\.isSkip).count < Self.maxPendingSkips { commands.append(command) }
        }
        pending[source] = commands.isEmpty ? nil : commands
        return wasEmpty && !commands.isEmpty
    }

    func take(for source: MediaSource) -> MediaCommand? {
        lock.lock()
        defer { lock.unlock() }
        guard var commands = pending[source], !commands.isEmpty else { return nil }
        let first = commands.removeFirst()
        pending[source] = commands.isEmpty ? nil : commands
        return first
    }

    func discard(for source: MediaSource) {
        lock.lock()
        defer { lock.unlock() }
        pending[source] = nil
    }
}

private extension MediaCommand {
    var isPlayback: Bool {
        switch self {
        case .playPause, .play, .pause: true
        default: false
        }
    }

    var isSeek: Bool {
        if case .seek = self { return true }
        return false
    }

    var isSkip: Bool {
        switch self {
        case .next, .previous: true
        default: false
        }
    }
}

/// 1-based, bounds-checked access to an AppleScript list result.
private struct MediaDescriptorList {
    let descriptor: NSAppleEventDescriptor
    let count: Int

    init(_ descriptor: NSAppleEventDescriptor) {
        self.descriptor = descriptor
        count = descriptor.numberOfItems
    }

    func descriptor(_ index: Int) -> NSAppleEventDescriptor? {
        guard index >= 1, index <= count else { return nil }
        return descriptor.atIndex(index)
    }

    func string(_ index: Int) -> String {
        descriptor(index)?.stringValue ?? ""
    }

    func number(_ index: Int) -> Double? {
        guard let item = descriptor(index), item.descriptorType != MediaDescriptorList.nullType else { return nil }
        return item.doubleValue
    }

    private static let nullType: DescType = 0x6E75_6C6C // 'null' (missing value)
}

/// AppleScript sources. Each one is wrapped in an `is running` check so it can never launch the player,
/// and in a `with timeout` so a busy player fails fast (-1712) instead of blocking for two minutes.
private enum MediaScripts {
    static let timeoutError = -1712
    static let stateTimeout = 3
    static let commandTimeout = 3
    static let artworkTimeout = 5

    /// Error handler for `try` blocks that only tolerate missing data: Automation denial (-1743/-1744),
    /// timeouts and a vanished player are rethrown so Swift sees them instead of an empty reading.
    private static let rethrowUnreachable = """
        on error errText number errNum
        if errNum is in {-1743, -1744, \(timeoutError), -609, -600} then error errText number errNum
        """

    static func guarded(_ source: MediaSource, timeout: Int, _ body: String, fallback: String = "return {}") -> String {
        """
        if application id "\(source.bundleID)" is running then
        with timeout of \(timeout) seconds
        tell application id "\(source.bundleID)"
        \(body)
        end tell
        end timeout
        end if
        \(fallback)
        """
    }

    /// Returns {state} or {state, name, artist, album, duration, position (s, or -1)}.
    /// `player state` is deliberately outside any `try`: if it fails, the reading fails.
    static func state(for source: MediaSource) -> String {
        let body = """
        set pState to player state
        if pState is stopped then return {"stopped"}
        set tState to "playing"
        if pState is paused then set tState to "paused"
        set tName to ""
        set tArtist to ""
        set tAlbum to ""
        set tDuration to 0
        set tPosition to -1
        try
        set t to current track
        try
        set tName to name of t
        \(rethrowUnreachable)
        end try
        try
        set tArtist to artist of t
        \(rethrowUnreachable)
        end try
        try
        set tAlbum to album of t
        \(rethrowUnreachable)
        end try
        try
        set tDuration to duration of t
        \(rethrowUnreachable)
        end try
        \(rethrowUnreachable)
        end try
        try
        set tPosition to player position
        \(rethrowUnreachable)
        end try
        return {tState, tName, tArtist, tAlbum, tDuration, tPosition}
        """
        return guarded(source, timeout: stateTimeout, body, fallback: "return {\"notrunning\"}")
    }

    /// Returns {name, image data} for Music, {name, artwork url} for Spotify, or {} when unavailable.
    static func artwork(for source: MediaSource) -> String {
        switch source {
        case .music:
            return guarded(source, timeout: artworkTimeout, """
            try
            set t to current track
            set n to name of t
            \(rethrowUnreachable)
            return {}
            end try
            try
            return {n, data of artwork 1 of t}
            \(rethrowUnreachable)
            end try
            try
            return {n, raw data of artwork 1 of t}
            \(rethrowUnreachable)
            end try
            """)
        case .spotify:
            return guarded(source, timeout: artworkTimeout, """
            try
            set t to current track
            return {name of t, artwork url of t}
            \(rethrowUnreachable)
            end try
            """)
        }
    }
}
