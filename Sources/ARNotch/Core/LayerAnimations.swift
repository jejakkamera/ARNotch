import AppKit
import QuartzCore
import SwiftUI

// Always-on motion for the notch, run by Core Animation.
//
// A SwiftUI animation that never ends (`TimelineView(.animation)`, `repeatForever`, `phaseAnimator`, repeating
// symbol effects) makes the hosting view re-evaluate and re-render the whole notch on every display frame.
// These views hand the motion to `CAAnimation`s on their own layers instead: the render server interpolates
// them, so the app does no per-frame work. SwiftUI only reaches them through `updateNSView` when an input
// changes, and an animation is rebuilt only when its parameters change. Animations exist only while the view
// is in a window, and Reduce Motion stops the looping ones.

// MARK: - Motion

/// A looping ease from a start state to an end state and back.
struct LayerPulse: Hashable {
    var startOpacity: Float = 1
    var endOpacity: Float = 0.35
    var startScale: CGFloat = 1
    var endScale: CGFloat = 1
    /// Seconds for a full start → end → start cycle.
    var period: CFTimeInterval = 1.4

    /// Close to SF Symbols' repeating `.pulse`.
    static let standard = LayerPulse()
    /// Half the speed of `standard`, for ambient indicators.
    static let slow = LayerPulse(period: 2.8)
}

/// A looping swing around a pivot: a pause, quick swings to alternating sides, then back to rest.
struct LayerWiggle: Hashable {
    /// Peak angle in degrees; the first swing goes counterclockwise.
    var angle: Double = 16
    var swings = 4
    var swingDuration: CFTimeInterval = 0.09
    /// Still time at the start of each cycle.
    var pause: CFTimeInterval = 0.45
    /// Pivot in unit coordinates of the glyph; `.top` hangs it from its top edge.
    var anchor: UnitPoint = .top

    /// A ringing bell.
    static let bell = LayerWiggle()
}

/// Continuous motion of a `LayerGlyph`.
enum LayerGlyphEffect: Equatable {
    case none
    case pulse(LayerPulse)
    /// A pulse that also blends the glyph's colour to the given one at the pulse's end state.
    case flash(Color, LayerPulse)
    case wiggle(LayerWiggle)
}

/// What a `LayerGlyph` draws.
enum LayerGlyphContent: Hashable {
    /// An SF Symbol, as `Image(systemName:)` with `.font(.system(size:weight:))`.
    case symbol(String, size: CGFloat, weight: Font.Weight = .regular)
    /// A short run of text in the system font with monospaced digits.
    case text(String, size: CGFloat, weight: Font.Weight = .regular)

    /// The SwiftUI view the glyph stands in for; its rendering becomes the glyph's shape.
    @ViewBuilder fileprivate var view: some View {
        switch self {
        case let .symbol(name, size, weight):
            Image(systemName: name).font(.system(size: size, weight: weight))
        case let .text(string, size, weight):
            Text(verbatim: string).font(.system(size: size, weight: weight)).monospacedDigit()
        }
    }
}

// MARK: - SwiftUI views

/// Audio-visualizer bars (capsules centred vertically). While `isAnimating`, each bar loops through its own
/// smooth mix of sines with its own period, so they move organically; otherwise they settle low and stay still.
struct LayerVisualizerBars: NSViewRepresentable {
    var isAnimating: Bool
    var color: Color
    var barCount = 4
    /// Height fraction of the resting bars.
    var restingLevel: CGFloat = 0.22

    func makeNSView(context: Context) -> LayerVisualizerBarsView { LayerVisualizerBarsView() }

    func updateNSView(_ view: LayerVisualizerBarsView, context: Context) {
        view.update(
            isAnimating: isAnimating && !context.environment.accessibilityReduceMotion,
            color: color.resolve(in: context.environment).cgColor,
            barCount: max(1, barCount),
            restingLevel: restingLevel
        )
    }
}

/// A filled circle (the largest that fits, centred) that can pulse, with an optional glow in its own colour.
struct LayerPulsingDot: NSViewRepresentable {
    var color: Color
    var isPulsing = true
    var pulse = LayerPulse.standard
    /// Blur radius of the glow; 0 for none.
    var glowRadius: CGFloat = 0
    var glowOpacity: Float = 0.6

    func makeNSView(context: Context) -> LayerPulsingDotView { LayerPulsingDotView() }

    func updateNSView(_ view: LayerPulsingDotView, context: Context) {
        view.update(
            color: color.resolve(in: context.environment).cgColor,
            pulse: isPulsing && !context.environment.accessibilityReduceMotion ? pulse : nil,
            restingPulse: pulse,
            glow: LayerGlow(radius: glowRadius, opacity: glowOpacity)
        )
    }
}

/// An SF Symbol or short text, filled with `color` and drawn into a layer, with an optional glow and a looping
/// effect. It sizes itself to the glyph, like the `Image` or `Text` it replaces, and is exposed to accessibility
/// as that `Image` or `Text`, so labels attached at the call site (or to a container holding only it) reach
/// VoiceOver; a bare NSViewRepresentable would create no accessibility node and drop them.
struct LayerGlyph: View {
    var content: LayerGlyphContent
    var color: Color
    var effect: LayerGlyphEffect = .none
    /// Blur radius of a glow in the glyph's colour; 0 for none.
    var glowRadius: CGFloat = 0
    var glowOpacity: Float = 0.55

    init(_ content: LayerGlyphContent, color: Color, effect: LayerGlyphEffect = .none,
         glowRadius: CGFloat = 0, glowOpacity: Float = 0.55) {
        self.content = content
        self.color = color
        self.effect = effect
        self.glowRadius = glowRadius
        self.glowOpacity = glowOpacity
    }

    var body: some View {
        LayerGlyphRepresentable(content: content, color: color, effect: effect,
                                glowRadius: glowRadius, glowOpacity: glowOpacity)
            .accessibilityRepresentation { content.view }
    }
}

/// The layer-backed drawing behind `LayerGlyph`.
private struct LayerGlyphRepresentable: NSViewRepresentable {
    var content: LayerGlyphContent
    var color: Color
    var effect: LayerGlyphEffect
    var glowRadius: CGFloat
    var glowOpacity: Float

    func makeNSView(context: Context) -> LayerGlyphView { LayerGlyphView() }

    func updateNSView(_ view: LayerGlyphView, context: Context) {
        let environment = context.environment
        let resolved: LayerGlyphView.Effect
        var anchor = UnitPoint.center
        switch environment.accessibilityReduceMotion ? .none : effect {
        case .none:
            resolved = .none
        case .pulse(let pulse):
            resolved = .pulse(pulse)
        case .flash(let target, let pulse):
            resolved = .flash(target.resolve(in: environment).cgColor, pulse)
        case .wiggle(let wiggle):
            resolved = .wiggle(wiggle)
            anchor = wiggle.anchor
        }
        view.update(
            content: content,
            color: color.resolve(in: environment).cgColor,
            effect: resolved,
            anchor: anchor,
            glow: LayerGlow(radius: glowRadius, opacity: glowOpacity)
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LayerGlyphView, context: Context) -> CGSize? {
        LayerGlyphView.stencil(for: content, scale: nsView.backingScale)?.size ?? .zero
    }
}

/// A circular track with an arc from 12 o'clock clockwise to `fraction` (0...1). Changes ease linearly over
/// `transitionDuration`, so a value that ticks once a second moves continuously.
struct LayerProgressRing: NSViewRepresentable {
    var fraction: Double
    var color: Color
    var trackColor: Color
    var lineWidth: CGFloat
    var transitionDuration: CFTimeInterval = 1

    func makeNSView(context: Context) -> LayerProgressRingView { LayerProgressRingView() }

    func updateNSView(_ view: LayerProgressRingView, context: Context) {
        view.update(
            fraction: CGFloat(min(max(fraction, 0), 1)),
            color: color.resolve(in: context.environment).cgColor,
            trackColor: trackColor.resolve(in: context.environment).cgColor,
            lineWidth: lineWidth,
            transitionDuration: transitionDuration
        )
    }
}

// MARK: - Layer views

/// Glow drawn as a layer shadow in the shape's own colour.
struct LayerGlow: Equatable {
    var radius: CGFloat
    var opacity: Float

    /// Sets the shadow properties that differ, without implicit animations.
    func apply(to layer: CALayer, color: CGColor) {
        let opacity = radius > 0 ? opacity : 0
        guard layer.shadowColor != color || layer.shadowOpacity != opacity || layer.shadowRadius != radius
            || layer.shadowOffset != .zero else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowColor = color
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = .zero
        CATransaction.commit()
    }
}

/// Base of the layer views: layer-backed and flipped (so layer geometry runs top-down like SwiftUI's), invisible
/// to the mouse, and running its animations only while it is in a window and has a size.
class LayerAnimationView: NSView {
    /// Identifies the animations that were last installed; nil when none run.
    private var installedSignature: AnyHashable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Pixels per point of the window's screen.
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backingScaleDidChange()
        needsLayout = true
        refreshAnimations()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingScaleDidChange()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
        refreshAnimations()
    }

    /// Positions the sublayers for `bounds`; runs without implicit animations.
    func layoutLayers() {}

    /// Updates `contentsScale` and anything rendered for the screen's scale.
    func backingScaleDidChange() {}

    /// The animations the view should run now, as a value that changes whenever they must be rebuilt
    /// (nil for none).
    var animationSignature: AnyHashable? { nil }

    /// Replaces the animations described by `old` with those described by `new` (either may be nil).
    func animationsChanged(from old: AnyHashable?, to new: AnyHashable?) {}

    /// Rebuilds the animations if `animationSignature` changed; none run outside a window or at zero size.
    final func refreshAnimations() {
        let wanted = window != nil && bounds.width > 0 && bounds.height > 0 ? animationSignature : nil
        guard wanted != installedSignature else { return }
        let old = installedSignature
        installedSignature = wanted
        animationsChanged(from: old, to: wanted)
    }

    /// Rounds a coordinate to the nearest device pixel.
    func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = backingScale
        return (value * scale).rounded() / scale
    }
}

private extension CAMediaTimingFunction {
    static let easeInOut = CAMediaTimingFunction(name: .easeInEaseOut)
    static let easeOut = CAMediaTimingFunction(name: .easeOut)
    static let linear = CAMediaTimingFunction(name: .linear)
}

/// Adds `pulse` to `layer` as looping opacity and scale animations under `key`.
private func addPulse(_ pulse: LayerPulse, to layer: CALayer, key: String) {
    func swing(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = pulse.period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = .easeInOut
        return animation
    }
    if pulse.startOpacity != pulse.endOpacity {
        layer.add(swing("opacity", from: pulse.startOpacity, to: pulse.endOpacity), forKey: key + ".opacity")
    }
    if pulse.startScale != pulse.endScale {
        layer.add(swing("transform.scale", from: pulse.startScale, to: pulse.endScale), forKey: key + ".scale")
    }
}

private func removePulse(from layer: CALayer, key: String) {
    layer.removeAnimation(forKey: key + ".opacity")
    layer.removeAnimation(forKey: key + ".scale")
}

/// Backs `LayerVisualizerBars`.
final class LayerVisualizerBarsView: LayerAnimationView {
    private struct Signature: Hashable {
        var barCount: Int
        var size: CGSize
    }

    private var bars: [CALayer] = []
    private var isAnimating = false
    private var restingLevel: CGFloat = 0.22
    private var color: CGColor = CGColor(gray: 1, alpha: 1)
    /// When the loops' cycles began; kept while animating so a rebuild (e.g. a resize) doesn't jump.
    private var loopEpoch: CFTimeInterval?

    private static let leadIn: CFTimeInterval = 0.25

    func update(isAnimating: Bool, color: CGColor, barCount: Int, restingLevel: CGFloat) {
        if color != self.color {
            self.color = color
            bars.forEach { $0.backgroundColor = color }
        }
        if barCount != bars.count {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                bar.backgroundColor = color
                layer?.addSublayer(bar)
                return bar
            }
            needsLayout = true
        }
        if restingLevel != self.restingLevel {
            self.restingLevel = restingLevel
            needsLayout = true
        }
        if isAnimating != self.isAnimating {
            self.isAnimating = isAnimating
            refreshAnimations()
        }
    }

    private var barWidth: CGFloat {
        let count = CGFloat(bars.count)
        return max(1, (bounds.width - spacing * (count - 1)) / count)
    }

    private var spacing: CGFloat { max(1, bounds.width * 0.14) }

    private var restingHeight: CGFloat { max(barWidth, bounds.height * restingLevel) }

    override func layoutLayers() {
        let width = barWidth
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: restingHeight)
            bar.position = CGPoint(x: CGFloat(index) * (width + spacing) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
    }

    override var animationSignature: AnyHashable? {
        isAnimating ? Signature(barCount: bars.count, size: bounds.size) : nil
    }

    override func animationsChanged(from old: AnyHashable?, to new: AnyHashable?) {
        let current = bars.map { $0.presentation()?.bounds.height ?? $0.bounds.height }
        for bar in bars {
            bar.removeAnimation(forKey: "loop")
            bar.removeAnimation(forKey: "leadIn")
            bar.removeAnimation(forKey: "settle")
        }
        guard new != nil else {
            loopEpoch = nil
            // Settle from wherever the bars were, like a spring, when playback pauses in view.
            guard old != nil, window != nil else { return }
            for (bar, height) in zip(bars, current) where abs(height - restingHeight) > 0.25 {
                let spring = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.2)
                spring.keyPath = "bounds.size.height"
                spring.fromValue = height
                spring.toValue = restingHeight
                spring.duration = spring.settlingDuration
                bar.add(spring, forKey: "settle")
            }
            return
        }

        let now = bars.first?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        let isResuming = loopEpoch == nil
        let epoch = loopEpoch ?? now + Self.leadIn
        loopEpoch = epoch
        for (index, bar) in bars.enumerated() {
            let values = Self.loopHeights(bar: index, maxHeight: bounds.height, minHeight: barWidth)
            let loop = CAKeyframeAnimation(keyPath: "bounds.size.height")
            loop.values = values.heights
            loop.calculationMode = .cubic
            loop.duration = values.period
            loop.repeatCount = .infinity
            loop.beginTime = epoch
            loop.fillMode = .backwards
            bar.add(loop, forKey: "loop")

            // Grow from the resting (or current) height into the first frame of the loop.
            if isResuming, let first = values.heights.first {
                let lead = CABasicAnimation(keyPath: "bounds.size.height")
                lead.fromValue = current[index]
                lead.toValue = first
                lead.duration = Self.leadIn
                lead.timingFunction = .easeOut
                bar.add(lead, forKey: "leadIn")
            }
        }
    }

    /// One seamless cycle of heights for a bar: three sines whose frequencies are whole multiples of the bar's
    /// own period (close to 0.84, 1.42 and 0.37 Hz), each bar with its own period and phase.
    private static func loopHeights(bar index: Int, maxHeight: CGFloat, minHeight: CGFloat) -> (heights: [CGFloat], period: CFTimeInterval) {
        let i = Double(index)
        let period = 2.6 + 0.29 * Double((index * 3) % 5)
        func cycles(_ radiansPerSecond: Double) -> Double {
            max(1, (radiansPerSecond * period / (2 * .pi)).rounded())
        }
        let a = cycles(5.3 + i * 0.83), b = cycles(max(3, 8.9 - i * 0.61)), c = cycles(2.3 + i * 0.37)
        let phase = i * 1.913 + 0.37
        let samples = 40
        let heights = (0...samples).map { step -> CGFloat in
            let t = Double(step % samples) / Double(samples) * 2 * .pi
            let mix = (sin(t * a + phase) * 0.5 + sin(t * b + phase * 2.41) * 0.3 + sin(t * c + phase * 0.73) * 0.2 + 1) / 2
            return max(minHeight, min(maxHeight, maxHeight * CGFloat(0.25 + 0.72 * mix)))
        }
        return (heights, period)
    }
}

/// Backs `LayerPulsingDot`.
final class LayerPulsingDotView: LayerAnimationView {
    private let dot = CALayer()
    private var pulse: LayerPulse?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(dot)
    }

    func update(color: CGColor, pulse: LayerPulse?, restingPulse: LayerPulse, glow: LayerGlow) {
        if dot.backgroundColor != color { dot.backgroundColor = color }
        glow.apply(to: dot, color: color)
        // At rest the dot shows the pulse's start state.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.opacity = restingPulse.startOpacity
        dot.setValue(restingPulse.startScale, forKeyPath: "transform.scale")
        CATransaction.commit()
        if pulse != self.pulse {
            self.pulse = pulse
            refreshAnimations()
        }
    }

    override func layoutLayers() {
        let diameter = min(bounds.width, bounds.height)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        dot.cornerRadius = diameter / 2
    }

    override var animationSignature: AnyHashable? { pulse }

    override func animationsChanged(from old: AnyHashable?, to new: AnyHashable?) {
        removePulse(from: dot, key: "pulse")
        if let pulse = new as? LayerPulse { addPulse(pulse, to: dot, key: "pulse") }
    }
}

/// Backs `LayerGlyph`: `glyph` is positioned, animated and casts the glow; `fill` holds the colour and is
/// masked by `stencil`, the glyph's shape.
final class LayerGlyphView: LayerAnimationView {
    enum Effect: Hashable {
        case none
        case pulse(LayerPulse)
        case flash(CGColor, LayerPulse)
        case wiggle(LayerWiggle)
    }

    private let glyph = CALayer()
    private let fill = CALayer()
    private let stencil = CALayer()
    private var content: LayerGlyphContent?
    private var color: CGColor?
    private var effect = Effect.none
    private var anchor = UnitPoint.center

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill.mask = stencil
        glyph.addSublayer(fill)
        layer?.addSublayer(glyph)
    }

    func update(content: LayerGlyphContent, color: CGColor, effect: Effect, anchor: UnitPoint, glow: LayerGlow) {
        if content != self.content {
            self.content = content
            renderStencil()
            needsLayout = true
        }
        if anchor != self.anchor {
            self.anchor = anchor
            needsLayout = true
        }
        if color != self.color {
            self.color = color
            fill.backgroundColor = color
        }
        glow.apply(to: glyph, color: color)
        if effect != self.effect {
            self.effect = effect
            refreshAnimations()
        } else if case .flash = effect {
            // The flash animates from the base colour, so a new base colour restarts it.
            refreshAnimations()
        }
    }

    override func backingScaleDidChange() {
        renderStencil()
    }

    private func renderStencil() {
        let scale = backingScale
        stencil.contents = content.flatMap { Self.stencil(for: $0, scale: scale) }?.image
        stencil.contentsScale = scale
        stencil.contentsGravity = .resize
    }

    override func layoutLayers() {
        let size = content.flatMap { Self.stencil(for: $0, scale: backingScale) }?.size ?? .zero
        let origin = CGPoint(x: pixelAligned((bounds.width - size.width) / 2), y: pixelAligned((bounds.height - size.height) / 2))
        glyph.bounds = CGRect(origin: .zero, size: size)
        glyph.anchorPoint = CGPoint(x: anchor.x, y: anchor.y)
        glyph.position = CGPoint(x: origin.x + anchor.x * size.width, y: origin.y + anchor.y * size.height)
        fill.frame = glyph.bounds
        stencil.frame = fill.bounds
    }

    override var animationSignature: AnyHashable? {
        switch effect {
        case .none: return nil
        case .flash(let target, let pulse): return [AnyHashable(target), AnyHashable(pulse), AnyHashable(color)]
        default: return effect
        }
    }

    override func animationsChanged(from old: AnyHashable?, to new: AnyHashable?) {
        removePulse(from: glyph, key: "pulse")
        fill.removeAnimation(forKey: "flash")
        glyph.removeAnimation(forKey: "wiggle")
        guard new != nil else { return }

        switch effect {
        case .none:
            break
        case .pulse(let pulse):
            addPulse(pulse, to: glyph, key: "pulse")
        case .flash(let target, let pulse):
            addPulse(pulse, to: glyph, key: "pulse")
            let blend = CABasicAnimation(keyPath: "backgroundColor")
            blend.fromValue = color
            blend.toValue = target
            blend.duration = pulse.period / 2
            blend.autoreverses = true
            blend.repeatCount = .infinity
            blend.timingFunction = .easeInOut
            fill.add(blend, forKey: "flash")
        case .wiggle(let wiggle):
            glyph.add(Self.wiggleAnimation(wiggle), forKey: "wiggle")
        }
    }

    /// Pause, `swings` eased swings to alternating sides, then an ease back to rest.
    private static func wiggleAnimation(_ wiggle: LayerWiggle) -> CAKeyframeAnimation {
        let radians = wiggle.angle * .pi / 180
        let settle = 0.1
        var values: [Double] = [0, 0]
        var times: [CFTimeInterval] = [0, wiggle.pause]
        for swing in 0..<max(1, wiggle.swings) {
            values.append(swing.isMultiple(of: 2) ? -radians : radians)
            times.append(times[times.count - 1] + wiggle.swingDuration)
        }
        values.append(0)
        times.append(times[times.count - 1] + settle)
        let total = times[times.count - 1]

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0 / total) }
        animation.timingFunctions = [.linear] + Array(repeating: .easeInOut, count: values.count - 3) + [.easeOut]
        animation.duration = total
        animation.repeatCount = .infinity
        return animation
    }

    // Stencils

    /// A glyph's shape: opaque white (only its alpha is used), `size` points at the scale it was rendered for.
    struct Stencil {
        let image: CGImage
        let size: CGSize
    }

    private struct StencilKey: Hashable {
        var content: LayerGlyphContent
        var scale: CGFloat
    }

    /// Rendered shapes; the set of glyphs in use is small.
    private static var stencils: [StencilKey: Stencil] = [:]

    /// Renders the glyph with SwiftUI itself, so it matches the `Image` or `Text` it replaces.
    static func stencil(for content: LayerGlyphContent, scale: CGFloat) -> Stencil? {
        let key = StencilKey(content: content, scale: scale)
        if let cached = stencils[key] { return cached }
        let renderer = ImageRenderer(content: content.view.foregroundStyle(Color.white))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let stencil = Stencil(image: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        if stencils.count >= 32 { stencils.removeAll() }
        stencils[key] = stencil
        return stencil
    }
}

/// Backs `LayerProgressRing`.
final class LayerProgressRingView: LayerAnimationView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var fraction: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0
    }

    func update(fraction: CGFloat, color: CGColor, trackColor: CGColor, lineWidth: CGFloat, transitionDuration: CFTimeInterval) {
        if arc.strokeColor != color { arc.strokeColor = color }
        if track.strokeColor != trackColor { track.strokeColor = trackColor }
        if arc.lineWidth != lineWidth {
            arc.lineWidth = lineWidth
            track.lineWidth = lineWidth
            needsLayout = true
        }
        guard fraction != self.fraction else { return }
        let from = arc.presentation()?.strokeEnd ?? arc.strokeEnd
        self.fraction = fraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = fraction
        CATransaction.commit()
        guard window != nil, transitionDuration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = from
        animation.toValue = fraction
        animation.duration = transitionDuration
        animation.timingFunction = .linear
        arc.add(animation, forKey: "strokeEnd")
    }

    override func layoutLayers() {
        // Strokes are centred on the path; keep them inside the bounds.
        let inset = arc.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = max(0, min(rect.width, rect.height) / 2)
        let path = CGMutablePath()
        // Layer geometry runs top-down here, so increasing angles go clockwise on screen, starting at 12 o'clock.
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
        }
    }
}
