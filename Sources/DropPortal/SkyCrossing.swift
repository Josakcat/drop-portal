//
//  SkyCrossing.swift
//  DropPortal
//
//  Stardust and Lightning on the Mac, hung on the stage and the card by the
//  same kind of one-line hooks as MetalCrossing (StageView.sky, CardLook.sky).
//
//  SkyStage, over the stage and under the card:
//  - Stardust: while held, filler stardust streams in from beyond the right
//    edge and turns in a soft vortex there (its clock is the drag's p, so it
//    moves only when the finger does). After the release it holds 50 ms, then
//    one grain per point of the card launches, right side first, and flies
//    450–550 ms on emphasized-decelerate to its spot, its curl offset decaying
//    to 0, growing from a dot to a square over the last 20 %; 10 % glitter.
//  - Lightning: a faint lavender glow on the edge while held (opacity only).
//    After the release the leader draws from the edge to the landing spot in
//    four steps, the return stroke is one 25 ms beat at up to 2.5× white
//    (EDR, never past the headroom) with an ice-blue halo and a five-level
//    bloom, then one weaker re-strike with a new seed and an afterglow
//    (τ 100 ms); gone by 0.45 s. Every flash asks `SkyBoard`'s limiter first:
//    at most three a second across all strikes (WCAG 2.3.1).
//  SkyCard, inside the card's host (so it follows the card's pose): the
//  Stardust glint (one EDR band across the card at the landing) and the
//  Lightning exposure lift, both inside the card's rounded rect only.
//
//  No Metal (or Reduce motion, Low Power Mode, the settings process): the
//  Core Animation fallback. Stardust's card flies as it is with a soft glow
//  on the edge; Lightning's bolt is three stroked paths under the same cap.
//

import AppKit
import DropPortalCore
import Metal
import QuartzCore
import simd

/// What the stage and the card of one crossing share: the card's picture
/// (the grains' colours) and the strike's flash plan, plus the process-wide
/// flash cap.
@MainActor
enum SkyBoard {
    static var snapshot: MTLTextureBox?
    private static var limiter = FlashLimiter()
    private static var plan: (at: CFTimeInterval, allowed: [Bool])?

    /// The flashes this strike may draw (the stroke, then each re-strike).
    /// The card and the stage ask at the same release and get the same plan.
    static func strike(at now: CFTimeInterval, still: Bool) -> [Bool] {
        if still { return Array(repeating: true, count: LightningStrike.flashesPerStrike) }
        if let plan, abs(plan.at - now) < 0.1 { return plan.allowed }
        let allowed = limiter.plan(strikeAt: now)
        plan = (now, allowed)
        if allowed.contains(false) { PortalLog.write("sky: flash cap, strike drawn with \(allowed.filter { $0 }.count) of \(allowed.count) flashes") }
        return allowed
    }

    static func reset() {
        snapshot = nil
        plan = nil
    }
}

extension PortalEffect {
    /// Release to the Mac card's landing for the sky effects.
    var skyFlight: Double { self == .stardust ? Stardust.macFlight : LightningStrike.macFlight }
}

extension PortalPalette {
    /// Lightning's tones: every colour of the palette through `SkyColor.lightningSafe`.
    var lightningSafe: PortalPalette { PortalPalette(safe: self) }

    private init(safe p: PortalPalette) {
        core = ns(SkyColor.lightningSafe(rgb(p.core)).mixed(with: .white, 0.6))
        glow = ns(SkyColor.lightningSafe(rgb(p.glow)))
        accent = ns(SkyColor.lightningSafe(rgb(p.accent)).mixed(with: PortalRGB(red: 0.82, green: 0.76, blue: 1), 0.4))
        rainbow = false
        key = "lightning-" + p.key
    }
}

private func linear(_ c: NSColor) -> SIMD3<Float> {
    let s = c.usingColorSpace(.sRGB) ?? c
    func l(_ v: CGFloat) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
    return SIMD3(l(s.redComponent), l(s.greenComponent), l(s.blueComponent))
}

private func rgb(_ c: NSColor) -> PortalRGB {
    let s = c.usingColorSpace(.sRGB) ?? c
    return PortalRGB(red: Double(s.redComponent), green: Double(s.greenComponent), blue: Double(s.blueComponent))
}

private func ns(_ c: PortalRGB, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: alpha)
}

// MARK: - Stage

@MainActor
final class SkyStage: FXClient {
    let layer = CALayer()
    let effect: PortalEffect
    private let palette: PortalPalette
    private var seam: CGPoint
    private let landing: CGPoint
    private let k: CGFloat
    private let card = StageView.Look.card
    private var p: CGFloat = 0
    private var sentAt: CFTimeInterval?
    private var stillSend: CGFloat?
    private var vortexAtRelease: CGFloat = 0
    private var canvas: SkyCanvas?
    private var dirty = true
    private var done = false
    private var allowed: [Bool] = []
    private let seed: UInt32
    // Lightning on the GPU: one vertex buffer per bolt, the bolt target and five bloom levels.
    private var bolts: [(buffer: MTLBuffer, count: Int)] = []
    private var boltTarget: MTLTexture?
    private var mips: [MTLTexture] = []
    // The Core Animation fallback.
    private var glow: CAGradientLayer?
    private var paths: [[CAShapeLayer]] = []

    /// Grains for the Mac card: one per point, fewer when the budget says so.
    static let grainBudget = 80_000, fillerCount = 16_000

    /// Whether the GPU draws the crossing (the card is grains until the landing).
    var onGPU: Bool { canvas != nil }

    init?(frame: CGRect, effect: PortalEffect, palette: PortalPalette, seam: CGPoint, landing: CGPoint, k: CGFloat, scale: CGFloat) {
        guard effect.isSky else { return nil }
        self.effect = effect
        self.palette = palette
        self.seam = seam
        self.landing = landing
        self.k = k
        seed = UInt32.random(in: 1...UInt32.max)
        layer.frame = frame
        layer.actions = ["opacity": NSNull()]
        if let engine = SkyEngine.forCrossing() {
            let c = SkyCanvas(engine: engine, frame: CGRect(origin: .zero, size: frame.size), scale: scale, maxPixels: 1_000_000)
            canvas = c
            layer.addSublayer(c.layer)
            if effect == .lightning {
                let (w, h) = c.pixelSize
                boltTarget = engine.target(width: w, height: h)
                var (mw, mh) = (w, h)
                for _ in 0..<5 {
                    mw = max(1, mw / 2); mh = max(1, mh / 2)
                    if let t = engine.target(width: mw, height: mh) { mips.append(t) }
                }
            }
        }
        buildFallback()
    }

    func setIntensity(_ value: CGFloat) {
        p = min(1, max(0, value))
        if let glow { still { glow.opacity = Float((effect == .lightning ? 0.5 : 0.8) * pow(p, 0.8)) } }
        changed()
    }

    func follow(card center: CGPoint) {}

    func moveSeam(toY y: CGFloat) {
        seam.y = y
        if let glow { still { glow.position.y = y } }
        changed()
    }

    // MARK: Send

    func send(still t: Double?, flight: Double) {
        let now = CACurrentMediaTime()
        if let t { stillSend = CGFloat(t) } else { sentAt = now }
        vortexAtRelease = vortex(held: p)
        if effect == .lightning {
            allowed = SkyBoard.strike(at: now, still: t != nil)
            makeBolts()
        }
        if canvas == nil { playFallback(still: t) }
        changed()
    }

    func impact(still t: Double?) { changed() }

    func fadeOut() -> Double {
        var m = Motion(0.14, ease: .retire)
        let start = CGFloat((layer.presentation() ?? layer).opacity)
        m.opacity = { u in start * (1 - u) }
        m.run(on: layer)
        return 0.14
    }

    func stop() {
        done = true
        FXDriver.shared.remove(self)
        canvas?.clear()
        layer.removeAllAnimations()
        layer.sublayers?.forEach { $0.removeAllAnimations() }
        bolts = []
        mips = []
        boltTarget = nil
    }

    private func changed() {
        dirty = true
        guard canvas != nil else { return }
        if MetalFX.mode == .stills { _ = tick(now: CACurrentMediaTime()) } else { FXDriver.shared.wake(self) }
    }

    // MARK: Frames

    private var lifetime: CGFloat {
        effect == .stardust ? CGFloat(Stardust.macFlight) + 0.12 : CGFloat(LightningStrike.end) + 0.02
    }

    /// The vortex's clock while held: the drag's p, so nothing moves on its own.
    private func vortex(held p: CGFloat) -> CGFloat { 1.4 * p }

    func tick(now: CFTimeInterval) -> Bool {
        guard !done, let canvas else { return false }
        let ts = stillSend ?? sentAt.map { CGFloat(now - $0) } ?? -1
        let moving = ts >= 0 && stillSend == nil
        if ts > lifetime {
            canvas.clear()
            done = true
            return false
        }
        if dirty || moving { draw(canvas, ts: ts) }
        dirty = false
        return moving
    }

    private func uniforms(_ canvas: SkyCanvas, ts: CGFloat) -> SkyUniforms {
        var u = SkyUniforms()
        let headroom = canvas.headroom
        u.a = SIMD4(effect == .stardust ? 0 : 1, Float(p), Float(ts), -1)
        u.b = SIMD4(Float(canvas.layer.bounds.width), Float(canvas.layer.bounds.height), Float(canvas.pxScale), Float(headroom))
        u.c = SIMD4(Float(landing.x), Float(landing.y), Float(card.width), Float(card.height))
        let turn = Float(StageView.Look.rainbowDragTurn * p + 0.3 * max(0, ts))
        if effect == .stardust {
            let vortexTime = ts < 0 ? vortex(held: p) : vortexAtRelease + ts
            let level = ts < 0 ? 0.9 * pow(p, 0.8) : 0.9 * pow(max(p, 0.5), 0.8) * (1 - seg(ts, 0.1, 0.4))
            u.d = SIMD4(Float(seam.x), Float(seam.y), Float(vortexTime), Float(level))
            u.e = SIMD4(linear(palette.glow), palette.rainbow ? 1 : 0)
            u.f = SIMD4(linear(palette.core), turn)
        } else {
            let safe = SkyColor.lightningSafe(rgb(palette.glow))
            let lavender = safe.mixed(with: PortalRGB(red: 0.82, green: 0.76, blue: 1), 0.5)
            let hold = ts < 0 ? 0.6 * pow(p, 0.8) : 0.6 * pow(max(p, 0.5), 0.8) * (1 - seg(ts, 0, 0.12))
            u.d = SIMD4(Float(seam.x), Float(seam.y), 0, Float(hold))
            u.e = SIMD4(linear(ns(safe)), 0)
            u.f = SIMD4(linear(ns(lavender)), 0)
        }
        let cols = SkyStage.grid.columns, rows = SkyStage.grid.rows
        u.g = SIMD4(Float(cols), Float(rows), Float(Self.fillerCount), Float(seed % 65_536))
        u.h = SIMD4(Float(effect.skyFlight), 0, 1, Float(k))
        u.j = SIMD4(Float(Stardust.holdSeconds), Float(Stardust.launchSpread), Float(Stardust.flight.lowerBound), Float(Stardust.flight.upperBound))
        return u
    }

    static let grid = Stardust.grid(width: Double(StageView.Look.card.width), height: Double(StageView.Look.card.height),
                                    step: 1, budget: grainBudget)

    private func draw(_ canvas: SkyCanvas, ts: CGFloat) {
        var u = uniforms(canvas, ts: ts)
        let engine = canvas.engine
        if effect == .stardust {
            let card = SkyBoard.snapshot?.texture
            let n = Self.grid.columns * Self.grid.rows
            let launched = ts >= 0 && card != nil
            let filler = u.d.w > 0.001
            canvas.draw { buffer, target in
                engine.pass(buffer, into: target, clear: true) { enc in
                    if filler {
                        enc.sky(engine.filler, u)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Self.fillerCount)
                    }
                    if launched, let card {
                        enc.sky(engine.grain, u, textures: [card])
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
                        enc.sky(engine.glitter, u)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n / 10)
                    }
                }
            }
            return
        }
        // Lightning.
        let strike = LightningStrike.level(at: Double(ts), allowed: allowed)
        let level = ts >= 0 ? strike.level : 0
        let edr = Float(min(canvas.headroom, 2.5))
        u.h.y = Float(level)
        u.h.z = Float(ts >= 0 ? LightningStrike.reveal(at: Double(ts)) : 0)
        u.i = SIMD4(0.6, strike.flash ? edr : 1, 0, 0)
        let bolt = level > 0.002 && strike.bolt < bolts.count ? bolts[strike.bolt] : nil
        let target0 = boltTarget, mips = self.mips, blank = engine.blank
        canvas.draw { buffer, target in
            guard let bolt, let boltTarget = target0, mips.count == 5 else {
                engine.pass(buffer, into: target, clear: true) { enc in
                    enc.sky(engine.comp, u, textures: [blank, blank])
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                return
            }
            engine.pass(buffer, into: boltTarget, clear: true) { enc in
                enc.sky(engine.bolt, u)
                enc.setVertexBuffer(bolt.buffer, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: bolt.count)
            }
            // Down five levels (Karis on the first), then back up with a tent.
            var source = boltTarget
            for (n, mip) in mips.enumerated() {
                var d = u
                d.i.w = n == 0 ? 1 : 0
                engine.pass(buffer, into: mip, clear: true) { enc in
                    enc.sky(engine.down, d, textures: [source])
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                source = mip
            }
            for n in stride(from: mips.count - 1, to: 0, by: -1) {
                engine.pass(buffer, into: mips[n - 1], clear: false) { enc in
                    enc.sky(engine.up, u, textures: [mips[n]])
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
            engine.pass(buffer, into: target, clear: true) { enc in
                enc.sky(engine.comp, u, textures: [boltTarget, mips[0]])
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
    }

    // MARK: Bolts

    /// From the edge at the card's exit height to just inside the card's right edge at its spot.
    private var boltEnds: (from: (x: Double, y: Double), to: (x: Double, y: Double)) {
        ((Double(seam.x), Double(seam.y)), (Double(landing.x + card.width * 0.3), Double(landing.y + card.height * 0.04)))
    }

    private func makeBolts() {
        let ends = boltEnds
        let shapes = (0...LightningStrike.restrikes.count).map { n in
            LightningBolt(from: ends.from, to: ends.to, seed: seed &+ UInt32(n) &* 7919, generations: 5, branches: 2 + Int(seed % 3))
        }
        if let engine = canvas?.engine {
            bolts = shapes.compactMap { Self.mesh($0, device: engine.device) }
        } else {
            buildFallbackBolts(shapes)
        }
    }

    /// Each line as one strip of quads with mitred normals, six vertices a segment.
    private static func mesh(_ bolt: LightningBolt, device: MTLDevice) -> (MTLBuffer, Int)? {
        var out: [SkyBoltVertex] = []
        for line in bolt.lines {
            let pts = line.points.map { SIMD2(Float($0.x), Float($0.y)) }
            guard pts.count > 1 else { continue }
            func perp(_ v: SIMD2<Float>) -> SIMD2<Float> { let l = max(1e-5, simd_length(v)); return SIMD2(-v.y / l, v.x / l) }
            var normals: [SIMD2<Float>] = []
            for i in pts.indices {
                let a = perp(pts[min(i + 1, pts.count - 1)] - pts[max(i - 1, 0)])
                let n0 = i > 0 ? perp(pts[i] - pts[i - 1]) : a
                let m = simd_normalize(n0 + a)
                normals.append(m / max(0.5, simd_dot(m, n0)))
            }
            for i in 0..<(pts.count - 1) {
                let w = Float(line.weight)
                let along0 = Float(line.points[i].along), along1 = Float(line.points[i + 1].along)
                let a0 = SkyBoltVertex(p: pts[i], n: normals[i], along: along0, side: -1, weight: w)
                let a1 = SkyBoltVertex(p: pts[i], n: normals[i], along: along0, side: 1, weight: w)
                let b0 = SkyBoltVertex(p: pts[i + 1], n: normals[i + 1], along: along1, side: -1, weight: w)
                let b1 = SkyBoltVertex(p: pts[i + 1], n: normals[i + 1], along: along1, side: 1, weight: w)
                out += [a0, a1, b0, a1, b1, b0]
            }
        }
        guard !out.isEmpty,
              let buffer = device.makeBuffer(bytes: out, length: out.count * MemoryLayout<SkyBoltVertex>.stride, options: .storageModeShared)
        else { return nil }
        return (buffer, out.count)
    }

    // MARK: Core Animation fallback

    private func buildFallback() {
        let g = CAGradientLayer()
        g.type = .radial
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        let tone: NSColor = effect == .lightning
            ? ns(SkyColor.lightningSafe(rgb(palette.glow)).mixed(with: PortalRGB(red: 0.82, green: 0.76, blue: 1), 0.5))
            : palette.glow
        g.colors = [tone.withAlphaComponent(effect == .lightning ? 0.22 : 0.4).cgColor, tone.withAlphaComponent(0).cgColor]
        g.bounds = CGRect(x: 0, y: 0, width: 160 * k, height: 520 * k)
        g.position = seam
        g.opacity = 0
        g.actions = ["opacity": NSNull(), "position": NSNull()]
        // On the GPU the filler and the hold glow are drawn by the shader.
        if canvas == nil { layer.addSublayer(g); glow = g }
    }

    private func buildFallbackBolts(_ shapes: [LightningBolt]) {
        paths.forEach { $0.forEach { $0.removeFromSuperlayer() } }
        let ice = ns(SkyColor.lightningSafe(rgb(palette.glow)))
        paths = shapes.map { bolt in
            let path = CGMutablePath()
            for line in bolt.lines {
                path.move(to: CGPoint(x: line.points[0].x, y: line.points[0].y))
                for pt in line.points.dropFirst() { path.addLine(to: CGPoint(x: pt.x, y: pt.y)) }
            }
            return [(14 * k, ice.withAlphaComponent(0.12)), (6 * k, ice.withAlphaComponent(0.3)), (2, NSColor.white)].map { width, color in
                let s = CAShapeLayer()
                s.frame = layer.bounds
                s.path = path
                s.fillColor = nil
                s.strokeColor = color.cgColor
                s.lineWidth = width
                s.lineJoin = .round
                s.lineCap = .round
                s.opacity = 0
                s.actions = ["opacity": NSNull(), "strokeEnd": NSNull()]
                layer.addSublayer(s)
                return s
            }
        }
    }

    private func playFallback(still t: Double?) {
        if let glow {
            let o = CGFloat(glow.opacity)
            timeline(glow, 0.3, still: t, opacity: { s in o * (1 - seg(s, 0, 0.3)) })
        }
        guard effect == .lightning else { return }
        let allowed = self.allowed
        for (n, strokes) in paths.enumerated() {
            for (i, s) in strokes.enumerated() {
                // Halo and glow follow the level; the core is white only on a flash that passed the cap.
                timeline(s, LightningStrike.end, still: t, opacity: { time in
                    let v = LightningStrike.level(at: Double(time), allowed: allowed)
                    guard v.bolt == n else { return 0 }
                    let core = i == 2 ? (v.flash ? 1 : 0.7) : 1
                    return CGFloat(v.level) * core
                })
                if n == 0 { reveal(s, still: t) }
            }
        }
    }

    /// The leader draws on in four steps.
    private func reveal(_ s: CAShapeLayer, still t: Double?) {
        if let t { s.strokeEnd = CGFloat(LightningStrike.reveal(at: t)); return }
        let a = CAKeyframeAnimation(keyPath: "strokeEnd")
        let steps = LightningStrike.leaderSteps
        a.values = (1...steps).map { Double($0) / Double(steps) }
        a.keyTimes = (0..<steps).map { NSNumber(value: Double($0) / Double(steps)) }
        a.calculationMode = .discrete
        a.duration = LightningStrike.leaderSeconds
        s.strokeEnd = 1
        s.add(a, forKey: "leader")
    }

    private func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - Card

@MainActor
final class SkyCard: FXClient {
    let effect: PortalEffect
    private let host: CALayer
    private let cardFrame: CGRect
    private let radius: CGFloat
    private var canvas: SkyCanvas?
    private var lift: CALayer?
    private var sentAt: CFTimeInterval?
    private var landedAt: CFTimeInterval?
    private var stillSend: CGFloat?
    private var stillLand: CGFloat?
    private var allowed: [Bool] = []
    private var dirty = true
    private var done = false

    /// Stardust on the GPU: the card is grains until the real picture crossfades in.
    var hidesCard: Bool { effect == .stardust && canvas != nil }

    init?(effect: PortalEffect, host: CALayer, cardFrame: CGRect, radius: CGFloat) {
        guard effect.isSky else { return nil }
        self.effect = effect
        self.host = host
        self.cardFrame = cardFrame
        self.radius = radius
        SkyBoard.snapshot = nil
        if let engine = SkyEngine.forCrossing() {
            let c = SkyCanvas(engine: engine, frame: cardFrame, scale: host.contentsScale > 1 ? host.contentsScale : 2, maxPixels: 400_000)
            canvas = c
            host.addSublayer(c.layer)
        } else if effect == .lightning {
            // The exposure lift on the Core Animation path: white, inside the card only.
            let l = CALayer()
            l.frame = cardFrame
            l.cornerRadius = radius
            l.cornerCurve = .continuous
            l.backgroundColor = NSColor.white.cgColor
            l.opacity = 0
            l.actions = ["opacity": NSNull()]
            host.addSublayer(l)
            lift = l
        }
    }

    func setSnapshot(_ image: CGImage?) {
        guard effect == .stardust, let engine = canvas?.engine else { return }
        SkyBoard.snapshot = engine.texture(from: image).map(MTLTextureBox.init)
    }

    /// The release: Stardust's card waits as grains and crossfades in over
    /// the last 120 ms from 1.02 to 1.0; Lightning plans its flashes.
    func commit(card: CALayer, still t: Double?, flight: Double) {
        if let t { stillSend = CGFloat(t) } else { sentAt = CACurrentMediaTime() }
        if effect == .lightning {
            allowed = SkyBoard.strike(at: CACurrentMediaTime(), still: t != nil)
            if let lift {
                let allowed = self.allowed
                timeline(lift, LightningStrike.end, still: t, opacity: { s in
                    let v = LightningStrike.level(at: Double(s), allowed: allowed)
                    return v.flash ? 0.18 * CGFloat(v.level) : 0
                })
            }
        }
        if hidesCard {
            let L = CGFloat(flight), d = CGFloat(Stardust.handoffSeconds), s0 = CGFloat(Stardust.handoffScale)
            timeline(card, Double(L), still: t, opacity: { s in seg(s, L - d, L, .retire) },
                     transform: { s in let v = lerp(s0, 1, seg(s, L - d, L, .travel)); return CATransform3DMakeScale(v, v, 1) })
        }
        changed()
    }

    func land(still t: Double?) {
        if let t { stillLand = CGFloat(t) } else { landedAt = CACurrentMediaTime() }
        changed()
    }

    func stop() {
        done = true
        FXDriver.shared.remove(self)
        canvas?.clear()
        lift?.removeAllAnimations()
    }

    private func changed() {
        dirty = true
        guard canvas != nil else { return }
        if MetalFX.mode == .stills { _ = tick(now: CACurrentMediaTime()) } else { FXDriver.shared.wake(self) }
    }

    func tick(now: CFTimeInterval) -> Bool {
        guard !done, let canvas else { return false }
        let ts = stillSend ?? sentAt.map { CGFloat(now - $0) } ?? -1
        let ti = stillLand ?? landedAt.map { CGFloat(now - $0) } ?? -1
        let still = stillSend != nil || stillLand != nil
        let moving = ts >= 0 && !still
        let over = effect == .stardust ? ti > CGFloat(Stardust.glintSeconds) + 0.02 : ts > CGFloat(LightningStrike.end)
        if over {
            canvas.clear()
            done = true
            return false
        }
        if dirty || moving { draw(canvas, ts: ts, ti: ti) }
        dirty = false
        return moving
    }

    private func draw(_ canvas: SkyCanvas, ts: CGFloat, ti: CGFloat) {
        var u = SkyUniforms()
        let headroom = canvas.headroom
        let f = canvas.layer.frame
        u.b = SIMD4(Float(f.width), Float(f.height), Float(canvas.pxScale), Float(headroom))
        u.c = SIMD4(Float(cardFrame.midX - f.minX), Float(cardFrame.midY - f.minY), Float(cardFrame.width), Float(cardFrame.height))
        var add: Float = 0, sweep: Float = 0
        if effect == .stardust, ti >= 0 {
            // One glint: up to 3× SDR white, clamped to the headroom, back to 1 by 0.15 s.
            add = Float((Stardust.glint(at: Double(ti), headroom: Double(headroom)) - 1) * 0.5)
            // An SDR screen still sees the band, at white.
            if headroom <= 1.01 { add = Float(0.35 * (1 - seg(ti, 0, CGFloat(Stardust.glintSeconds)))) }
            sweep = Float(ti / CGFloat(Stardust.glintSeconds))
        } else if effect == .lightning, ts >= 0 {
            let v = LightningStrike.level(at: Double(ts), allowed: allowed)
            if v.flash { add = 0.18 * Float(v.level) * Float(min(headroom, 2.5)); sweep = 0.5 }
        }
        u.i = SIMD4(add, sweep, Float(radius), 0)
        let engine = canvas.engine
        canvas.draw { buffer, target in
            engine.pass(buffer, into: target, clear: true) { enc in
                guard add > 0.0005 else { return }
                enc.sky(engine.lift, u)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
    }
}
