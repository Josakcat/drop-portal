//
//  MetalCrossing.swift
//  DropPortal
//
//  The crossing's GPU passes, hung on the Core Animation stage and card by a
//  few one-line hooks (StageView.gpu, CardLook.gpu) so the CA path stays the
//  same file it was and is still what plays when MetalFX gives no engine
//  (Metal missing or still compiling, Reduce motion, Low Power Mode, the
//  settings process).
//
//  GPUStage: one canvas over the whole stage, under the card: the effect's
//  light (stage_fs) and, from the landing, thousands of particles.
//  GPUCard: one canvas inside the card's host, so the card's pose still
//  comes from `host.sublayerTransform`: the card's own picture, distorted
//  (card_fs), and Paper plane's two halves lit as paper (wing_fs).
//
//  Live, both draw from FXDriver's display link while something moves and
//  only when something changed while the finger holds the card; the frame is
//  encoded off the main thread. Stills draw at once, at the instant given.
//

import AppKit
import DropPortalCore
import Metal
import QuartzCore

/// The crossing's clock, shared by both halves: p while held, then seconds
/// since the release and since the landing (live from the media clock, or
/// the instant the harness asked for).
private struct FXClock {
    var p: CGFloat = 0
    var sentAt: CFTimeInterval?
    var landedAt: CFTimeInterval?
    var stillSend: CGFloat?
    var stillImpact: CGFloat?

    func since(now: CFTimeInterval) -> (send: CGFloat, impact: CGFloat) {
        let s = stillSend ?? sentAt.map { CGFloat(now - $0) } ?? -1
        let i = stillImpact ?? landedAt.map { CGFloat(now - $0) } ?? -1
        return (s, i)
    }

    var isStill: Bool { stillSend != nil || stillImpact != nil }
}

// MARK: - Stage

@MainActor
final class GPUStage: FXClient {
    /// The impact's particles are gone by then; the stage light earlier.
    static let impactSeconds: CGFloat = 0.62
    private let canvas: FXCanvas
    private let effect: PortalEffect
    private let palette: PortalPalette
    private var seam: CGPoint
    private let landing: CGPoint
    private let k: CGFloat
    private var card: CGPoint
    private var clock = FXClock()
    /// Release to landing: the effect's own, or the thrown path's, from `send`.
    private var flight: Double
    private var dirty = true
    private var done = false

    var layer: CALayer { canvas.layer }

    /// Nil when the crossing plays the Core Animation path.
    init?(frame: CGRect, effect: PortalEffect, palette: PortalPalette, seam: CGPoint, landing: CGPoint, k: CGFloat, scale: CGFloat) {
        // Stardust and Lightning draw through SkyStage (SkyCrossing.swift).
        guard !effect.isSky, !effect.isCourier, let engine = MetalFX.forCrossing() else { return nil }
        canvas = FXCanvas(engine: engine, frame: frame, scale: scale, maxPixels: 1_000_000)
        self.effect = effect
        self.palette = palette
        self.seam = seam
        self.landing = landing
        self.k = k
        flight = effect.flight
        card = seam
    }

    func setIntensity(_ p: CGFloat) { clock.p = p; changed() }
    func follow(card center: CGPoint) { card = center; changed() }
    /// The card's exit height on the edge (StageView.moveSeam).
    func moveSeam(toY y: CGFloat) { seam.y = y; changed() }

    func send(still t: Double?, flight: Double = 0) {
        if flight > 0 { self.flight = flight }
        if let t { clock.stillSend = CGFloat(t) } else { clock.sentAt = CACurrentMediaTime() }
        changed()
    }

    func impact(still t: Double?) {
        if let t { clock.stillImpact = CGFloat(t) } else { clock.landedAt = CACurrentMediaTime() }
        changed()
    }

    func stop() {
        done = true
        FXDriver.shared.remove(self)
        canvas.clear()
    }

    private func changed() {
        dirty = true
        if MetalFX.mode == .stills { _ = tick(now: CACurrentMediaTime()) } else { FXDriver.shared.wake(self) }
    }

    func tick(now: CFTimeInterval) -> Bool {
        guard !done else { return false }
        let (ts, ti) = clock.since(now: now)
        let moving = ts >= 0 && !clock.isStill
        if ti > Self.impactSeconds {
            canvas.clear()
            done = true
            return false
        }
        if dirty || moving { canvas.draw(draws(ts: ts, ti: ti)) }
        dirty = false
        return moving
    }

    private func draws(ts: CGFloat, ti: CGFloat) -> [FXDraw] {
        let engine = canvas.engine
        var u = FXUniforms()
        u.set(palette: palette, k: k)
        let p = clock.p
        let (sx, sy, turn) = CardLook.heldShape(effect, p)
        let rainbowTurn = StageView.Look.rainbowDragTurn * p
            + (ti >= 0 ? (1 - StageView.Look.rainbowDragTurn) * Ease.inOut(ti / 0.52) : 0)
        u.a = SIMD4(effect.shaderID, Float(p), Float(ts), Float(ti))
        u.b = SIMD4(Float(canvas.layer.bounds.width), Float(canvas.layer.bounds.height), 0, 0)
        u.c = SIMD4(Float(card.x), Float(card.y), Float(StageView.Look.card.width), Float(StageView.Look.card.height))
        u.d = SIMD4(Float(seam.x), Float(seam.y), Float(landing.x), Float(landing.y))
        u.f.w = Float(rainbowTurn)
        u.h = SIMD4(Float(flight), Float(sx), Float(sy), Float(turn * .pi / 180))
        u.i = SIMD4(Float(canvas.pxScale), 0, 0, 0)
        var list = [FXDraw(pipeline: engine.stage, uniforms: u, texture: nil)]
        if ti >= 0 {
            // From the landing the card is at its spot.
            var pu = u
            pu.c.x = Float(landing.x)
            pu.c.y = Float(landing.y)
            list.append(FXDraw(pipeline: engine.particles, uniforms: pu, texture: nil, instances: effect.particleCount))
        }
        return list
    }
}

// MARK: - Card

@MainActor
final class GPUCard: FXClient {
    /// Room round the card for the swirl, the slices' trail and the glitch.
    static let reach = CGSize(width: 130, height: 64)
    private let canvas: FXCanvas
    private var wingCanvases: [FXCanvas] = []
    private let effect: PortalEffect
    private let palette: PortalPalette
    private let cardFrame: CGRect
    private let radius: CGFloat
    private var texture: MTLTextureBox?
    private var clock = FXClock()
    /// Release to landing: CardLook's `flight`, the thrown path's when the phone sent one.
    private var flight: Double
    private var clipX: CGFloat
    private var dirty = true
    private var done = false

    /// Whether the GPU draws the card's picture itself (the card is hidden
    /// meanwhile), or only light over it (Liquid; everyone after the landing).
    var drawsPicture: Bool { texture != nil && effect != .liquid && effect != .plane }

    var layer: CALayer { canvas.layer }

    init?(effect: PortalEffect, palette: PortalPalette, host: CALayer, cardFrame: CGRect, radius: CGFloat) {
        guard !effect.isSky, !effect.isCourier, let engine = MetalFX.forCrossing() else { return nil }
        let frame = cardFrame.insetBy(dx: -Self.reach.width, dy: -Self.reach.height)
        canvas = FXCanvas(engine: engine, frame: frame, scale: host.contentsScale > 1 ? host.contentsScale : 2)
        self.effect = effect
        self.palette = palette
        self.cardFrame = cardFrame
        self.radius = radius
        flight = effect.flight
        clipX = host.bounds.width
        host.addSublayer(canvas.layer)
    }

    /// Paper plane: a canvas on each of the two hinged halves.
    func attach(wings: [CALayer]) {
        guard effect == .plane else { return }
        wingCanvases = wings.map { wing in
            let c = FXCanvas(engine: canvas.engine, frame: wing.bounds, scale: 2, maxPixels: 200_000)
            wing.addSublayer(c.layer)
            return c
        }
    }

    func setSnapshot(_ image: CGImage?) {
        texture = canvas.engine.texture(from: image).map(MTLTextureBox.init)
        changed()
    }

    func clip(toMaxX x: CGFloat) { clipX = x; changed() }
    func update(progress p: CGFloat) { clock.p = p; changed() }

    func commit(still t: Double?, flight: Double = 0) {
        if flight > 0 { self.flight = flight }
        if let t { clock.stillSend = CGFloat(t) } else { clock.sentAt = CACurrentMediaTime() }
        changed()
    }

    func land(still t: Double?) {
        if let t { clock.stillImpact = CGFloat(t) } else { clock.landedAt = CACurrentMediaTime() }
        changed()
    }

    func stop() {
        done = true
        FXDriver.shared.remove(self)
        canvas.clear()
        wingCanvases.forEach { $0.clear() }
    }

    private func changed() {
        dirty = true
        if MetalFX.mode == .stills { _ = tick(now: CACurrentMediaTime()) } else { FXDriver.shared.wake(self) }
    }

    func tick(now: CFTimeInterval) -> Bool {
        guard !done else { return false }
        let (ts, ti) = clock.since(now: now)
        let moving = ts >= 0 && !clock.isStill
        if ti > 0.5 {
            canvas.clear()
            wingCanvases.forEach { $0.clear() }
            done = true
            return false
        }
        if dirty || moving {
            canvas.draw(draws(ts: ts, ti: ti))
            if effect == .plane { drawWings(ts: ts, ti: ti) }
        }
        dirty = false
        return moving
    }

    private func strength(ts: CGFloat, ti: CGFloat) -> CGFloat {
        let p = clock.p, L = CGFloat(flight)
        let held: CGFloat
        switch effect {
        case .wormhole: held = 4.2 * pow(1 - p, 1.3)
        case .beam: held = 0.2 + 0.8 * (1 - p)
        case .liquid: held = seg(p, 0.15, 0.7)
        default: held = 1
        }
        guard ts >= 0 else { return held }
        switch effect {
        case .wormhole: return held * (1 - seg(ts, 0, L, .travel))
        case .beam: return ti >= 0 ? 0.9 * (1 - seg(ti, 0, 0.12)) : lerp(held, 0.12, seg(ts, 0, L))
        default: return held
        }
    }

    private func draws(ts: CGFloat, ti: CGFloat) -> [FXDraw] {
        // The picture goes back to Core Animation at the landing: only light is left to draw.
        if effect == .plane || (ti >= 0 && effect == .wormhole) { return [] }
        var u = FXUniforms()
        u.set(palette: palette, k: 1)
        let f = canvas.layer.frame
        u.a = SIMD4(effect.shaderID, Float(clock.p), Float(ts), Float(ti))
        u.b = SIMD4(Float(f.width), Float(f.height), Float(f.minX), Float(f.minY))
        u.c = SIMD4(Float(cardFrame.midX), Float(cardFrame.midY), Float(cardFrame.width), Float(cardFrame.height))
        u.f.w = Float(StageView.Look.rainbowDragTurn * clock.p)
        u.i = SIMD4(Float(canvas.pxScale), Float(clipX), Float(radius), Float(strength(ts: ts, ti: ti)))
        if effect == .beam {
            let held = ts < 0
            let clockStep = held ? floor(clock.p * 40) : floor(ts * 50)
            u.j = SIMD4(Float(90 * (1 - clock.p)), Float(held ? -1 : ts), Float(clockStep),
                        Float(0.3 * (held ? seg(clock.p, 0.4, 1) : 1)))
            // At the landing the slices hand over to the card in 80 ms (CardLook.land fades the card in).
            if ti >= 0 { canvas.layer.opacity = Float(1 - seg(ti, 0, 0.08)) }
        }
        return [FXDraw(pipeline: canvas.engine.card, uniforms: u, texture: texture?.texture)]
    }

    /// CardLook's hinge, the same numbers: up to 34° with p, 68° as it
    /// folds into the plane, opening from 68° to 20° before the landing.
    private func fold(ts: CGFloat) -> (degrees: CGFloat, crease: CGFloat) {
        let look = CardLook.Look.planeFold, L = CGFloat(flight), loopEnd = L - 0.1
        let k0 = seg(clock.p, look.from, 1)
        guard ts >= 0 else { return (look.degrees * k0, 0.7 * k0) }
        if ts < loopEnd { return (lerp(look.degrees * k0, 68, seg(ts, 0, 0.09, .travel)), 0.7 * k0 * (1 - seg(ts, 0, 0.09))) }
        return (lerp(68, 20, seg(ts, loopEnd, L, .travel)), 0.5 * seg(ts, loopEnd, L))
    }

    private func drawWings(ts: CGFloat, ti: CGFloat) {
        guard ti < 0, let texture else { wingCanvases.forEach { $0.clear() }; return }
        let (degrees, crease) = fold(ts: ts)
        for (i, c) in wingCanvases.enumerated() {
            var u = FXUniforms()
            u.set(palette: palette, k: 1)
            u.b = SIMD4(Float(c.layer.bounds.width), Float(c.layer.bounds.height), 0, 0)
            u.i = SIMD4(Float(c.pxScale), i == 0 ? 1 : 0, Float(radius), Float(degrees * .pi / 180))
            u.j.x = Float(crease)
            c.draw([FXDraw(pipeline: canvas.engine.wing, uniforms: u, texture: texture.texture)])
        }
    }
}

/// A texture the render queue may read while the main actor lets it go.
final class MTLTextureBox: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}
