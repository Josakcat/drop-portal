//
//  PortalStage.swift
//  DropPortal
//
//  The big half of a crossing on the Mac: a transparent, click-through layer
//  over the whole screen the card arrives on, behind the card. While the
//  phone drags, it holds a soft vignette and the effect's light on the right
//  edge (a rift with rays, a splash of water, a vortex pulling stars,
//  full-height scanlines, or wind and a contrail) aimed at the card; on the
//  send it flares and launches particles; where the card lands it plays the
//  impact (a bloom, a shockwave, a burst and the effect's own extra) and is
//  clear 0.9 s later.
//
//  Core Animation layers only. Every timed animation is a `Motion`, sampled
//  by one function, so the harness can render any instant of it as a still.
//

import AppKit
import DropPortalCore

// MARK: - Timing

/// A cubic Bézier easing, the same curve as CSS's cubic-bezier().
struct Ease {
    let x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat

    static let linear = Ease(x1: 0, y1: 0, x2: 1, y2: 1)
    /// Arriving: fast, then settling.
    static let out = Ease(x1: 0.16, y1: 0.84, x2: 0.3, y2: 1)
    /// Leaving: slow, then away.
    static let `in` = Ease(x1: 0.55, y1: 0, x2: 0.9, y2: 0.45)
    static let inOut = Ease(x1: 0.45, y1: 0, x2: 0.4, y2: 1)

    // The motion spec's curves (docs/effects.md, "Curves"), by its letters.
    /// A: accelerating into the phone's left edge.
    static let accel = Ease(x1: 0.40, y1: 0, x2: 0.85, y2: 0.35)
    /// T and O: decelerating to the landing, waves and folds opening.
    static let travel = Ease(x1: 0.16, y1: 1, x2: 0.30, y2: 1)
    /// F: opacity retiring.
    static let retire = Ease(x1: 0.22, y1: 0, x2: 0.58, y2: 1)
    /// I: a collapse, an iris closing.
    static let collapse = Ease(x1: 0.55, y1: 0, x2: 1, y2: 0.45)

    func callAsFunction(_ x: CGFloat) -> CGFloat {
        let x = min(1, max(0, x))
        if x1 == y1, x2 == y2 { return x }
        var lo: CGFloat = 0, hi: CGFloat = 1, t = x
        for _ in 0..<20 {
            let v = Self.bezier(t, x1, x2)
            if abs(v - x) < 0.0005 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return Self.bezier(t, y1, y2)
    }

    private static func bezier(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let s = 1 - t
        return 3 * a * t * s * s + 3 * b * t * t * s + t * t * t
    }
}

/// Piecewise linear through `(time, value)` pairs, time 0...1.
func keys(_ pairs: [(CGFloat, CGFloat)]) -> (CGFloat) -> CGFloat {
    { u in
        guard let first = pairs.first, let last = pairs.last else { return 0 }
        if u <= first.0 { return first.1 }
        for i in 1..<pairs.count where u <= pairs[i].0 {
            let (t0, v0) = pairs[i - 1], (t1, v1) = pairs[i]
            return t1 > t0 ? v0 + (v1 - v0) * (u - t0) / (t1 - t0) : v1
        }
        return last.1
    }
}

/// One timed change of a layer: opacity, transform and position as functions
/// of eased time 0...1. Live, it becomes keyframe animations sampled at 60 Hz
/// with the end state as the model value; `still` sets the values at that many
/// seconds instead, for the harness.
struct Motion {
    var duration: Double
    var delay: Double = 0
    var ease: Ease = .linear
    var opacity: ((CGFloat) -> CGFloat)?
    var transform: ((CGFloat) -> CATransform3D)?
    var position: ((CGFloat) -> CGPoint)?
    /// "transform", or "sublayerTransform" for a layer that shapes its sublayers.
    var transformKey = "transform"

    init(_ duration: Double, delay: Double = 0, ease: Ease = .linear) {
        self.duration = duration
        self.delay = delay
        self.ease = ease
    }

    @MainActor
    func run(on layer: CALayer, still: Double? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let still {
            let u = ease(CGFloat((still - delay) / duration))
            if let opacity { layer.opacity = Float(opacity(u)) }
            if let transform { layer.setValue(NSValue(caTransform3D: transform(u)), forKeyPath: transformKey) }
            if let position { layer.position = position(u) }
            return
        }
        let n = max(6, Int((duration * 60).rounded()))
        let us = (0...n).map { ease(CGFloat($0) / CGFloat(n)) }
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        func add(_ key: String, _ values: [Any]) {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.duration = duration
            a.beginTime = begin
            a.fillMode = .backwards
            a.calculationMode = .linear
            layer.setValue(values.last, forKeyPath: key)
            layer.add(a, forKey: "motion.\(key)")
        }
        if let opacity { add("opacity", us.map { NSNumber(value: Double(opacity($0))) }) }
        if let transform { add(transformKey, us.map { NSValue(caTransform3D: transform($0)) }) }
        if let position { add("position", us.map { NSValue(point: position($0)) }) }
    }
}

/// How far `t` is through `a...b`, eased: the spec's per-segment curves.
func seg(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat, _ ease: Ease = .linear) -> CGFloat {
    b > a ? ease((t - a) / (b - a)) : (t >= b ? 1 : 0)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }

/// Scale, then turn about z: the usual particle and glow transform.
func spin(_ scale: CGFloat, _ angle: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1) -> CATransform3D {
    CATransform3DRotate(CATransform3DMakeScale(scale * sx, scale * sy, 1), angle, 0, 0, 1)
}

/// A repeatable random sequence, so the harness draws the same burst every time.
struct Dice {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 40) & 0xFFFFFF) / CGFloat(0x1000000)
    }
    mutating func range(_ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + (r.upperBound - r.lowerBound) * next() }
    mutating func pick<T>(_ items: [T]) -> T { items[min(items.count - 1, Int(next() * CGFloat(items.count)))] }
}

// MARK: - Sprites

/// Small pictures for particles and glows, drawn once per shape and colour.
@MainActor
enum Sprite {
    enum Shape: String { case glow, core, drop, star, pixel, puff, ring, rim, streak }

    private static var cache: [String: CGImage] = [:]

    static func image(_ shape: Shape, _ color: NSColor) -> CGImage? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = "\(shape.rawValue)-\(c.redComponent)-\(c.greenComponent)-\(c.blueComponent)-\(c.alphaComponent)"
        if let hit = cache[key] { return hit }
        let image = draw(shape, c)
        cache[key] = image
        return image
    }

    private static func draw(_ shape: Shape, _ color: NSColor) -> CGImage? {
        let w = shape == .rim ? 512 : shape == .ring ? 256 : shape == .streak ? 96 : 64
        let h = shape == .rim ? 512 : shape == .ring ? 256 : shape == .streak ? 24 : 64
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let mid = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2), r = CGFloat(min(w, h)) / 2
        func radial(_ colors: [NSColor], _ stops: [CGFloat], center: CGPoint = mid, radius: CGFloat = r) {
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: colors.map(\.cgColor) as CFArray, locations: stops) else { return }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        let white = NSColor.white
        switch shape {
        case .glow:
            radial([white, color, color.withAlphaComponent(0.35), color.withAlphaComponent(0)], [0, 0.18, 0.5, 1])
        case .core:
            radial([white, white.withAlphaComponent(0.85), color.withAlphaComponent(0.4), color.withAlphaComponent(0)], [0, 0.3, 0.6, 1])
        case .puff:
            radial([white.withAlphaComponent(0.85), white.withAlphaComponent(0.45), white.withAlphaComponent(0)], [0, 0.45, 1])
        case .ring:
            radial([color.withAlphaComponent(0), color.withAlphaComponent(0), color.withAlphaComponent(0.55),
                    white.withAlphaComponent(0.95), color.withAlphaComponent(0.5), color.withAlphaComponent(0)],
                   [0, 0.62, 0.8, 0.88, 0.93, 1])
        case .rim:
            // A razor-thin white edge in a soft halo of the colour: the spec's waves and rims.
            radial([color.withAlphaComponent(0), color.withAlphaComponent(0), color.withAlphaComponent(0.22),
                    color.withAlphaComponent(0.7), white, color.withAlphaComponent(0.55), color.withAlphaComponent(0)],
                   [0, 0.8, 0.9, 0.95, 0.965, 0.978, 1])
        case .pixel:
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 14, y: 14, width: 36, height: 36))
            ctx.setFillColor(white.withAlphaComponent(0.7).cgColor)
            ctx.fill(CGRect(x: 24, y: 24, width: 16, height: 16))
        case .star:
            radial([color.withAlphaComponent(0.55), color.withAlphaComponent(0)], [0, 1], radius: r * 0.6)
            ctx.setFillColor(white.cgColor)
            for horizontal in [true, false] {
                let path = CGMutablePath()
                let a: CGFloat = horizontal ? r * 0.95 : r * 0.12, b: CGFloat = horizontal ? r * 0.12 : r * 0.95
                path.addEllipse(in: CGRect(x: mid.x - a, y: mid.y - b, width: 2 * a, height: 2 * b))
                ctx.addPath(path)
                ctx.fillPath()
            }
            radial([white, white.withAlphaComponent(0)], [0, 1], radius: r * 0.25)
        case .drop:
            // Round below, pointed above (bitmap and layers both have y up).
            let body = CGMutablePath()
            body.addArc(center: CGPoint(x: mid.x, y: 22), radius: 16, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: true)
            body.addLine(to: CGPoint(x: mid.x, y: 60))
            body.closeSubpath()
            ctx.addPath(body)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.setFillColor(white.withAlphaComponent(0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: mid.x - 9, y: 22, width: 7, height: 9))
        case .streak:
            // A comet: bright head on the right, tail to the left.
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [color.withAlphaComponent(0), color.withAlphaComponent(0.8), white].map(\.cgColor) as CFArray,
                                     locations: [0, 0.75, 1]) else { return nil }
            let bar = CGPath(roundedRect: CGRect(x: 2, y: CGFloat(h) / 2 - 3, width: CGFloat(w) - 4, height: 6),
                             cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(bar)
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: mid.y), end: CGPoint(x: CGFloat(w), y: mid.y), options: [])
        }
        return ctx.makeImage()
    }

    /// A layer showing `shape` at `size`, centred on `center`.
    static func layer(_ shape: Shape, _ color: NSColor, size: CGFloat, at center: CGPoint, aspect: CGFloat = 1) -> CALayer {
        let layer = CALayer()
        layer.contents = image(shape, color)
        let w = shape == .streak ? size * 4 : size
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: size * aspect)
        layer.position = center
        layer.opacity = 0
        return layer
    }
}

// MARK: - Particles

/// A one-shot burst of sprite particles: each its own layer on a path with
/// drag and gravity, so the same numbers draw live and as a still.
struct Burst {
    var count: Int
    var origin: CGPoint
    /// Start points spread over an ellipse with these radii.
    var jitter = CGSize.zero
    /// Direction (radians, 0 = right, y up) and half the cone around it.
    var angle: CGFloat = 0
    var cone: CGFloat = .pi
    var speed: ClosedRange<CGFloat>
    /// Points a second squared; negative falls.
    var gravity: CGFloat = 0
    /// How fast the speed dies away, per second.
    var drag: CGFloat = 2.6
    var life: ClosedRange<CGFloat>
    var delay: ClosedRange<CGFloat> = 0...0
    var size: ClosedRange<CGFloat>
    var shapes: [Sprite.Shape]
    var colors: [NSColor]
    /// Radians a second each particle turns (Paper plane's confetti), or for
    /// `inward`, how far it swirls on its way in.
    var turn: CGFloat = 0
    /// Scale at the end of a life.
    var grow: CGFloat = 0.35
    /// Starts out at speed × life from the origin and falls into it (a pull).
    var inward = false
    var seed: UInt64 = 1

    @MainActor
    func spawn(in parent: CALayer, still: Double? = nil) {
        var dice = Dice(seed)
        for _ in 0..<count {
            let shape = dice.pick(shapes), color = dice.pick(colors)
            let size = dice.range(self.size)
            let a = angle + (dice.next() * 2 - 1) * cone
            let v = dice.range(speed)
            let life = Double(dice.range(self.life)), delay = Double(dice.range(self.delay))
            let ja = dice.next() * 2 * .pi, jr = dice.next().squareRoot()
            let start = CGPoint(x: origin.x + cos(ja) * jitter.width * jr, y: origin.y + sin(ja) * jitter.height * jr)
            let turn = (dice.next() * 2 - 1) * self.turn
            let layer = Sprite.layer(shape, color, size: size, at: start)
            parent.addSublayer(layer)
            var m = Motion(life, delay: delay)
            let drag = self.drag, gravity = self.gravity, grow = self.grow, inward = self.inward
            let s0 = CGFloat(life)
            if inward {
                let r0 = v * s0, swirl = self.turn
                m.position = { u in
                    let k = pow(u, 1.7), r = r0 * (1 - k), th = a + swirl * k
                    return CGPoint(x: start.x + cos(th) * r, y: start.y + sin(th) * r)
                }
                m.transform = { u in spin(1 - 0.6 * u, (shape == .streak ? a + swirl * pow(u, 1.7) + .pi : 0)) }
                m.opacity = keys([(0, 0), (0.25, 1), (0.85, 0.9), (1, 0)])
            } else {
                m.position = { u in
                    let s = u * s0
                    let travel = drag > 0 ? (1 - exp(-drag * s)) / drag : s
                    return CGPoint(x: start.x + cos(a) * v * travel, y: start.y + sin(a) * v * travel + 0.5 * gravity * s * s)
                }
                m.transform = { u in
                    let scale = 1 + (grow - 1) * u
                    switch shape {
                    case .streak:
                        // Points where it flies; falls with gravity.
                        let s = u * s0, vx = cos(a) * v * exp(-drag * s), vy = sin(a) * v * exp(-drag * s) + gravity * s
                        return spin(scale, atan2(vy, vx))
                    default: return spin(scale, turn * u * CGFloat(life))
                    }
                }
                m.opacity = keys([(0, 0), (0.05, 1), (0.5, 0.85), (1, 0)])
            }
            m.run(on: layer, still: still)
        }
    }
}

/// A timed change of `layer` whose closures take seconds since it started,
/// so one keyframe track can hold several of the spec's segments, each with
/// its own curve (`seg`). `still` draws that instant instead, for the harness.
@MainActor
func timeline(_ layer: CALayer, _ seconds: Double, delay: Double = 0, still t: Double? = nil, key: String = "transform",
              opacity: ((CGFloat) -> CGFloat)? = nil, transform: ((CGFloat) -> CATransform3D)? = nil,
              position: ((CGFloat) -> CGPoint)? = nil) {
    var m = Motion(seconds, delay: delay)
    let d = CGFloat(seconds)
    m.transformKey = key
    if let opacity { m.opacity = { opacity($0 * d) } }
    if let transform { m.transform = { transform($0 * d) } }
    if let position { m.position = { position($0 * d) } }
    m.run(on: layer, still: t)
}

/// A rotation about y, in degrees: the rims' and the wings' tilt.
func turnY(_ degrees: CGFloat) -> CATransform3D { CATransform3DMakeRotation(degrees * .pi / 180, 0, 1, 0) }
func turnZ(_ degrees: CGFloat) -> CATransform3D { CATransform3DMakeRotation(degrees * .pi / 180, 0, 0, 1) }

// MARK: - Light layers

/// The effect's painted light on screen: the bitmap itself, or for Rainbow
/// a wheel of hues masked by the light's coverage with the white core over
/// it, so `turn` sweeps the hue across the effect. Only transforms, opacity
/// and the wheel's position change; nothing is painted again.
@MainActor
final class LightLayer {
    let layer = CALayer()
    private var wheel: CAGradientLayer?
    private var filled = false

    init(size: CGSize) {
        layer.bounds = CGRect(origin: .zero, size: size)
    }

    func show(_ bitmap: LightBitmap?) {
        guard let bitmap, !filled else { return }
        filled = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let core = bitmap.core else { layer.contents = bitmap.image; return }
        let bounds = layer.bounds
        func masked(_ image: CGImage) -> CALayer {
            let holder = CALayer(), mask = CALayer()
            holder.frame = bounds
            mask.frame = bounds
            mask.contents = image
            holder.mask = mask
            layer.addSublayer(holder)
            return holder
        }
        // Two turns of the wheel side by side, one turn per width of the light; `turn` slides it left.
        let wheel = CAGradientLayer()
        let stops = 12
        wheel.colors = (0...2 * stops).map { i in
            let hue = CGFloat(i % stops) / CGFloat(stops)
            return (NSColor(hue: hue, saturation: 0.9, brightness: 1, alpha: 1).blended(withFraction: 0.1, of: .white) ?? .white).cgColor
        }
        wheel.startPoint = CGPoint(x: 0, y: 0.5)
        wheel.endPoint = CGPoint(x: 1, y: 0.5)
        wheel.anchorPoint = CGPoint(x: 0, y: 0.5)
        wheel.bounds = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
        wheel.position = CGPoint(x: 0, y: bounds.midY)
        masked(bitmap.image).addSublayer(wheel)
        let white = masked(core)
        white.backgroundColor = NSColor.white.cgColor
        self.wheel = wheel
    }

    /// Where the wheel is, in turns, 0...1 (1 = the whole wheel has passed every point).
    func position(turn: CGFloat) -> CGPoint {
        CGPoint(x: -layer.bounds.width * min(1, max(0, turn)), y: layer.bounds.midY)
    }

    func setTurn(_ turn: CGFloat) {
        guard let wheel else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wheel.position = position(turn: turn)
        CATransaction.commit()
    }

    /// The hue sweeps from `from` to the end of the wheel over `seconds`: the impact's Rainbow.
    func sweep(from: CGFloat, seconds: Double, still t: Double?) {
        guard let wheel else { return }
        let d = CGFloat(seconds)
        timeline(wheel, seconds, still: t, position: { s in
            self.position(turn: lerp(from, 1, seg(s, 0, d, .inOut)))
        })
    }
}

extension Sprite {
    private static var halos: [String: CGImage] = [:]

    /// A strong glow round the card, open in the middle so slices and wings
    /// never show a block of colour: two halos of the colour, painted once.
    static func cardHalo(_ color: NSColor, card: CGSize, radius: CGFloat, pad: CGFloat) -> CGImage? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = "\(c.redComponent)-\(c.greenComponent)-\(c.blueComponent)-\(card)-\(radius)-\(pad)"
        if let hit = halos[key] { return hit }
        let w = Int(card.width + 2 * pad), h = Int(card.height + 2 * pad)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: pad, y: pad, width: card.width, height: card.height)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for (blur, alpha) in [(pad * 0.62, 1.0), (pad * 0.2, 0.9)] as [(CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: c.withAlphaComponent(alpha).cgColor)
            ctx.setFillColor(c.cgColor)
            ctx.addPath(shape); ctx.fillPath()
            ctx.restoreGState()
        }
        // Open the middle, a little inside the card's edge.
        ctx.setBlendMode(.clear)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 6, dy: 6), cornerWidth: max(0, radius - 6), cornerHeight: max(0, radius - 6), transform: nil))
        ctx.fillPath()
        let image = ctx.makeImage()
        halos[key] = image
        return image
    }
}

// MARK: - The stage

extension PortalEffect {
    /// Release to visual landing (the spec's L), seconds: the card flies on
    /// the travel curve this long and the impact plays when it arrives. Paper
    /// plane keeps its loop-de-loop, so it is longer than the spec's 0.38.
    var flight: Double {
        switch self {
        case .portal: 0.28
        case .liquid: 0.32
        case .wormhole: 0.30
        case .beam: 0.32
        case .plane: 0.56
        }
    }
}

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The colours of one effect, from the user's tint (`PortalTones`): a
/// nearly white core, a saturated glow and a second tone a little round the
/// hue wheel. Rainbow takes the clock's hue for this crossing and spreads the
/// whole wheel across the impact.
struct PortalPalette: Hashable {
    let core: NSColor, glow: NSColor, accent: NSColor
    let rainbow: Bool
    /// Tells cached bitmaps apart.
    let key: String

    init(tint: PortalTint, at date: Date = Date()) {
        let base = tint.base(at: date)
        let tones = PortalTones(base, rainbow: tint == .rainbow)
        func ns(_ c: PortalRGB) -> NSColor { NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1) }
        core = ns(tones.core)
        glow = ns(tones.glow)
        accent = ns(tones.second)
        rainbow = tint == .rainbow
        // Rainbow's impact bitmap is the whole wheel whatever the crossing's hue: one bitmap, always warm.
        key = rainbow ? "rainbow" : tones.glow.hex + tones.second.hex
    }

    /// The effect's default colour, as it was before colours could change.
    static func of(_ effect: PortalEffect) -> PortalPalette { PortalPalette(tint: .defaultTint(for: effect)) }

    /// Left to right across the impact: the second tone where the card lands,
    /// the glow toward the edge the light comes from. Rainbow: the whole wheel.
    func gradient(saturated: Bool) -> [CGColor] {
        let lift: CGFloat = saturated ? 0 : 0.22
        let colors: [NSColor] = rainbow
            ? (0..<7).map { i in NSColor(hue: CGFloat(Double(i) / 6).truncatingRemainder(dividingBy: 1) * 0.92, saturation: 1, brightness: 1, alpha: 1) }
            : [accent, accent, glow, glow]
        return colors.map { ($0.usingColorSpace(.sRGB) ?? $0).blended(withFraction: lift, of: .white)?.cgColor ?? $0.cgColor }
    }

    var gradientStops: [CGFloat] { rainbow ? (0..<7).map { CGFloat($0) / 6 } : [0, 0.25, 0.7, 1] }
}

/// The whole screen behind the card. `seam` is where the card comes through
/// the right edge, `landing` the middle of where it comes to rest, both in
/// this view's coordinates. Sizes are the spec's, drawn for a 1280 × 800
/// screen and scaled to this one (`k`).
final class StageView: NSView {
    /// Tune here.
    enum Look {
        /// The darkest the vignette gets, at full drag.
        static let vignette: CGFloat = 0.35
        /// From the impact until the stage is clear, seconds.
        static let impactSeconds: Double = 0.55
        static let card = CGSize(width: 240, height: 268)
        /// Room round the card for its halo.
        static let glowPad: CGFloat = 72
        /// The card's halo at no drag and at full drag (the impact flashes it to 1).
        static let glowHeld: (CGFloat, CGFloat) = (0.5, 0.95)
        /// The building light at full drag, and in flight.
        static let buildHeld: CGFloat = 0.85
        static let buildFlight: CGFloat = 0.92
        /// Rainbow: how far the wheel turns with the drag; the impact sweeps the rest.
        static let rainbowDragTurn: CGFloat = 0.3
    }

    let effect: PortalEffect
    private let seam: CGPoint
    private let landing: CGPoint
    private let palette: PortalPalette
    private let k: CGFloat
    private let root = CALayer()
    /// What the drag lights: vignette, wash and the effect's edge.
    private let ambient = CALayer()
    /// The send and the impact.
    private let fx = CALayer()
    private var impactTexture: LightBitmap?
    private var impactFrame = CGRect.zero
    private var lightLayout: PortalLightTexture.Layout!
    private var hero: LightLayer?
    /// The impact's light while the finger holds the card: the same picture,
    /// pinned to the seam and stretched to the card, so the effect's shape
    /// builds with p and becomes the impact at the landing.
    private var build: LightLayer!
    /// The halo round the card and the light on its edge, behind it.
    private let cardGlow = CALayer()
    private let rim = CAShapeLayer()
    private var intensity: CGFloat = 0
    private var card: CGPoint
    /// When the flick happened; the harness sets `stillClock` instead.
    private var sentAt: CFTimeInterval?
    private var stillClock: CGFloat?
    /// Seconds since the release, nil while the finger still holds the card.
    private var since: CGFloat? { stillClock ?? sentAt.map { CGFloat(CACurrentMediaTime() - $0) } }
    /// Portal's slit, Liquid's membrane, Beam's edge.
    private var halo: CALayer?
    /// Portal's light ribbon and Liquid's neck, from the seam to the card.
    private var ribbon: CALayer?
    /// Wormhole: three rims in perspective around the seam.
    private var tunnel: CALayer?
    private var rims: [CALayer] = []
    private static let rimTilt: [CGFloat] = [45, 30, 15]
    /// Beam: nine lines from the card's slices to the seam.
    private var lines: CAReplicatorLayer?
    private var lineBar: CAGradientLayer?
    /// Paper plane: breeze at the seam and two contrails.
    private var breeze: CALayer?
    private var contrails: [CAShapeLayer] = []

    private var w: CGFloat { bounds.width }
    private var h: CGFloat { bounds.height }

    init(frame: NSRect, effect: PortalEffect, palette: PortalPalette, seam: CGPoint, landing: CGPoint, backingScale: CGFloat = 2) {
        self.effect = effect
        self.seam = seam
        self.landing = landing
        card = seam
        self.palette = palette
        // The spec's numbers are for 1280 × 800; its effects stay under 78% of the height.
        k = Self.scale(for: frame.size)
        super.init(frame: frame)
        wantsLayer = true
        root.frame = bounds
        layer?.addSublayer(root)
        ambient.frame = bounds
        fx.frame = bounds
        root.addSublayer(ambient)
        buildCommon()
        switch effect {
        case .portal: buildPortal()
        case .liquid: buildLiquid()
        case .wormhole: buildWormhole()
        case .beam: buildBeam()
        case .plane: buildPlane()
        }
        lightLayout = PortalLightTexture.layout(effect: effect, screen: frame.size, landing: landing, k: k)
        impactFrame = lightLayout.frame
        build = LightLayer(size: impactFrame.size)
        build.layer.anchorPoint = lightAnchor
        build.layer.opacity = 0
        root.insertSublayer(build.layer, above: ambient)
        buildCardGlow()
        root.addSublayer(fx)
        still { ambient.opacity = 0 }
        arrange()
        PortalLightTexture.prepare(effect: effect, palette: palette, layout: lightLayout, scale: backingScale) { [weak self] image in
            self?.light(image)
        }
    }

    /// The landing spot inside the light's bitmap: both light layers pivot there.
    private var lightAnchor: CGPoint {
        CGPoint(x: (landing.x - impactFrame.minX) / impactFrame.width, y: (landing.y - impactFrame.minY) / impactFrame.height)
    }

    private func light(_ image: LightBitmap?) {
        impactTexture = image
        build.show(image)
        hero?.show(image)
        still { arrange() }
    }

    /// The harness paints the light at once instead of waiting for the painter.
    func paintNow() {
        if impactTexture == nil {
            light(PortalLightTexture.image(effect: effect, palette: palette, layout: lightLayout, scale: 2))
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The spec's numbers are for 1280 × 800; its effects stay under 78% of the height.
    static func scale(for size: CGSize) -> CGFloat {
        min(1.3, max(0.75, min(size.width / 1280, size.height / 800)))
    }

    private func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Building

    private func gradient(_ type: CAGradientLayerType = .axial, _ colors: [NSColor], _ stops: [NSNumber]? = nil) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = type
        g.colors = colors.map(\.cgColor)
        g.locations = stops
        return g
    }

    /// A radial glow centred on `center` with radii `rx`, `ry`.
    private func glow(_ colors: [NSColor], _ stops: [NSNumber], center: CGPoint, rx: CGFloat, ry: CGFloat) -> CAGradientLayer {
        let g = gradient(.radial, colors, stops)
        g.bounds = CGRect(x: 0, y: 0, width: rx * 2, height: ry * 2)
        g.position = center
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        return g
    }

    private func buildCommon() {
        // A soft vignette around the edge the card comes through, never darker than 35%.
        let black = NSColor.black
        ambient.addSublayer(glow([black.withAlphaComponent(0), black.withAlphaComponent(Look.vignette),
                                  black.withAlphaComponent(Look.vignette * 0.5), black.withAlphaComponent(0)],
                                 [0, 0.28, 0.62, 1], center: seam, rx: w * 0.75, ry: h * 1.05))
        // A narrow wash of the effect's light on the edge: a doorway, not a screen wash.
        let wash = gradient(.axial, [palette.glow.withAlphaComponent(0.5), palette.glow.withAlphaComponent(0.14),
                                     palette.glow.withAlphaComponent(0.04), palette.glow.withAlphaComponent(0)], [0, 0.3, 0.65, 1])
        wash.frame = CGRect(x: w - 240 * k, y: 0, width: 240 * k, height: h)
        wash.startPoint = CGPoint(x: 1, y: 0.5)
        wash.endPoint = CGPoint(x: 0, y: 0.5)
        ambient.addSublayer(wash)
    }

    private func buildCardGlow() {
        let size = Look.card, pad = Look.glowPad
        cardGlow.bounds = CGRect(x: 0, y: 0, width: size.width + 2 * pad, height: size.height + 2 * pad)
        cardGlow.contents = Sprite.cardHalo(palette.glow, card: size, radius: 18, pad: pad)
        cardGlow.opacity = 0
        rim.frame = cardGlow.bounds
        rim.fillColor = nil
        rim.strokeColor = palette.core.cgColor
        rim.lineWidth = 2.4
        rim.path = rimPath(radius: 18)
        cardGlow.addSublayer(rim)
        root.addSublayer(cardGlow)
    }

    /// Just outside the card's edge, so the light shows round it.
    private func rimPath(radius: CGFloat) -> CGPath {
        let r = CGRect(x: Look.glowPad, y: Look.glowPad, width: Look.card.width, height: Look.card.height).insetBy(dx: -1.2, dy: -1.2)
        return CGPath(roundedRect: r, cornerWidth: radius + 1.2, cornerHeight: radius + 1.2, transform: nil)
    }

    /// A band of light from the seam toward the card, wide at the card and
    /// thin at the seam: drawn 1000 long once and stretched by `layout`.
    private func taper(_ colors: [NSColor], height: CGFloat, tip: CGFloat) -> CALayer {
        let band = gradient(.axial, colors)
        band.bounds = CGRect(x: 0, y: 0, width: 1000, height: height)
        band.anchorPoint = CGPoint(x: 1, y: 0.5)
        band.position = seam
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let shape = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: 1000, y: height / 2 - tip / 2), control: CGPoint(x: 400, y: height * 0.32))
        path.addLine(to: CGPoint(x: 1000, y: height / 2 + tip / 2))
        path.addQuadCurve(to: CGPoint(x: 0, y: height), control: CGPoint(x: 400, y: height * 0.68))
        path.closeSubpath()
        shape.path = path
        band.mask = shape
        band.opacity = 0
        return band
    }

    private func buildPortal() {
        let p = palette
        // The doorway: a tall slit of light on the edge, 220 → 600 tall, 40 → 170 wide with the drag.
        let slit = glow([NSColor.white, p.core.withAlphaComponent(0.95), p.glow.withAlphaComponent(0.8),
                         p.accent.withAlphaComponent(0.28), p.accent.withAlphaComponent(0)], [0, 0.08, 0.3, 0.65, 1],
                        center: seam, rx: 170 * k, ry: 300 * k)
        ambient.addSublayer(slit)
        halo = slit
        // A bright core on the edge itself, 600 tall at full drag.
        let core = gradient(.axial, [p.core.withAlphaComponent(0), p.core, NSColor.white, p.core, p.core.withAlphaComponent(0)], [0, 0.2, 0.5, 0.8, 1])
        slit.addSublayer(core)
        // Centred on the edge: 4 pt of it shows, and the slit's x scale never thins it below that.
        core.frame = CGRect(x: slit.bounds.midX - 8, y: 0, width: 16, height: slit.bounds.height)
        let band = taper([p.glow.withAlphaComponent(0.9), p.accent.withAlphaComponent(0.7), p.core], height: 200 * k, tip: 10)
        root.addSublayer(band)
        ribbon = band
    }

    private func buildLiquid() {
        let p = palette
        // A curved membrane bulging from the edge, 30 → 160 wide, 180 → 500 tall.
        let membrane = glow([p.accent.withAlphaComponent(0.85), p.core.withAlphaComponent(0.75), p.glow.withAlphaComponent(0.45),
                             p.glow.withAlphaComponent(0)], [0, 0.25, 0.6, 1], center: seam, rx: 160 * k, ry: 250 * k)
        ambient.addSublayer(membrane)
        halo = membrane
        // The neck that stretches between the edge and the file, then snaps.
        let neck = taper([p.core.withAlphaComponent(0.9), p.glow.withAlphaComponent(0.85), p.glow], height: Look.card.height * 0.9, tip: 70 * k)
        root.addSublayer(neck)
        ribbon = neck
    }

    private func buildWormhole() {
        let p = palette
        let group = CALayer()
        group.position = seam
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        group.sublayerTransform = perspective
        let deep = srgb(0x0B0B0F)
        group.addSublayer(glow([p.glow.withAlphaComponent(0.75), p.accent.withAlphaComponent(0.3), p.accent.withAlphaComponent(0)],
                               [0, 0.5, 1], center: .zero, rx: 340 * k, ry: 340 * k))
        // Three rims, 560 / 390 / 250 across, tilted 45° / 30° / 15°: a tunnel in perspective.
        for (i, d) in ([560, 390, 250] as [CGFloat]).enumerated() {
            let rim = Sprite.layer(.rim, i == 0 ? p.core : p.glow, size: d * k, at: .zero)
            rim.opacity = 0.7
            // A soft halo on the same layer's plane: one texture each, no filter.
            let halo = Sprite.layer(.ring, i == 0 ? p.glow : p.accent, size: d * k * 1.1, at: CGPoint(x: d * k / 2, y: d * k / 2))
            halo.opacity = 0.8
            rim.addSublayer(halo)
            group.addSublayer(rim)
            rims.append(rim)
        }
        // The dark middle: depth without a volume.
        group.addSublayer(glow([deep.withAlphaComponent(0.95), deep.withAlphaComponent(0.8), deep.withAlphaComponent(0)],
                               [0, 0.5, 1], center: .zero, rx: 120 * k, ry: 120 * k))
        group.opacity = 0
        root.addSublayer(group)
        tunnel = group
    }

    private func rimTransform(_ i: Int, tilt: CGFloat, spin: CGFloat, scale: CGFloat = 1) -> CATransform3D {
        CATransform3DScale(CATransform3DConcat(turnZ(spin), turnY(tilt)), scale, scale, scale)
    }

    private func buildBeam() {
        let p = palette
        halo = glow([NSColor.white, p.core.withAlphaComponent(0.95), p.glow.withAlphaComponent(0.7), p.accent.withAlphaComponent(0.2),
                     p.accent.withAlphaComponent(0)], [0, 0.08, 0.3, 0.65, 1], center: seam, rx: 90 * k, ry: 280 * k)
        ambient.addSublayer(halo!)
        // Nine low ribbons from the card's slices back to the seam.
        let rep = CAReplicatorLayer()
        rep.anchorPoint = CGPoint(x: 1, y: 0.5)
        rep.instanceCount = CardLook.Look.beamSlices
        let step = Look.card.height / CGFloat(rep.instanceCount)
        rep.instanceTransform = CATransform3DMakeTranslation(0, step, 0)
        let bar = gradient(.axial, [p.core, p.glow.withAlphaComponent(0.55), p.glow.withAlphaComponent(0.15)])
        bar.startPoint = CGPoint(x: 0, y: 0.5)
        bar.endPoint = CGPoint(x: 1, y: 0.5)
        rep.addSublayer(bar)
        rep.opacity = 0
        root.addSublayer(rep)
        lines = rep
        lineBar = bar
    }

    private func buildPlane() {
        let p = palette
        // A breeze at the seam that grows with the drag: three still arcs, nothing loops.
        let wind = CALayer()
        wind.position = seam
        for (dy, length, alpha) in [(46, 120, 0.55), (-8, 170, 0.7), (-58, 100, 0.45)] as [(CGFloat, CGFloat, CGFloat)] {
            let arc = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -6, y: dy * k))
            path.addQuadCurve(to: CGPoint(x: -length * k, y: (dy - 12) * k), control: CGPoint(x: -length * k * 0.5, y: (dy + 14) * k))
            arc.path = path
            arc.fillColor = nil
            arc.strokeColor = p.core.withAlphaComponent(alpha).cgColor
            arc.lineWidth = 1.6
            arc.lineCap = .round
            wind.addSublayer(arc)
        }
        ambient.addSublayer(wind)
        breeze = wind
        for (color, width) in [(p.glow.withAlphaComponent(0.3), 7.0), (p.accent, 1.8), (p.glow.withAlphaComponent(0.3), 7.0), (p.accent, 1.8)] as [(NSColor, CGFloat)] {
            let line = CAShapeLayer()
            line.fillColor = nil
            line.strokeColor = color.cgColor
            line.lineWidth = width
            line.lineCap = .round
            line.opacity = 0
            root.insertSublayer(line, below: fx)
            contrails.append(line)
        }
    }

    // MARK: Following the drag

    /// 0 dark, 1 full light; follows the drag (the spec's p).
    func setIntensity(_ value: CGFloat) {
        intensity = min(1, max(0, value))
        still {
            ambient.opacity = Float(pow(intensity, 0.7))
            arrange()
        }
    }

    /// Where the middle of the card is now: the ribbon, the neck, the lines and the contrails reach it.
    func follow(card center: CGPoint) {
        card = center
        still { arrange() }
    }

    /// While the finger holds the card everything follows p; after the
    /// release the timed motions own the transforms and only what reaches the
    /// moving card (the ribbon, the neck, the lines, the contrails) is set here.
    private func arrange() {
        let p = intensity, L = CGFloat(effect.flight), held = since == nil
        switch effect {
        case .portal:
            if held { halo?.transform = CATransform3DMakeScale((40 + 130 * p) / 170, (220 + 380 * p) / 600, 1) }
            stretch(ribbon)
            ribbon?.opacity = Float(since.map { 0.22 * (1 - seg($0, 0, L, .retire)) } ?? 0.12 * p)
        case .liquid:
            if held { halo?.transform = CATransform3DMakeScale((30 + 130 * p) / 160, (180 + 320 * p) / 500, 1) }
            // The neck thins to a hairline over the last 120 ms of the flight and snaps at the landing.
            stretch(ribbon, thick: 0.6 * lerp(1, 0.02 / 0.6, since.map { seg($0, L - 0.12, L, .collapse) } ?? 0))
            ribbon?.opacity = Float(since.map { $0 < L ? 0.75 : 0 } ?? 0.75 * seg(p, 0.5, 1))
        case .wormhole:
            if !held { break }
            tunnel?.opacity = Float(min(1, 1.6 * p))
            tunnel?.transform = CATransform3DMakeScale(0.4 + 0.6 * p, 0.4 + 0.6 * p, 1)
            for (i, rim) in rims.enumerated() { rim.transform = rimTransform(i, tilt: Self.rimTilt[i], spin: 0) }
        case .beam:
            if held {
                halo?.transform = CATransform3DMakeScale(1, 0.5 + 0.5 * p, 1)
                lines?.opacity = Float(0.25 * p)
            }
            placeLines()
        case .plane:
            if held { breeze?.transform = CATransform3DMakeScale(0.4 + 0.6 * p, 0.4 + 0.6 * p, 1) }
            placeContrails()
        }
        placeBuild()
        placeGlow()
    }

    /// The impact's own picture, pinned to the seam and stretched to the
    /// card: its landing spot sits on the card, its right edge on the seam.
    /// Squeezed toward the edge at the start of the drag (Wormhole's rims
    /// edge-on, Portal's lens a sliver, Liquid's neck short), it opens to the
    /// impact's exact pose as the card reaches its spot.
    private func placeBuild() {
        guard let build else { return }
        let span = max(1, seam.x - landing.x)
        let sx = min(1, max(0.02, (seam.x - card.x) / span))
        let sy = lerp(0.62, 1, sx)
        build.layer.position = card
        build.layer.transform = CATransform3DMakeScale(sx, sy, 1)
        let held = Look.buildHeld * pow(seg(intensity, 0.02, 0.7), 0.7)
        if let since {
            build.layer.opacity = Float(lerp(held, Look.buildFlight,
                                             seg(since, 0, CGFloat(effect.flight), .travel)))
        } else {
            build.layer.opacity = Float(held)
            build.setTurn(Look.rainbowDragTurn * intensity)
        }
    }

    private func glowShape(_ p: CGFloat) -> CATransform3D {
        let (sx, sy, turn) = CardLook.heldShape(effect, p)
        return CATransform3DScale(turnZ(turn), sx, sy, 1)
    }

    /// The halo and the rim follow the card and its held shape (Wormhole's
    /// turn, Liquid's squash), then fly with it.
    private func placeGlow() {
        let p = intensity, L = CGFloat(effect.flight)
        cardGlow.position = card
        let (g0, g1) = Look.glowHeld
        let heldOpacity = lerp(g0, g1, p)
        // Beam's slices and the plane's halves leave the card's outline: its rim waits for them.
        let rimHeld: CGFloat = effect == .beam ? seg(p, 0.55, 1) : effect == .plane ? 1 - seg(p, 0.25, 0.6) : 1
        let liquid = effect == .liquid ? seg(p, 0.35, 0.8) : 0
        guard let s = since else {
            cardGlow.opacity = Float(heldOpacity)
            cardGlow.transform = glowShape(p)
            rim.opacity = Float(rimHeld)
            if effect == .liquid { rim.path = rimPath(radius: lerp(18, CardLook.Look.liquidRadius, liquid)) }
            return
        }
        let u = seg(s, 0, L, .travel)
        let (sx0, sy0, turn0) = CardLook.heldShape(effect, p)
        let (sx1, sy1): (CGFloat, CGFloat) = effect == .liquid ? (1.08, 0.94) : (1, 1)
        cardGlow.transform = CATransform3DScale(turnZ(lerp(turn0, 0, u)), lerp(sx0, sx1, u), lerp(sy0, sy1, u), 1)
        switch effect {
        case .plane:
            // The card is a plane in the loop: its glow waits for the halves to open.
            let back = seg(s, L - 0.1, L)
            cardGlow.opacity = Float(lerp(heldOpacity * (1 - seg(s, 0, 0.09)), 1, back))
            rim.opacity = Float(back)
        case .liquid:
            cardGlow.opacity = Float(lerp(heldOpacity, 1, u))
            rim.path = rimPath(radius: lerp(lerp(18, CardLook.Look.liquidRadius, liquid), CardLook.Look.liquidRadius, seg(s, 0, 0.1)))
        default:
            cardGlow.opacity = Float(lerp(heldOpacity, 1, u))
            rim.opacity = Float(lerp(rimHeld, 1, seg(s, 0, L * 0.8)))
        }
    }

    /// From the seam to the card's trailing edge.
    private func stretch(_ band: CALayer?, thick: CGFloat = 1) {
        guard let band else { return }
        let target = CGPoint(x: card.x + Look.card.width * 0.3, y: card.y)
        let dx = target.x - seam.x, dy = target.y - seam.y
        let length = max(0, -dx)
        band.isHidden = length < 4
        let angle = atan2(dy, dx) - .pi
        band.transform = CATransform3DConcat(CATransform3DMakeScale(max(0.001, length / 1000), thick, 1),
                                             CATransform3DMakeRotation(angle, 0, 0, 1))
    }

    private func placeLines() {
        guard let lines, let lineBar else { return }
        let step = Look.card.height / CGFloat(lines.instanceCount)
        let left = card.x + Look.card.width / 2 - 4, width = max(0, w - left)
        lines.bounds = CGRect(x: 0, y: 0, width: width, height: Look.card.height)
        lines.position = CGPoint(x: w, y: card.y)
        lineBar.frame = CGRect(x: 0, y: step / 2 - 0.75, width: width, height: 1.5)
    }

    private func placeContrails() {
        let tail = CGPoint(x: card.x + 50, y: card.y + 6)
        for (i, line) in contrails.enumerated() {
            let side: CGFloat = i < 2 ? 1 : -1
            let path = CGMutablePath()
            path.move(to: CGPoint(x: w + 4, y: seam.y + side * 70 * k))
            path.addQuadCurve(to: CGPoint(x: tail.x, y: tail.y + side * 10),
                              control: CGPoint(x: tail.x + (w - tail.x) * 0.35, y: tail.y + side * 12 * k))
            line.path = tail.x < w ? path : nil
        }
    }

    // MARK: Send, impact, cancel

    /// The flick, `t` = 0 at the release: the edge light holds while the card
    /// flies (`effect.flight`) and fades 0.2 s after it lands.
    func send(still t: Double? = nil) {
        let L = CGFloat(effect.flight), a0 = CGFloat(pow(max(intensity, 0.5), 0.7))
        if let t { stillClock = CGFloat(t) } else { sentAt = CACurrentMediaTime() }
        timeline(ambient, Double(L) + 0.2, still: t, opacity: { s in
            s < 0.1 ? lerp(a0, 1, seg(s, 0, 0.1, .travel)) : 1 - seg(s, L, L + 0.2, .retire)
        })
        switch effect {
        case .portal:
            if let halo {
                let x0 = (40 + 130 * intensity) / 170, y0 = (220 + 380 * intensity) / 600
                timeline(halo, 0.1, still: t, transform: { s in CATransform3DMakeScale(x0 * lerp(1, 1.35, seg(s, 0, 0.1, .travel)), y0, 1) })
            }
        case .liquid:
            if let halo {
                let x0 = (30 + 130 * intensity) / 160, y0 = (180 + 320 * intensity) / 500
                timeline(halo, Double(L), still: t, transform: { s in CATransform3DMakeScale(x0 * lerp(1, 0.2, seg(s, 0, L, .collapse)), y0, 1) })
            }
        case .wormhole:
            if let tunnel {
                let o = CGFloat(tunnel.opacity), s0 = 0.4 + 0.6 * intensity
                timeline(tunnel, 0.12, still: t, opacity: { s in lerp(o, 1, seg(s, 0, 0.1)) },
                         transform: { s in let v = lerp(s0, 1, seg(s, 0, 0.12, .travel)); return CATransform3DMakeScale(v, v, 1) })
            }
            for (i, rim) in rims.enumerated() {
                let tilt = Self.rimTilt[i]
                timeline(rim, Double(L), still: t, transform: { s in self.rimTransform(i, tilt: tilt, spin: 35 * seg(s, 0, L, .travel)) })
            }
        case .beam:
            if let lines { timeline(lines, 0.1, still: t, opacity: { s in lerp(0.25 * self.intensity, 0.4, seg(s, 0, 0.1)) }) }
        case .plane:
            if let breeze {
                let s0 = 0.4 + 0.6 * intensity
                timeline(breeze, 0.3, still: t, transform: { s in
                    CATransform3DScale(CATransform3DMakeTranslation(-90 * seg(s, 0, 0.3, .travel), 0, 0), s0, s0, 1)
                })
            }
            for line in contrails {
                timeline(line, 0.26, still: t, opacity: { s in seg(s, 0.09, 0.14) })
                reveal(line, from: 0.09, to: 0.26, still: t)
            }
        }
        still { arrange() }
    }

    /// Draws a contrail from the seam over `from...to` seconds.
    private func reveal(_ line: CAShapeLayer, from: Double, to: Double, still t: Double?) {
        if let t {
            line.strokeEnd = seg(CGFloat(t), CGFloat(from), CGFloat(to), .travel)
            return
        }
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.beginTime = line.convertTime(CACurrentMediaTime(), from: nil) + from
        a.duration = to - from
        a.fillMode = .backwards
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        line.strokeEnd = 1
        line.add(a, forKey: "reveal")
    }

    /// The card is at its spot (the spec's L): each effect's own signature.
    /// `t` is seconds since L, for the harness.
    func impact(still t: Double? = nil) {
        // The hero silhouette is painted before playback, including its blue bloom.
        // Holding the peak for 70 ms makes it readable in motion as well as in a still.
        if t != nil { paintNow() }
        let light = LightLayer(size: impactFrame.size)
        let hero = light.layer
        hero.anchorPoint = lightAnchor
        hero.position = landing
        light.show(impactTexture)
        self.hero = light
        fx.addSublayer(hero)
        // Rainbow: the hue sweeps across the light while it plays, from where the drag left it.
        light.setTurn(Look.rainbowDragTurn * intensity)
        light.sweep(from: Look.rainbowDragTurn * intensity, seconds: 0.52, still: t)
        timeline(hero, 0.52, still: t, opacity: { s in
            s < 0.025 ? seg(s, 0, 0.025, .travel) : 1 - seg(s, 0.095, 0.52, .retire)
        }, transform: { s in
            if self.effect == .beam || self.effect == .plane { return CATransform3DIdentity }
            if self.effect == .wormhole {
                var pose = CATransform3DIdentity
                pose.m34 = -1 / 1400
                return CATransform3DRotate(pose, 1.4 * seg(s, 0.10, 0.38, .collapse), 0, 1, 0)
            }
            let v = lerp(0.82, 1, seg(s, 0, 0.035, .travel)) + 0.08 * seg(s, 0.095, 0.52, .travel)
            return CATransform3DMakeScale(v, v, 1)
        })
        // Retire the drag geometry so it cannot obscure the brighter impact silhouette.
        for layer in [tunnel, ribbon, lines].compactMap({ $0 }) {
            timeline(layer, 0.06, still: t, opacity: { s in 1 - seg(s, 0, 0.06) })
        }
        let b = CGFloat(build.layer.opacity)
        timeline(build.layer, 0.1, still: t, opacity: { s in b * (1 - seg(s, 0, 0.1, .retire)) })
        // The card's halo flashes with the pop (CardLook.land's curve) and goes out with the light.
        let pop = effect == .beam ? keys([(0, 1), (0.07, 1.08), (0.3, 1)]) : keys([(0, 1), (0.07, CardLook.Look.pop), (0.2, 0.985), (0.3, 1.006), (0.45, 1)])
        let shape = cardGlow.transform
        timeline(cardGlow, 0.52, still: t, opacity: { s in 1 - seg(s, 0.12, 0.52, .retire) },
                 transform: { s in CATransform3DScale(shape, pop(s), pop(s), 1) })
    }

    /// A cancel: the light goes out in 140 ms. Returns seconds.
    func fadeOut() -> Double {
        var m = Motion(0.14, ease: .retire)
        for layer in [ambient, tunnel, ribbon, lines, build?.layer, cardGlow].compactMap({ $0 }) + contrails {
            let start = CGFloat((layer.presentation() ?? layer).opacity)
            m.opacity = { u in start * (1 - u) }
            m.run(on: layer)
        }
        return 0.14
    }

    func stop() {
        func clear(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(clear)
        }
        clear(root)
    }
}
