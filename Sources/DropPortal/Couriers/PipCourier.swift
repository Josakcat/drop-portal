//
//  PipCourier.swift
//  DropPortal
//
//  Pip the hamster on the Mac, ported from the approved mockup
//  (`.droppykit/design/fx-mockups-cute-v2/mockups.html`, "1. Cheek Stash":
//  `drawHamster`, `hamWait`, `hamMac`). Pip waits peeking in from the right
//  edge with its cheeks filling as the phone's card goes in, tumbles in when
//  the bytes come (T = 0), plants with a squash at 200 ms, winds up, spits the
//  card out with one proud "ptoo" from 440 ms so it lands exactly at L, grooms,
//  turns and scurries out. Rare gag: a sunflower seed drops out of its cheek.
//
//  Every pose is computed in the mockup's own Mac space (mock px, y down,
//  landing at 660, 204, ground 336) and mapped onto the stage by
//  `scene.mock`; the right edge is the stage's own. The parts are redrawn
//  each frame from the pose (cheeks, ears, eyes and mouth change shape), and
//  ears, splay and cheeks lag the body on damped springs integrated over the
//  last 0.7 s of the body's own path, so a still from the harness is exactly a
//  live frame. See "How to add a courier" in .droppykit/docs/effects.md.
//

import AppKit
import DropPortalCore

private typealias K = CourierKit

// MARK: - Pose

enum PipEyes { case open, wide, squeeze, happy }
enum PipMouth { case w, o, puff, smile }

/// One frame of Pip in the mockup's space (mock px, y down, angles clockwise on screen).
struct PipPose {
    var x: CGFloat
    var y: CGFloat
    var sx: CGFloat = 1, sy: CGFloat = 1, rot: CGFloat = 0, face: CGFloat = 1
    /// The tumble, about the middle (46 units up), and the stretch along the motion.
    var spin: CGFloat = 0, vs: CGFloat = 1
    var alpha: CGFloat = 1
    var lookX: CGFloat = -3, lookY: CGFloat = 0, cheek: CGFloat = 1, tilt: CGFloat = 0
    var ear: CGFloat = 0, pawL: CGFloat = 0, pawR: CGFloat = 0
    var eyes: PipEyes = .open, mouth: PipMouth = .w, chew: CGFloat = 0, whisk: CGFloat = 0
    var breath: CGFloat = 0
    /// Forces the lid shut this much (on top of the plan's blinks).
    var lid: CGFloat = 0
    /// The card copy in mock space: middle, scale (1 = the landed card), turn (clockwise).
    var card: (x: CGFloat, y: CGFloat, s: CGFloat, rot: CGFloat)? = nil
}

/// The secondary motion: ears, their splay and the cheeks, lagging the body.
struct PipSprings { var ear: CGFloat = 0, splay: CGFloat = 0, cheek: CGFloat = 0 }

/// The mockup's Mac choreography, in its own units.
enum PipMac {
    static let HXM: CGFloat = 792, GM: CGFloat = 336, kM: CGFloat = 0.86
    static let landing = CGPoint(x: 660, y: 204)

    static func slope(_ f: Ease, _ u: CGFloat) -> CGFloat {
        (f(min(1, u + 0.01)) - f(max(0, u - 0.01))) / 0.02
    }

    /// Peeking in from the right edge (`edge` in mock x) while the phone holds the card at p.
    static func wait(p: CGFloat, ms: Double, edge: CGFloat) -> PipPose {
        let a = p < 0.5 ? 10 * K.easeOut(p / 0.5) : 10 + 12 * K.easeOut((p - 0.5) / 0.5)
        var P = PipPose(x: edge + 50 * kM - a * 1.9 + 6, y: GM)
        P.rot = -0.1
        P.lookX = -14
        P.whisk = 6
        P.cheek = p < 0.5 ? 1 : 1 + 0.6 * K.easeInOut((p - 0.5) / 0.5)
        P.mouth = .w
        P.tilt = -0.05
        // Breathing and a nibble while it watches.
        let t = CGFloat(ms) / 1000
        P.breath = 0.016 * sin(2 * .pi * t / 2.6)
        P.chew = p > 0.3 && p < 0.55 ? sin(t * 40) : 0
        P.ear = 0.25 * K.kick(ms - 120, f: 6, z: 0.25)
        return P
    }

    /// T 0 … gone on the plan's clock; nil once gone.
    static func at(_ T: Double, edge: CGFloat, jitter: CGFloat) -> PipPose? {
        guard T >= 0, T <= 1080 else { return nil }
        let t = CGFloat(T)
        var P = PipPose(x: HXM, y: GM)
        P.lookX = -4
        if t < 200 {
            // Tumbling in from past the right edge.
            let u = K.part(T, 0, 200), s = K.decel(u)
            P.x = K.mix(edge + 67, HXM, s)
            P.spin = -2 * .pi * s
            P.cheek = 1.7
            P.eyes = .squeeze
            P.mouth = .puff
            P.vs = t < 45 ? 1.25 : 1 + 0.1 * K.clamp(slope(K.decel, u) / 3)
            P.y = GM - 5 * jitter * abs(sin(s * 2 * .pi)) * (1 - s)
            return P
        }
        if t < 260 {
            // Planted: the landing squash.
            let q = K.landSquash(T - 200, peak: 1.25, rebound: 0.95, hold: 26)
            P.sx = q
            P.sy = 1 / q
            P.cheek = 1.7
            P.mouth = .puff
            P.eyes = t < 215 ? .squeeze : .open
            return P
        }
        if t < 440 {
            // The wind-up: leans back, cheeks swell.
            let w = K.easeInOut(K.part(T, 260, 440)), q = K.landSquash(T - 200, peak: 1.25, rebound: 0.95, hold: 26)
            P.rot = 0.105 * w * jitter
            P.cheek = 1.7 + 0.15 * w
            P.eyes = t < 290 ? .open : .squeeze
            P.mouth = .puff
            P.sx = q * (1 + 0.05 * w)
            P.sy = 1 / P.sx
            P.lookX = -4 + 3 * w
            return P
        }
        if t < 520 {
            // Ptoo.
            let r = K.part(T, 440, 520), e = K.easeOut(r)
            P.x = HXM + 8 * e
            P.rot = K.mix(0.105 * jitter, -0.07, K.easeOut(r * 1.6))
            P.sx = K.mix(1.05, 1.15, K.easeOut(r * 3))
            P.sy = 1 / P.sx
            P.cheek = r < 0.5 ? K.mix(1.85, 0.9, K.easeOut(r * 2)) : 0.9 + 0.1 * (1 - K.settle(Double(r - 0.5) * 40, f: 4, z: 0.3))
            P.mouth = .o
            P.eyes = r < 0.35 ? .squeeze : .wide
            return P
        }
        P.x = HXM + 8
        if t < 760 {
            // Proud: bounces back, grooms its face with both paws.
            let a = T - 520, q = 1 + 0.15 * K.settle(a, f: 3, z: 0.5)
            P.sx = q
            P.sy = 1 / q
            P.rot = -0.07 * K.settle(a, f: 2.6, z: 0.5)
            P.cheek = 1 - 0.1 * K.settle(a + 40, f: 4, z: 0.3)
            let g = CGFloat(a / 240) * 2 * .pi, amt = K.clamp(CGFloat(a / 60)) * (1 - K.part(T, 700, 750))
            P.pawL = 0.4 + 0.6 * amt * (0.5 + 0.5 * sin(g))
            P.pawR = 0.4 + 0.6 * amt * (0.5 + 0.5 * sin(g + .pi))
            P.tilt = 0.07 * sin(g) * amt
            P.eyes = t < 700 ? .happy : .open
            P.mouth = t < 700 ? .w : .smile
            if t >= 700 { P.lid = CGFloat(CourierPlan.lid(T - 712)) }
            return P
        }
        // Turns round with a hop and scurries out to the right.
        let tu = K.part(T, 760, 840)
        P.face = cos(.pi * K.easeInOut(tu))
        P.y = GM - 7 * jitter * sin(.pi * tu)
        P.eyes = .open
        P.mouth = .smile
        if t > 830 {
            let u = K.part(T, 830, 1075), s = K.curveA(u)
            P.x = K.mix(HXM + 8, edge + 117, s)
            P.y = GM - 6 * abs(sin(u * .pi * 4.5))
            P.face = -1
            P.vs = 1 + 0.12 * K.clamp(slope(K.curveA, u) / 2.5)
            P.rot = 0.06
        }
        return P
    }

    /// The mockup's `rigM` for Pip (k = kM), mock space.
    static func body(_ P: PipPose, k: CGFloat = kM) -> CGAffineTransform {
        var m = CGAffineTransform(translationX: P.x, y: P.y)
        func then(_ t: CGAffineTransform) { m = t.concatenating(m) }
        if P.vs != 1 {
            let h = 46 * k
            then(CGAffineTransform(translationX: 0, y: -h))
            then(CGAffineTransform(scaleX: P.vs, y: 1 / P.vs))
            then(CGAffineTransform(translationX: 0, y: h))
        }
        if P.rot != 0 { then(CGAffineTransform(rotationAngle: P.rot)) }
        then(CGAffineTransform(scaleX: P.sx / (1 + P.breath * 0.6), y: P.sy * (1 + P.breath)))
        then(CGAffineTransform(scaleX: k * P.face, y: k))
        if P.spin != 0 {
            then(CGAffineTransform(translationX: 0, y: -46))
            then(CGAffineTransform(rotationAngle: P.spin * P.face))
            then(CGAffineTransform(translationX: 0, y: 46))
        }
        return m
    }

    /// The mouth in mock space (where the card comes out).
    static func mouth(_ P: PipPose) -> CGPoint {
        let tm = rotAt(0, -46, P.tilt)
        let q = CGPoint(x: P.lookX, y: -42 + P.lookY).applying(tm)
        return q.applying(body(P))
    }

    static func rotAt(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(rotationAngle: a)).concatenating(CGAffineTransform(translationX: x, y: y))
    }

    /// Ears, splay and cheeks as damped springs pushed by the body's
    /// acceleration (the mockup's GAINS), integrated over the last 0.7 s.
    static func springs(at T: Double, position: (Double) -> CGPoint?) -> PipSprings {
        let dt = 2.0, span = 700.0, h = 8.0
        let start = T - span
        let n = Int(span / dt)
        // Positions on a 2 ms grid, 8 ms either side.
        var grid: [CGPoint?] = []
        grid.reserveCapacity(n + 9)
        for i in -4...(n + 4) { grid.append(position(start + Double(i) * dt)) }
        struct Spr { var w: Double, z: Double, x = 0.0, v = 0.0
            mutating func step(_ dt: Double, _ F: Double) { let a = F - w * w * x - 2 * z * w * v; v += a * dt; x += v * dt } }
        var ear = Spr(w: 2 * .pi * 4.5, z: 0.28), splay = Spr(w: 2 * .pi * 4, z: 0.32), cheek = Spr(w: 2 * .pi * 5, z: 0.3)
        let L = 60000.0
        for i in 0..<n {
            let j = i + 4
            var ax = 0.0, ay = 0.0
            if let a = grid[j - 4], let b = grid[j], let c = grid[j + 4] {
                ax = max(-L, min(L, Double(a.x - 2 * b.x + c.x) / (h * h) * 1e6))
                ay = max(-L, min(L, Double(a.y - 2 * b.y + c.y) / (h * h) * 1e6))
            }
            ear.step(0.002, -0.028 * ax)
            splay.step(0.002, -0.008 * ay)
            cheek.step(0.002, -0.003 * ay)
        }
        func sat(_ x: Double, _ m: Double) -> CGFloat { CGFloat(m * tanh(x / m)) }
        return PipSprings(ear: sat(ear.x, 0.55), splay: sat(splay.x, 0.35), cheek: sat(cheek.x, 0.14))
    }
}

// MARK: - The drawing (the mockup's drawHamster as paths)

/// Every path of one frame of Pip, in the drawing's units (feet at 0,0, y down, facing left).
struct PipShapes {
    static let ink = pipColor(0x3A2414), fur = pipColor(0xF2A65A), shade = pipColor(0xD98840), cream = pipColor(0xFFF6EA)
    static let feetPink = pipColor(0xFFC0AE), blush = pipColor(0xFF9FB2), earPink = pipColor(0xFFB3A4)
    static let nose = pipColor(0xD9687A), pawPink = pipColor(0xFFD2C2), tongue = pipColor(0xFF8A9A)

    static func E(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ r: CGFloat = 0) -> CGPath {
        let rx = max(0.01, rx), ry = max(0.01, ry)
        var t = CGAffineTransform(rotationAngle: r).concatenating(CGAffineTransform(translationX: x, y: y))
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
    }

    static func xf(_ p: CGPath, _ t: CGAffineTransform) -> CGPath {
        var t = t
        return p.copy(using: &t) ?? p
    }

    static let body: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -92))
        p.addCurve(to: CGPoint(x: 50, y: -42), control1: CGPoint(x: 30, y: -92), control2: CGPoint(x: 50, y: -70))
        p.addCurve(to: CGPoint(x: 0, y: -1), control1: CGPoint(x: 50, y: -14), control2: CGPoint(x: 31, y: -1))
        p.addCurve(to: CGPoint(x: -50, y: -42), control1: CGPoint(x: -31, y: -1), control2: CGPoint(x: -50, y: -14))
        p.addCurve(to: CGPoint(x: 0, y: -92), control1: CGPoint(x: -50, y: -70), control2: CGPoint(x: -30, y: -92))
        p.closeSubpath()
        return p
    }()
    /// The body's lit part (the shade stays as a crescent on the lower right) and the cream belly.
    static let bodyLit = body.intersection(xf(body, CGAffineTransform(translationX: -5, y: -6)))
    static let belly = body.intersection(E(0, -14, 31, 22))
    static let feet = [E(-20, -4, 10, 6), E(20, -4, 10, 6)]
    static let highlight = E(-22, -74, 10, 5.5, -0.55)

    struct Eye { var fill: CGPath?; var line: CGPath?; var lineWidth: CGFloat; var shine: CGPath? }

    static func eye(_ x: CGFloat, _ y: CGFloat, _ rx0: CGFloat, _ ry0: CGFloat, _ st: PipEyes, _ bl: CGFloat, lw: CGFloat, dir: CGFloat) -> Eye {
        switch st {
        case .happy:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - rx0 * 1.15, y: y + ry0 * 0.35))
            p.addQuadCurve(to: CGPoint(x: x + rx0 * 1.15, y: y + ry0 * 0.35), control: CGPoint(x: x, y: y - ry0 * 1.25))
            return Eye(fill: nil, line: p, lineWidth: lw * 1.5, shine: nil)
        case .squeeze:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - rx0 * dir * 1.05, y: y - ry0 * 0.85))
            p.addLine(to: CGPoint(x: x + rx0 * dir * 0.95, y: y))
            p.addLine(to: CGPoint(x: x - rx0 * dir * 1.05, y: y + ry0 * 0.85))
            return Eye(fill: nil, line: p, lineWidth: lw * 1.5, shine: nil)
        case .open, .wide:
            let b = K.clamp(bl), sc: CGFloat = st == .wide ? 1.15 : 1
            let rx = rx0 * sc, ry = ry0 * sc
            if b > 0.82 {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x - rx * 1.1, y: y + ry * 0.1))
                p.addQuadCurve(to: CGPoint(x: x + rx * 1.1, y: y + ry * 0.1), control: CGPoint(x: x, y: y + ry * 0.85))
                return Eye(fill: nil, line: p, lineWidth: lw * 1.4, shine: nil)
            }
            var shine: CGPath?
            if b < 0.45 {
                let s = CGMutablePath()
                s.addPath(E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4))
                s.addPath(E(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19))
                shine = s
            }
            return Eye(fill: E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92)), line: nil, lineWidth: lw, shine: shine)
        }
    }

    struct Mouth { var fill: CGPath?; var tongue: CGPath?; var line: CGPath? }

    static func mouth(_ x: CGFloat, _ y: CGFloat, _ kind: PipMouth, s: CGFloat = 0.9) -> Mouth {
        switch kind {
        case .o:
            return Mouth(fill: E(x, y + 1.2 * s, 2.6 * s, 3.2 * s), tongue: E(x, y + 2.6 * s, 1.6 * s, 1.2 * s), line: nil)
        case .puff:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - 2 * s, y: y + s))
            p.addLine(to: CGPoint(x: x + 2 * s, y: y + s))
            return Mouth(fill: nil, tongue: nil, line: p)
        case .smile:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - 3.4 * s, y: y))
            p.addQuadCurve(to: CGPoint(x: x + 3.4 * s, y: y), control: CGPoint(x: x, y: y + 3.4 * s))
            return Mouth(fill: nil, tongue: nil, line: p)
        case .w:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - 4 * s, y: y))
            p.addQuadCurve(to: CGPoint(x: x, y: y + 0.4 * s), control: CGPoint(x: x - 2 * s, y: y + 2.6 * s))
            p.addQuadCurve(to: CGPoint(x: x + 4 * s, y: y), control: CGPoint(x: x + 2 * s, y: y + 2.6 * s))
            return Mouth(fill: nil, tongue: nil, line: p)
        }
    }
}

func pipColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: - The courier

@MainActor
final class PipCourier: CourierCharacter {
    let courier: Courier = .cheek

    /// The tumble and the stretch, inside the body (drawing units).
    private let inner = CALayer()
    /// Puffs, spit lines and sparkles (stage points), and the gag's seed.
    private var puffs: [CAShapeLayer] = []
    private let spit = CAShapeLayer()
    private var sparkles: [CAShapeLayer] = []
    private let seed = CALayer()
    private let seedBody = CAShapeLayer()
    private let seedStripe = CAShapeLayer()
    private weak var rig: CourierRig?

    /// This frame's pose and springs (the pose functions run just before `draw`).
    private var cur = PipPose(x: 0, y: 0)
    private var spr = PipSprings()
    /// The outline: 2 px at the mockup's Mac scale.
    private let lw: CGFloat = 2 / PipMac.kM

    func build(_ rig: CourierRig) {
        self.rig = rig
        inner.actions = K.noActions
        inner.bounds = .zero
        inner.position = .zero
        rig.body.addSublayer(inner)
        let empty = CGMutablePath(), S = PipShapes.self, ink = S.ink
        func add(_ name: String, _ fill: NSColor, stroke: CGFloat = 0, path: CGPath? = nil) {
            let l = rig.part(name, path ?? empty, fill: fill, ink: ink, width: stroke, in: inner)
            l.lineCap = .round
        }
        // The union outline, under every fill.
        add("o.footL", ink, stroke: 2 * lw, path: S.feet[0])
        add("o.footR", ink, stroke: 2 * lw, path: S.feet[1])
        add("o.earL", ink, stroke: 2 * lw)
        add("o.earR", ink, stroke: 2 * lw)
        add("o.body", ink, stroke: 2 * lw, path: S.body)
        add("o.chL", ink, stroke: 2 * lw)
        add("o.chR", ink, stroke: 2 * lw)
        add("footL", S.feetPink, path: S.feet[0])
        add("footR", S.feetPink, path: S.feet[1])
        add("earL", S.fur)
        add("earR", S.fur)
        add("earInL", S.earPink)
        add("earInR", S.earPink)
        add("body", S.shade, path: S.body)
        add("bodyLit", S.fur, path: S.bodyLit)
        add("belly", S.cream, path: S.belly)
        add("chL", S.fur)
        add("chR", S.fur)
        add("chArcs", .clear, stroke: lw * 0.8)
        add("hilite", .white, path: S.highlight)
        rig["hilite"]?.opacity = 0.5
        add("muzzle", S.cream)
        add("eyeL", ink)
        add("eyeR", ink)
        add("eyeLineL", .clear, stroke: lw * 1.4)
        add("eyeLineR", .clear, stroke: lw * 1.4)
        add("shineL", .white)
        add("shineR", .white)
        add("blush", S.blush)
        rig["blush"]?.opacity = 0.8
        add("blushDot", .white)
        rig["blushDot"]?.opacity = 0.44
        add("nose", S.nose)
        add("mouthFill", ink)
        add("tongue", S.tongue)
        add("mouthLine", .clear, stroke: lw * 1.1)
        add("whiskers", .clear, stroke: lw * 0.6)
        rig["whiskers"]?.opacity = 0.55
        add("o.paws", ink, stroke: lw * 1.2)
        add("paws", S.pawPink)

        // Effects in stage points, in front.
        for _ in 0..<15 {
            let l = CAShapeLayer()
            l.actions = K.noActions
            l.fillColor = pipColor(0xFFFAF0).cgColor
            rig.front.addSublayer(l)
            puffs.append(l)
        }
        spit.actions = K.noActions
        spit.fillColor = nil
        spit.strokeColor = NSColor.white.cgColor
        spit.lineCap = .round
        rig.front.addSublayer(spit)
        for _ in 0..<4 {
            let l = CAShapeLayer()
            l.actions = K.noActions
            l.fillColor = pipColor(0xFFF6C8).cgColor
            rig.front.addSublayer(l)
            sparkles.append(l)
        }
        seed.actions = K.noActions
        seed.bounds = .zero
        for l in [seedBody, seedStripe] {
            l.actions = K.noActions
            l.lineCap = .round
            seed.addSublayer(l)
        }
        let sp = CGMutablePath()
        sp.move(to: CGPoint(x: 0, y: -5))
        sp.addQuadCurve(to: CGPoint(x: 0, y: 5), control: CGPoint(x: 3.4, y: -1))
        sp.addQuadCurve(to: CGPoint(x: 0, y: -5), control: CGPoint(x: -3.4, y: -1))
        seedBody.path = sp
        seedBody.fillColor = pipColor(0x3A2F2A).cgColor
        seedBody.strokeColor = pipColor(0x1D1612).cgColor
        seedBody.lineWidth = 0.8
        let st = CGMutablePath()
        st.move(to: CGPoint(x: 0, y: -3.6))
        st.addLine(to: CGPoint(x: 0, y: 3.6))
        seedStripe.path = st
        seedStripe.fillColor = nil
        seedStripe.strokeColor = pipColor(0xE8E0D0).cgColor
        seedStripe.lineWidth = 0.9
        seed.isHidden = true
        rig.front.addSublayer(seed)
    }

    // MARK: Poses

    /// The stage's right edge in mock x.
    private func edge(_ s: CourierScene) -> CGFloat { PipMac.landing.x + (s.edge.x - s.landing.x) / s.s }

    private func stage(_ P: PipPose, _ s: CourierScene) -> CourierPose {
        let p = s.mock(P.x, P.y)
        var pose = CourierPose(x: p.x, y: p.y)
        pose.sx = P.sx
        pose.sy = P.sy
        pose.rot = -P.rot
        pose.face = abs(P.face) < 0.02 ? (P.face < 0 ? -0.02 : 0.02) : P.face
        pose.alpha = P.alpha
        pose.shadow = K.clamp(1 - max(0, PipMac.GM - P.y) / 40)
        if let c = P.card {
            pose.card = CardCarry(center: s.mock(c.x, c.y), scale: c.s, rot: -c.rot)
        }
        return pose
    }

    func waiting(_ f: CourierFrame, p: CGFloat, ms: Double) -> CourierPose {
        cur = PipMac.wait(p: p, ms: ms, edge: edge(f.scene))
        spr = PipSprings(ear: cur.ear, splay: 0, cheek: 0)
        cur.ear = 0
        return stage(cur, f.scene)
    }

    private func pose(_ f: CourierFrame, T: Double) -> PipPose? {
        let e = edge(f.scene), j = CGFloat(f.plan.jitter)
        guard var P = PipMac.at(T, edge: e, jitter: j) else { return nil }
        spr = PipMac.springs(at: T) { t in
            guard t <= 1080 else { return nil }
            guard let q = PipMac.at(max(0, t), edge: e, jitter: j) else { return nil }
            return CGPoint(x: q.x, y: q.y)
        }
        // The spit: the card copy flies out of the mouth onto its spot, exactly the landed card at L.
        if T >= 440, T < f.plan.landingMS, let wind = PipMac.at(440, edge: e, jitter: j) {
            let m = PipMac.mouth(wind), L = PipMac.landing
            let r = K.easeOut(K.part(T, 440, f.plan.landingMS))
            let ctrl = CGPoint(x: K.mix(m.x, L.x, 0.5), y: min(m.y, L.y) - 52 * j)
            let q = K.qbez(m, ctrl, L, r)
            P.card = (q.x, q.y, K.mix(0.05, 1, r), K.mix(-0.5, 0, r))
        }
        cur = P
        return P
    }

    func arrive(_ f: CourierFrame, T: Double) -> CourierPose {
        guard let P = pose(f, T: T) else { return CourierPose(x: f.scene.size.width + 400, y: f.scene.ground, alpha: 0) }
        return stage(P, f.scene)
    }

    func leave(_ f: CourierFrame, T: Double) -> CourierPose? {
        guard T <= f.plan.goneMS, let P = pose(f, T: T) else { return nil }
        return stage(P, f.scene)
    }

    func sticker(_ f: CourierFrame, ms: Double) -> CourierPose {
        var P = PipPose(x: 0, y: 0)
        P.lookX = -3
        P.pawR = 1
        P.mouth = .smile
        P.tilt = 0.06
        cur = P
        spr = PipSprings()
        return CourierPose(x: 0, y: 0)
    }

    // MARK: Drawing

    func draw(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame) {
        let P = cur, S = PipShapes.self
        // Tumble and stretch about the middle.
        var m = CATransform3DIdentity
        m = CATransform3DTranslate(m, 0, -46, 0)
        if P.vs != 1 { m = CATransform3DScale(m, P.vs, 1 / P.vs, 1) }
        if P.spin != 0 { m = CATransform3DRotate(m, P.spin * P.face, 0, 0, 1) }
        m = CATransform3DTranslate(m, 0, 46, 0)
        if P.breath != 0 { m = CATransform3DScale(m, 1 / (1 + P.breath * 0.6), 1 + P.breath, 1) }
        inner.transform = m

        let lx = P.lookX, ly = P.lookY
        let ch = max(0.8, P.cheek + spr.cheek)
        let TM = PipMac.rotAt(0, -46, P.tilt)
        let ea = P.ear + spr.ear, spl = spr.splay
        func set(_ name: String, _ path: CGPath?) {
            guard let l = rig[name] else { return }
            l.isHidden = path == nil
            if let path { l.path = path }
        }
        // Ears.
        for sx in [CGFloat(-1), 1] {
            let rot = PipMac.rotAt(sx * 24, -76, ea + sx * (spl + 0.12))
            let t = rot.concatenating(TM)
            let ear = S.xf(S.E(sx * 26, -84, 11.5, 10.5), t)
            let inEar = S.xf(S.E(sx * 26, -86, 6.5, 6), t).intersection(ear)
            let side = sx < 0 ? "L" : "R"
            set("o.ear" + side, ear)
            set("ear" + side, ear)
            set("earIn" + side, inEar)
        }
        // Cheeks: they swell and move out as they fill.
        let cx = 34 + (ch - 1) * 8, cr = 12 * ch, cy: CGFloat = -40
        let chL = S.xf(S.E(lx * 0.5 - cx, cy + ly * 0.4, cr, cr * 0.92), TM)
        let chR = S.xf(S.E(lx * 0.5 + cx, cy + ly * 0.4, cr, cr * 0.92), TM)
        set("o.chL", chL); set("o.chR", chR); set("chL", chL); set("chR", chR)
        if ch > 1.08 {
            let arcs = CGMutablePath()
            for sx in [CGFloat(-1), 1] {
                let a0: CGFloat = sx < 0 ? -0.6 : .pi - 0.9, a1: CGFloat = sx < 0 ? 0.9 : .pi + 0.6
                let c = CGPoint(x: lx * 0.5 + sx * cx, y: cy + ly * 0.4)
                let one = CGMutablePath()
                one.addArc(center: c, radius: cr * 0.82, startAngle: a0, endAngle: a1, clockwise: false)
                arcs.addPath(one, transform: TM)
            }
            set("chArcs", arcs)
            rig["chArcs"]?.opacity = Float(0.45 * K.clamp((ch - 1.08) * 4))
        } else { set("chArcs", nil) }

        // The face, tilted with the head.
        set("muzzle", S.xf(S.E(lx, -41 + ly, 15, 10.5), TM))
        let blink = max(f.blink, P.lid)
        for (side, dx, dir) in [("L", CGFloat(-17), CGFloat(1)), ("R", 17, -1)] {
            let e = S.eye(lx + dx, -53 + ly, 5.2, 6.3, P.eyes, blink, lw: lw, dir: dir)
            set("eye" + side, e.fill.map { S.xf($0, TM) })
            set("eyeLine" + side, e.line.map { S.xf($0, TM) })
            rig["eyeLine" + side]?.lineWidth = e.lineWidth
            set("shine" + side, e.shine.map { S.xf($0, TM) })
        }
        let bx = 17 + (ch - 1) * 12
        let blush = CGMutablePath(), dots = CGMutablePath()
        for sx in [CGFloat(-1), 1] {
            let x = lx * 0.5 + sx * (bx + 7), y = -40 + ly
            blush.addPath(S.E(x, y, 7.5, 4.2), transform: TM)
            dots.addPath(S.E(x - 7.5 * 0.35, y - 4.2 * 0.3, 7.5 * 0.22, 4.2 * 0.22), transform: TM)
        }
        set("blush", blush)
        set("blushDot", dots)
        set("nose", S.xf(S.E(lx, -46.5 + ly, 2.9, 2.1), TM))
        let mo = S.mouth(lx, -42.8 + ly + abs(P.chew) * 0.8, P.mouth)
        set("mouthFill", mo.fill.map { S.xf($0, TM) })
        set("tongue", mo.tongue.map { S.xf($0, TM) })
        set("mouthLine", mo.line.map { S.xf($0, TM) })
        let wh = CGMutablePath()
        for sx in [CGFloat(-1), 1] {
            for dy in [CGFloat(-2.5), 2] {
                let one = CGMutablePath()
                one.move(to: CGPoint(x: lx + sx * 12, y: -43 + ly + dy * 0.5))
                one.addQuadCurve(to: CGPoint(x: lx + sx * (36 + P.whisk), y: -46 + ly + dy * 1.6),
                                 control: CGPoint(x: lx + sx * 24, y: -45 + ly + dy))
                wh.addPath(one, transform: TM)
            }
        }
        set("whiskers", wh)
        // Paws, held up to the cheeks.
        let paws = CGMutablePath()
        for (sx, u) in [(CGFloat(-1), P.pawL), (1, P.pawR)] {
            let t = CGAffineTransform(rotationAngle: sx * (25 + u * 25) * .pi / 180)
                .concatenating(CGAffineTransform(translationX: lx * 0.55 + sx * (12 - u * 2), y: -22 - u * 9))
            paws.addPath(S.E(0, 0, 5, 3.9), transform: t)
        }
        set("o.paws", paws)
        set("paws", paws)

        effects(f)
    }

    /// Puffs, the spit's lines and the card's sparkles, from the mockup's `C1.mac`.
    private func effects(_ f: CourierFrame) {
        puffs.forEach { $0.isHidden = true }
        sparkles.forEach { $0.isHidden = true }
        spit.isHidden = true
        seed.isHidden = true
        switch f.moment {
        case .arriving(let T), .leaving(let T): plays(f, T: T)
        default: break
        }
    }

    private func plays(_ f: CourierFrame, T: Double) {
        let s = f.scene
        var used = 0
        func puff(_ x: CGFloat, _ y: CGFloat, _ age: Double, n: Int, dir: Int, spread: CGFloat, seed sd: Double, size: CGFloat) {
            guard age >= 0, age <= 420 else { used += n; return }
            let u = CGFloat(age / 420)
            for i in 0..<n {
                guard used < puffs.count else { return }
                let l = puffs[used]
                used += 1
                let fi = Double(i)
                var a = (CGFloat(hash(sd + fi)) - 0.5) * .pi * 0.9 * spread
                a += dir < 0 ? .pi : dir > 0 ? 0 : -.pi / 2
                if dir == 0 { a += (CGFloat(i) / CGFloat(max(1, n - 1)) - 0.5) * .pi * 1.4 }
                let d = (10 + CGFloat(hash(sd + fi * 3)) * 12) * size * K.easeOut(u * 1.4)
                let r = (3 + CGFloat(hash(fi + sd * 7)) * 3.5) * size * (0.6 + u * 0.9)
                let c = s.mock(x + cos(a) * d, y - abs(sin(a)) * d * 0.55 - u * 6 * size)
                let rs = r * s.s
                l.path = CGPath(ellipseIn: CGRect(x: c.x - rs, y: c.y - rs, width: 2 * rs, height: 2 * rs), transform: nil)
                l.opacity = Float(0.55 * pow(1 - u, 1.4))
                l.isHidden = false
            }
        }
        let HXM = PipMac.HXM, GM = PipMac.GM
        if T >= 200, T < 640 { puff(HXM, GM, T - 200, n: 6, dir: 0, spread: 1, seed: 11, size: 1.1) } else { used += 6 }
        for i in 0..<3 where T > 830 {
            puff(HXM + 20 + CGFloat(i) * 62, GM, T - 860 - Double(i) * 70, n: 3, dir: -1, spread: 0.6, seed: 20 + Double(i), size: 0.7)
        }
        // Ptoo: three short lines from the mouth.
        let j = CGFloat(f.plan.jitter)
        if T >= 440, T < 700, let P = PipMac.at(442, edge: edge(s), jitter: j) {
            let m = PipMac.mouth(P), u = K.part(T, 440, 600)
            let path = CGMutablePath()
            for a in [CGFloat(-2.6), -3.0, -3.4] {
                let r0 = 10 + u * 16, r1 = 18 + u * 22
                path.move(to: s.mock(m.x + cos(a) * r0, m.y + sin(a) * r0))
                path.addLine(to: s.mock(m.x + cos(a) * r1, m.y + sin(a) * r1))
            }
            spit.path = path
            spit.lineWidth = 2.2 * s.s
            spit.opacity = Float(0.7 * (1 - u))
            spit.isHidden = false
        }
        // Sparkles round the landed card.
        if T >= f.plan.landingMS {
            let pts: [(CGFloat, CGFloat, CGFloat, Double)] = [(-0.62, -0.42, 12, 0), (0.6, -0.55, 9, 50), (0.66, 0.3, 7, 95), (-0.5, 0.5, 6, 140)]
            for (i, (dx, dy, size, d)) in pts.enumerated() {
                let age = T - f.plan.landingMS - d
                guard age >= 0, age <= 480 else { continue }
                let u = CGFloat(age / 480)
                let r = size * s.s * (u < 0.3 ? K.easeOut(u / 0.3) : 1 - K.easeIn((u - 0.3) / 0.7))
                let c = s.mock(PipMac.landing.x + dx * 122, PipMac.landing.y + dy * 154)
                let star = CGMutablePath()
                for k in 0..<4 {
                    let a = CGFloat(k) * .pi / 2
                    let tip = CGPoint(x: cos(a) * r, y: sin(a) * r)
                    if k == 0 { star.move(to: tip) } else { star.addLine(to: tip) }
                    star.addQuadCurve(to: CGPoint(x: cos(a + .pi / 4) * r * 0.18, y: sin(a + .pi / 4) * r * 0.18), control: .zero)
                }
                star.closeSubpath()
                star.addPath(CGPath(ellipseIn: CGRect(x: -r * 0.16, y: -r * 0.16, width: r * 0.32, height: r * 0.32), transform: nil))
                var t = CGAffineTransform(rotationAngle: -u * 1.2).concatenating(CGAffineTransform(translationX: c.x, y: c.y))
                sparkles[i].path = star.copy(using: &t)
                sparkles[i].opacity = 0.95
                sparkles[i].isHidden = false
            }
        }
    }

    private func hash(_ n: Double) -> Double {
        let x = sin(n * 127.1 + 311.7) * 43758.5453
        return x - floor(x)
    }

    // MARK: The gag

    /// A sunflower seed drops out of the cheek as Pip turns to go, and bounces.
    func gag(_ rig: CourierRig, _ f: CourierFrame, T: Double) {
        guard T > 780, T < 1150 else { seed.isHidden = true; return }
        let s = f.scene, GM = PipMac.GM
        let age = T - 800, sec = CGFloat(max(0, age) / 1000)
        let x0 = PipMac.HXM + 20, y0 = GM - 34
        let y = y0 + 600 * sec * sec
        var yy = min(y, GM - 3)
        if y > GM - 3 {
            let a2 = age - Double(sqrt((GM - 3 - y0) / 600)) * 1000
            yy = GM - 3 - max(0, 22 * K.kick(a2, f: 3, z: 0.4) * 1.4)
        }
        let p = s.mock(x0 - CGFloat(age) * 0.03, yy)
        seed.position = p
        let k = 1.3 * s.s
        seed.setAffineTransform(CGAffineTransform(scaleX: k, y: -k).rotated(by: CGFloat(age) * 0.01))
        seed.opacity = Float(1 - K.part(T, 1050, 1150))
        seed.isHidden = false
    }

    // MARK: Sounds

    func cues(_ plan: CourierPlan) -> [CourierCue] {
        var c = [CourierCue(ms: 30, name: "roll"), CourierCue(ms: 200, name: "plant"), CourierCue(ms: 300, name: "inhale"),
                 CourierCue(ms: 440, name: "ptoo"), CourierCue(ms: 590, name: "squeak")]
        if !plan.short { c.append(CourierCue(ms: 860, name: "patter")) }
        if plan.gag { c.append(CourierCue(ms: 1028, name: "seed")) }
        return c
    }

    func sound(_ cue: String) -> [Double]? { PipSound.samples(cue) }
}

// MARK: - Pip's own sounds (synthesised, 44.1 kHz; the landing sound stays PortalSound's)

enum PipSound {
    static let rate = 44_100.0

    static func samples(_ cue: String) -> [Double]? {
        switch cue {
        case "roll":
            // A soft rolling rumble: low noise, swelling and gone.
            var n = Noise(seed: 3), lp = 0.0
            return tone(0.16) { t in
                lp += (n.next() - lp) * 0.06
                return 0.5 * lp * sin(.pi * t / 0.16)
            }
        case "plant":
            // A little thump as it lands on its feet.
            return tone(0.09) { t in
                let ph = 2 * .pi * (150 * t - 300 * t * t)
                return 0.6 * sin(ph) * env(t, 0.003, 0.025)
            }
        case "inhale":
            // A tiny wind-up sniff: rising airy noise.
            var n = Noise(seed: 9), lp = 0.0
            return tone(0.12) { t in
                lp += (n.next() - lp) * (0.15 + t * 2)
                return 0.18 * lp * (t / 0.12) * (t < 0.11 ? 1 : (0.12 - t) / 0.01)
            }
        case "ptoo":
            // "P": a puff of air; "too": a round pop sliding down.
            var n = Noise(seed: 5)
            return tone(0.14) { t in
                let burst = n.next() * env(t, 0.001, 0.006) * 0.45
                let a = t - 0.008
                guard a > 0 else { return burst }
                let ph = 2 * .pi * (620 * a - 1400 * a * a)
                return burst + 0.55 * (sin(ph) + 0.25 * sin(2 * ph)) / 1.25 * env(a, 0.004, 0.045)
            }
        case "squeak":
            // A proud little chirp.
            return tone(0.09) { t in
                let ph = 2 * .pi * (1900 * t + 5000 * t * t)
                return 0.22 * sin(ph) * env(t, 0.006, 0.03)
            }
        case "patter":
            // Four quick paw steps.
            var n = Noise(seed: 13)
            return tone(0.2) { t in
                var s = 0.0
                for i in 0..<4 {
                    let a = t - Double(i) * 0.045
                    guard a >= 0 else { continue }
                    s += (0.6 * sin(2 * .pi * 900 * a) + 0.4 * n.next()) * env(a, 0.001, 0.007)
                }
                return 0.25 * s
            }
        case "seed":
            // Tik, tik: a seed bouncing.
            return tone(0.16) { t in
                var s = 0.0
                for (at, v) in [(0.0, 1.0), (0.09, 0.5)] {
                    let a = t - at
                    guard a >= 0 else { continue }
                    s += v * sin(2 * .pi * 2600 * a) * env(a, 0.0005, 0.006)
                }
                return 0.3 * s
            }
        default:
            return nil
        }
    }

    private static func tone(_ seconds: Double, _ f: (Double) -> Double) -> [Double] {
        return (0..<Int(seconds * rate)).map { f(Double($0) / rate) }
    }

    private static func env(_ t: Double, _ attack: Double, _ decay: Double) -> Double {
        t < 0 ? 0 : t < attack ? t / attack : exp(-(t - attack) / decay)
    }

    /// White noise from a seed, -1 … 1.
    struct Noise {
        var s: UInt32
        init(seed: UInt32) { s = seed &* 2_654_435_761 | 1 }
        mutating func next() -> Double {
            s ^= s << 13
            s ^= s >> 17
            s ^= s << 5
            return Double(s) / 2_147_483_648 - 1
        }
    }
}
