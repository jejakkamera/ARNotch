import AppKit

/// System-wide "now playing" (any app: browsers/YouTube, Spotify, Music, podcasts…).
///
/// macOS 15.4+ only serves MediaRemote to Apple-signed processes, so the bundled
/// `libCrestNowPlaying.dylib` (Helpers/NowPlayingBridge.m) runs inside `/usr/bin/perl` and streams
/// JSON lines; commands go back over stdin. The helper exits by itself when Crest goes away.
@MainActor
final class MediaNowPlayingBridge {
    struct State: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var timestamp = Date()
        var isPlaying = false
        var pid: pid_t = 0
        var artworkID: Int?

        var hasTrack: Bool { !title.isEmpty }
    }

    /// Called on the main actor for every update; `artwork` is non-nil only when the image changed.
    var onUpdate: ((State, Data?) -> Void)?
    /// Called once when the helper can't run (missing library, MediaRemote refused, repeated crashes).
    var onUnavailable: (() -> Void)?
    private(set) var isLive = false

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var crashes: [Date] = []
    private var stopped = false

    private static var libraryURL: URL? {
        Bundle.main.url(forResource: "libCrestNowPlaying", withExtension: "dylib")
    }

    private static let script = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $sym = DynaLoader::dl_find_symbol($lib, "crest_now_playing_run") or die "symbol";
    DynaLoader::dl_install_xsub("main::run", $sym);
    run();
    """

    func start() {
        guard process == nil, !stopped else { return }
        guard let library = Self.libraryURL, FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            onUnavailable?()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script, library.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // EOF: stop the handler, or it fires again immediately in a loop.
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaNowPlayingBridge.shared?.receive(chunk) }
            }
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MediaNowPlayingBridge.shared?.helperExited() }
            }
        }
        Self.shared = self
        do {
            try process.run()
        } catch {
            onUnavailable?()
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
    }

    func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Weak hook for the pipe callbacks, which run outside the actor.
    private static weak var shared: MediaNowPlayingBridge?

    private func receive(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if object["error"] != nil {
            stopped = true
            onUnavailable?()
            return
        }
        var state = State()
        state.title = object["title"] as? String ?? ""
        state.artist = object["artist"] as? String ?? ""
        state.album = object["album"] as? String ?? ""
        state.duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
        state.elapsed = (object["elapsed"] as? NSNumber)?.doubleValue ?? 0
        if let stamp = (object["timestamp"] as? NSNumber)?.doubleValue {
            state.timestamp = Date(timeIntervalSince1970: stamp)
        }
        state.isPlaying = (object["playing"] as? NSNumber)?.boolValue ?? false
        state.pid = pid_t((object["pid"] as? NSNumber)?.int32Value ?? 0)
        state.artworkID = (object["artworkId"] as? NSNumber)?.intValue
        let artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
        isLive = true
        onUpdate?(state, artwork)
    }

    /// Restarts after a crash; gives up after three exits within a minute.
    private func helperExited() {
        process = nil
        input = nil
        buffer.removeAll()
        guard !stopped else { return }
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count >= 3 {
            stopped = true
            isLive = false
            onUnavailable?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
        }
    }
}
