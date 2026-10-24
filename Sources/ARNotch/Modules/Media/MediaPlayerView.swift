import AppKit
import SwiftUI

/// Expanded player on the Home tab (~280×130 pt available).
struct MediaPlayerView: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        Group {
            if media.hasTrack {
                MediaNowPlayingContent(media: media)
                    .transition(.opacity)
            } else if media.automationDenied {
                MediaPermissionContent(media: media)
                    .transition(.opacity)
            } else {
                MediaEmptyContent(media: media)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: media.hasTrack)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: media.automationDenied)
    }
}

// MARK: Now playing

private struct MediaNowPlayingContent: View {
    @ObservedObject var media: MediaController

    private let artworkSize: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                MediaBadgedArtwork(media: media, size: artworkSize)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(media.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                            Text(media.artist.isEmpty ? media.album : media.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(helpText)

                        Spacer(minLength: 0)

                        MediaVisualizerBars(isPlaying: media.isPlaying, tint: media.accentColor)
                            .frame(width: 14, height: 12)
                            .padding(.top, 3)
                    }

                    Spacer(minLength: 4)

                    if media.automationDenied {
                        MediaPermissionButton(media: media, compact: true)
                            .frame(maxWidth: .infinity)
                    } else {
                        MediaTransportControls(media: media)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: artworkSize)
            }

            MediaProgressRow(media: media)
        }
    }

    private var helpText: String {
        [media.title, media.artist, media.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// Album art with the source app's icon tucked into the corner; clicking it brings the player forward.
private struct MediaBadgedArtwork: View {
    @ObservedObject var media: MediaController
    let size: CGFloat

    var body: some View {
        MediaArtworkView(image: media.artwork, size: size, cornerRadius: 12)
            .shadow(color: media.accentColor.opacity(media.artwork == nil ? 0 : 0.28), radius: 12, y: 3)
            .overlay(alignment: .bottomTrailing) {
                if let icon = media.sourceIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .offset(x: 5, y: 5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                media.openCurrentPlayer()
            }
            .help(media.sourceName.map { "Open \($0)" } ?? "")
    }
}

/// Square artwork with a music-note placeholder; cross-fades when the image changes.
struct MediaArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: max(9, size * 0.36), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
    }
}

// MARK: Controls

private struct MediaTransportControls: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 6) {
            MediaControlButton(symbol: "backward.fill", size: 14, help: "Previous") { media.previous() }
            MediaControlButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 20,
                               help: media.isPlaying ? "Pause" : "Play") { media.playPause() }
            MediaControlButton(symbol: "forward.fill", size: 14, help: "Next") { media.next() }
        }
    }
}

private struct MediaControlButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    // Plain `State` values throughout: the macOS 27 SDK's `@State` macro plugin ships only with Xcode.
    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.88))
                .frame(width: 32, height: 30)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)).frame(width: 30, height: 30))
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaPressButtonStyle())
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

/// Springy press feedback for icon buttons.
struct MediaPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: Progress

/// Elapsed time, a draggable accent-colored bar and remaining time. Ticks once per track second, only while
/// visible and playing (the bar moves about a pixel per second, so finer ticks would only cost renders).
private struct MediaProgressRow: View {
    @ObservedObject var media: MediaController
    @EnvironmentObject private var vm: NotchViewModel

    private let scrub = State<Double?>(initialValue: nil)
    private let hover = State(initialValue: false)
    /// True while the drag is live; SwiftUI resets it on cancellation too, which never reaches `onEnded`.
    private let dragging = GestureState(initialValue: false)
    private var scrubFraction: Double? { scrub.wrappedValue }
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        TimelineView(MediaSecondsSchedule(
            secondBoundary: media.elapsedTimestamp.addingTimeInterval(-media.elapsed.truncatingRemainder(dividingBy: 1)),
            paused: !media.isPlaying || scrubFraction != nil
        )) { context in
            let duration = media.duration
            let position = scrubFraction.map { $0 * duration } ?? media.currentElapsed(at: context.date)
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

            HStack(spacing: 8) {
                Text(duration > 0 || position > 0 ? Self.format(position) : "--:--")
                    .frame(width: 38, alignment: .leading)
                bar(fraction: fraction, enabled: duration > 0)
                Text(duration > 0 ? "-" + Self.format(max(0, duration - position)) : "--:--")
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(Color.white.opacity(0.5))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .onChange(of: dragging.wrappedValue) { _, active in
            // Deferred so a normal end runs `onEnded` (and seeks) first; after that this is a no-op.
            if !active { DispatchQueue.main.async { cancelScrub() } }
        }
        // E.g. the track list ends mid-drag and this row is removed.
        .onDisappear { cancelScrub() }
    }

    private func bar(fraction: Double, enabled: Bool) -> some View {
        let active = enabled && (hovering || scrubFraction != nil)
        let height: CGFloat = active ? 6 : 4
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(media.accentColor)
                    .frame(width: fraction > 0 ? max(height, geo.size.width * fraction) : 0)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(dragging) { _, active, _ in active = true }
                    .onChanged { value in
                        guard enabled, geo.size.width > 0 else { return }
                        if scrubFraction == nil { beginScrub() }
                        scrub.wrappedValue = min(max(value.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        guard let fraction = scrubFraction else { return }
                        media.seek(to: fraction * media.duration)
                        scrub.wrappedValue = nil
                        endScrub()
                    }
            )
        }
        .frame(height: 14)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
    }

    /// Keep the notch open while scrubbing, even if the pointer slips below it.
    private func beginScrub() {
        vm.hold(.scrub)
    }

    private func endScrub() {
        vm.release(.scrub)
    }

    /// Ends a scrub without seeking; does nothing when no scrub is in progress.
    private func cancelScrub() {
        guard scrubFraction != nil || vm.isHeld(by: .scrub) else { return }
        scrub.wrappedValue = nil
        endScrub()
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Timeline entries on the playing track's whole seconds, so the elapsed time turns over on time; a single entry
/// while paused.
private struct MediaSecondsSchedule: TimelineSchedule {
    /// A moment at which the track position was a whole number of seconds.
    var secondBoundary: Date
    var paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        // The next boundary after `startDate`, plus a hair so the floored position has already moved on.
        let offset = startDate.timeIntervalSince(secondBoundary)
        var boundary = secondBoundary.addingTimeInterval(offset.rounded(.down) + 1.01)
        let paused = paused
        return AnyIterator {
            defer {
                if paused {
                    next = nil
                } else {
                    next = boundary
                    boundary = boundary.addingTimeInterval(1)
                }
            }
            return next
        }
    }
}

// MARK: Empty & permission states

private struct MediaEmptyContent: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 12) {
            MediaArtworkView(image: nil, size: 72, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                Text(media.installedSources.isEmpty ? "No supported player found" : "Start music in")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                HStack(spacing: 6) {
                    ForEach(media.installedSources) { player in
                        MediaLaunchButton(media: media, player: player)
                    }
                }
                .padding(.top, 2)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .onAppear { media.refreshInstalledPlayers() }
    }
}

private struct MediaLaunchButton: View {
    @ObservedObject var media: MediaController
    let player: MediaSource

    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }
    private let iconState = State<NSImage?>(initialValue: nil)

    var body: some View {
        Button {
            media.openPlayer(player)
        } label: {
            HStack(spacing: 5) {
                if let icon = iconState.wrappedValue {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15)
                }
                Text(player.displayName)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.18 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(MediaPressButtonStyle())
        .onHover { hover.wrappedValue = $0 }
        .help("Open \(player.displayName)")
        .onAppear {
            if iconState.wrappedValue == nil, let url = player.applicationURL {
                iconState.wrappedValue = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}

private struct MediaPermissionContent: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08))
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("Allow control of \(media.automationDeniedSource?.displayName ?? "your player")")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Turn on ARNotch in Privacy & Security › Automation.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                MediaPermissionButton(media: media, compact: false)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Opens System Settings › Privacy & Security › Automation.
private struct MediaPermissionButton: View {
    @ObservedObject var media: MediaController
    let compact: Bool

    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button {
            media.openAutomationSettings()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                Text(compact ? "Allow playback control" : "Open Settings")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.2 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(MediaPressButtonStyle())
        .onHover { hover.wrappedValue = $0 }
        .help("Open Automation settings")
    }
}
