import AppKit
import ImageIO
import SwiftUI

/// An accent color in HSB, computed off the main thread from album art.
struct MediaAccent: Sendable, Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

    static let neutral = MediaAccent(hue: 0, saturation: 0, brightness: 0.92)
    /// Shared instance so repeated assignments compare equal and don't republish.
    static let neutralColor = neutral.color

    /// Keeps the hue but makes the color readable on the black notch.
    func adjustedForDarkBackground() -> MediaAccent {
        guard saturation >= 0.15, brightness >= 0.12 else { return .neutral }
        return MediaAccent(
            hue: hue,
            saturation: min(max(saturation, 0.35), 0.75),
            brightness: max(brightness, 0.88)
        )
    }
}

/// Downscaled artwork plus its accent; CGImage is immutable, so handing it across threads is safe.
struct MediaDecodedArtwork: @unchecked Sendable {
    let image: CGImage
    let accent: MediaAccent
}

/// Cache entry (NSCache needs a class).
final class MediaArtworkEntry {
    let image: NSImage
    let accent: Color

    init(image: NSImage, accent: Color) {
        self.image = image
        self.accent = accent
    }
}

enum MediaArtworkProcessor {
    /// Downloads Spotify artwork without touching the shared disk cache.
    static let session = URLSession(configuration: .ephemeral)

    /// Decodes and downsizes image data (the notch never shows art larger than ~84 pt) and derives its accent.
    /// Call from a background queue.
    static func decode(_ data: Data, maxPixelSize: Int = 320) -> MediaDecodedArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let accent = averageColor(of: image)?.adjustedForDarkBackground() ?? .neutral
        return MediaDecodedArtwork(image: image, accent: accent)
    }

    /// Average color of a tiny rendition, weighted toward vivid pixels so muddy backgrounds don't dominate.
    static func averageColor(of image: CGImage) -> MediaAccent? {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.1 else { continue }
            let r = Double(pixels[offset]) / 255 / alpha
            let g = Double(pixels[offset + 1]) / 255 / alpha
            let b = Double(pixels[offset + 2]) / 255 / alpha
            let maxC = max(r, g, b)
            let saturation = maxC > 0 ? (maxC - min(r, g, b)) / maxC : 0
            let weight = 0.15 + saturation * maxC
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        guard total > 0 else { return nil }
        return hsb(red: red / total, green: green / total, blue: blue / total)
    }

    private static func hsb(red: Double, green: Double, blue: Double) -> MediaAccent {
        let maxC = max(red, green, blue)
        let delta = maxC - min(red, green, blue)
        var hue = 0.0
        if delta > 0 {
            if maxC == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return MediaAccent(hue: hue, saturation: maxC > 0 ? delta / maxC : 0, brightness: maxC)
    }
}
