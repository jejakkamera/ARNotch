// Renders Crest's app icon and packs it into an .icns file.
// Usage: /usr/bin/swift tools/make_icon.swift <output.icns> [--preview <preview.png>]
import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: Geometry

/// Continuous-corner ("squircle") rounded rect in a y-down coordinate space.
/// Each corner blends into its edges over 1.5287 × radius, like Apple's icon shape.
func squirclePath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let limit: CGFloat = 1.52866483
    let r = min(radius, min(rect.width, rect.height) / 2 / limit)
    // Corner curve from (limit, 0) to (0, limit), in units of r along the incoming (u) and outgoing (v) edges.
    let segments: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 1.08849323, y: 0), CGPoint(x: 0.86840689, y: 0), CGPoint(x: 0.66993427, y: 0.06549600)),
        (CGPoint(x: 0.37282392, y: 0.16244859), CGPoint(x: 0.16244859, y: 0.37282392), CGPoint(x: 0.06549600, y: 0.66993427)),
        (CGPoint(x: 0, y: 0.86840689), CGPoint(x: 0, y: 1.08849323), CGPoint(x: 0, y: limit)),
    ]
    // (corner, u = back along the incoming edge, v = forward along the outgoing edge), clockwise on screen.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    func map(_ p: CGPoint, _ corner: (CGPoint, CGVector, CGVector)) -> CGPoint {
        let (c, u, v) = corner
        return CGPoint(x: c.x + r * (p.x * u.dx + p.y * v.dx), y: c.y + r * (p.x * u.dy + p.y * v.dy))
    }

    let path = CGMutablePath()
    path.move(to: map(CGPoint(x: 0, y: limit), corners[3]))
    for corner in corners {
        path.addLine(to: map(CGPoint(x: limit, y: 0), corner))
        for (c1, c2, end) in segments {
            path.addCurve(to: map(end, corner), control1: map(c1, corner), control2: map(c2, corner))
        }
    }
    path.closeSubpath()
    return path
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

// MARK: Drawing

/// Draws the icon into a square bitmap of `pixels` × `pixels`, designed on a 1024 grid.
func renderIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / 1024
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // Work in a y-down 1024 × 1024 design space.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    // Big Sur grid: 824pt body centred on the canvas, corner ≈ 22.5 %.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(body, radius: 824 * 0.225)

    // Drop shadow (shadow offsets are in device space, which is y-up).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: color(0, 0, 0, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(0.06, 0.05, 0.14))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Deep indigo → near-black background.
    ctx.drawLinearGradient(
        gradient([
            (0.0, color(0.33, 0.27, 0.92)),
            (0.45, color(0.17, 0.12, 0.50)),
            (1.0, color(0.03, 0.03, 0.08)),
        ]),
        start: CGPoint(x: 330, y: 100), end: CGPoint(x: 700, y: 924),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Violet bloom around the notch.
    ctx.drawRadialGradient(
        gradient([(0, color(0.62, 0.45, 1.0, 0.55)), (1, color(0.62, 0.45, 1.0, 0))]),
        startCenter: CGPoint(x: 512, y: 300), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 300), endRadius: 430, options: []
    )
    // Faint cyan glow spilling down from the pill.
    ctx.drawRadialGradient(
        gradient([(0, color(0.35, 0.80, 1.0, 0.16)), (1, color(0.35, 0.80, 1.0, 0))]),
        startCenter: CGPoint(x: 512, y: 400), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 400), endRadius: 240, options: []
    )

    // Glossy top sheen.
    ctx.drawLinearGradient(
        gradient([(0, color(1, 1, 1, 0.14)), (1, color(1, 1, 1, 0))]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 440), options: []
    )

    drawNotchPill(ctx, scale: scale)
    ctx.restoreGState()

    // Inner highlight: a hairline rim, bright at the top and fading toward the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(1, 1, 1, 0.45)), (0.35, color(1, 1, 1, 0.08)), (1, color(1, 1, 1, 0.03))]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

/// The black Dynamic-Island-style pill with a glowing dot and a little visualizer.
func drawNotchPill(_ ctx: CGContext, scale: CGFloat) {
    let pill = CGRect(x: 262, y: 236, width: 500, height: 148)
    let pillPath = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)

    // Soft shadow under the pill.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 40 * scale, color: color(0, 0, 0, 0.6))
    ctx.addPath(pillPath)
    ctx.setFillColor(color(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle top-lit rim on the pill.
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(1, 1, 1, 0.22)), (1, color(1, 1, 1, 0.02))]),
        start: CGPoint(x: 512, y: pill.minY), end: CGPoint(x: 512, y: pill.maxY), options: []
    )
    ctx.restoreGState()

    // Glowing status dot on the left.
    let dotCenter = CGPoint(x: pill.minX + 82, y: pill.midY)
    ctx.saveGState()
    ctx.drawRadialGradient(
        gradient([(0, color(0.30, 1.0, 0.62, 0.55)), (1, color(0.30, 1.0, 0.62, 0))]),
        startCenter: dotCenter, startRadius: 0, endCenter: dotCenter, endRadius: 62, options: []
    )
    ctx.setShadow(offset: .zero, blur: 18 * scale, color: color(0.30, 1.0, 0.62, 0.9))
    ctx.setFillColor(color(0.45, 1.0, 0.72))
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - 21, y: dotCenter.y - 21, width: 42, height: 42))
    ctx.restoreGState()

    // Visualizer bars on the right, cyan → violet.
    let heights: [CGFloat] = [44, 84, 62, 100, 54]
    let barWidth: CGFloat = 20
    let gap: CGFloat = 13
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = pill.maxX - 78 - totalWidth
    let bars = CGMutablePath()
    for h in heights {
        let bar = CGRect(x: x, y: pill.midY - h / 2, width: barWidth, height: h)
        bars.addRoundedRect(in: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        x += barWidth + gap
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22 * scale, color: color(0.55, 0.60, 1.0, 0.85))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(bars)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0.45, 0.92, 1.0)), (1, color(0.70, 0.45, 1.0))]),
        start: CGPoint(x: 512, y: pill.midY - 50), end: CGPoint(x: 512, y: pill.midY + 50),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: Output

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't create \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make_icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <output.icns> [--preview <file.png>]\n".data(using: .utf8)!)
    exit(64)
}
let output = URL(fileURLWithPath: args[1])
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Crest-\(UUID().uuidString).iconset")

do {
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }

    // Render each pixel size once, then reuse it for every name that needs it.
    var cache: [Int: CGImage] = [:]
    for base in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = base * factor
            let image = cache[pixels] ?? renderIcon(pixels: pixels)
            cache[pixels] = image
            let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try writePNG(image, to: iconset.appendingPathComponent(name))
        }
    }

    if let flag = args.firstIndex(of: "--preview"), args.indices.contains(flag + 1), let full = cache[1024] {
        try writePNG(full, to: URL(fileURLWithPath: args[flag + 1]))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "make_icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil failed (\(iconutil.terminationStatus))"])
    }
    let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
    print("Wrote \(output.path) (\(size) bytes)")
} catch {
    FileHandle.standardError.write("make_icon: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
