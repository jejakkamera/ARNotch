import SwiftUI

/// Left wing of the closed notch while music plays (44×notchHeight pt): album art.
struct MediaLiveActivityLeading: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        MediaArtworkView(image: media.artwork, size: 22, cornerRadius: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Right wing of the closed notch while music plays (44×notchHeight pt): animated visualizer.
struct MediaLiveActivityTrailing: View {
    @ObservedObject private var media = MediaController.shared

    var body: some View {
        MediaVisualizerBars(isPlaying: media.isPlaying, tint: media.accentColor)
            .frame(width: 16, height: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Audio-visualizer bars that move organically without audio access. The motion runs in Core Animation
/// (see `LayerVisualizerBars`), so it costs the app nothing per frame; the bars settle low while paused.
struct MediaVisualizerBars: View {
    var isPlaying: Bool
    var tint: Color
    var barCount = 4

    var body: some View {
        LayerVisualizerBars(isAnimating: isPlaying, color: tint, barCount: barCount)
    }
}
