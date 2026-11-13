//
//  MatchaCourier.swift
//  DropPortal
//
//  The Matcha Trio on the Mac (Duckling Parade): matcha-green ducklings in
//  navy mail caps with a coral band, the approved mockup's `drawDuck` rig
//  (`.droppykit/design/fx-mockups-cute-v2/mockups.html`) as layers, one
//  duckling per file (three to five, `CourierPlan.actors`).
//
//  - Waiting: one beak per duckling the phone shows peeks in from the right
//    edge, stacked, popping in at `Courier.ducklingStart`, breathing and bobbing.
//  - Arrival (T 0 … L): the peekers duck back out while the parade marches in
//    from the right edge with the card balanced on their caps, each waddling on
//    its own phase and period; all stop at once (squash 1.2), stretch and toss
//    the card onto its spot on a 24 pt arc, exactly the landed card at L.
//  - After L: a quack chord (beaks open 40 ms apart, three rising pitches, wings
//    flap, notes rise, one blink each), then each turns and waddles out of the
//    right edge 60 ms after the one before.
//  - The gag (1 in 4, `plan.gag`): the last duckling, the clumsy one, trips
//    while marching in, pitches forward, its cap pops up, and it catches up.
//    It plays in `arrive` (the frame carries the plan), not in `gag`.
//  - Cap, tail tuft and wings lag the body on springs integrated over the last
//    300 ms of the pose, so a still renders the same as the live frame.
//
//  Positions are worked out in the mockup's Mac units (y down, the landed card
//  at 660, 204, ground 336) and mapped with `scene.mock`; the ducklings draw at
//  the stage's own unit (16% larger than the mockup's 0.74) so they read at
//  Mac size.
//

import AppKit
import DropPortalCore

@MainActor
final class MatchaCourier: CourierCharacter {
    let courier: Courier = .ducks

    // MARK: Look

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private let ink = rgb(0x2F3A24), green = rgb(0xA8D08D), shade = rgb(0x86B36C), cream = rgb(0xFFF6EA)
    private let coral = rgb(0xFF8A65), coralShade = rgb(0xE8704C), cap = rgb(0x2B3A5C), capShade = rgb(0x1F2B47)
    /// Outline, drawing units (the union outline shows this much outside the fills).
    private let lw: CGFloat = 1.9
    /// Mockup px per drawing unit: the stage's own unit (0.86), up from the mockup's 0.74.
    private let k: CGFloat = 0.86
    private static let maxDucks = Courier.ducklingRange.upperBound
    private static let ground: CGFloat = 336

    // MARK: State of one frame

    enum Eyes { case open, happy, squeeze }

    /// One duckling: feet in mockup units (y down), the rig's moves.
    struct Duck {
        var x: CGFloat
        var y: CGFloat
        var k: CGFloat
        var sx: CGFloat = 1, sy: CGFloat = 1
        var rot: CGFloat = 0
        var face: CGFloat = 1
        var step: CGFloat = 0
        var tilt: CGFloat = 0
        var jaw: CGFloat = 0
        var wing: CGFloat = 0
        var eyes: Eyes = .open
        var blink: CGFloat = 0
        var capTurn: CGFloat = 0
        var capLift: CGFloat = 0
        var tail: CGFloat = 0
        var alpha: CGFloat = 1
        var shadow: CGFloat = 1
    }

    /// The parade's spots on this stage, mockup units.
    struct Lay {
        var n: Int
        var rest: [CGFloat]
        /// The right screen edge.
        var edge: CGFloat
        var cardH: CGFloat
        /// The peekers' vertical spacing.
        var stack: CGFloat
        /// From off the edge to the spots.
        var march: CGFloat { edge - rest[0] + 92 }
        var middle: CGFloat { rest.reduce(0, +) / CGFloat(n) }
    }

    private var marchers: [Duck?] = []
    private var peekers: [Duck?] = []
    /// Puffs (x, y, age, seed) and notes (x, y, alpha), mockup units.
    private var puffs: [(CGFloat, CGFloat, Double, Int)] = []
    private var notes: [(CGFloat, CGFloat, CGFloat)] = []
    /// The anchor `rig.body` stands on, mockup units.
    private var anchor = CGPoint(x: 660, y: ground)
    private var stickerMode = false

    private var shadowLayers: [CAGradientLayer] = []
    private var puffLayers: [CAShapeLayer] = []
    private var noteLayers: [CAShapeLayer] = []

    // MARK: Build

    func build(_ rig: CourierRig) {
        for _ in 0..<Self.maxDucks {
            let s = CAGradientLayer()
            s.type = .radial
            s.colors = [NSColor(white: 0, alpha: 0.28), NSColor(white: 0, alpha: 0.16), NSColor(white: 0, alpha: 0)].map(\.cgColor)
            s.locations = [0, 0.55, 1]
            s.startPoint = CGPoint(x: 0.5, y: 0.5)
            s.endPoint = CGPoint(x: 1, y: 1)
            s.actions = CourierKit.noActions
            s.isHidden = true
            rig.behind.addSublayer(s)
            shadowLayers.append(s)
        }
        for _ in 0..<(3 * Self.maxDucks) {
            let p = CAShapeLayer()
            p.actions = CourierKit.noActions
            p.fillColor = NSColor(srgbRed: 1, green: 0.98, blue: 0.94, alpha: 1).cgColor
            p.isHidden = true
            rig.behind.addSublayer(p)
            puffLayers.append(p)
        }
        for _ in 0..<Self.maxDucks {
            let n = CAShapeLayer()
            n.actions = CourierKit.noActions
            n.fillColor = cap.cgColor
            n.strokeColor = NSColor.white.cgColor
            n.lineWidth = 1.6
            n.lineJoin = .round
            n.isHidden = true
            rig.front.addSublayer(n)
            noteLayers.append(n)
        }
        // Peekers first (behind), then the parade, the rightmost (back of the march) furthest back.
        for i in (0..<Self.maxDucks).reversed() { buildDuck(rig, "w\(i)") }
        for i in (0..<Self.maxDucks).reversed() { buildDuck(rig, "d\(i)") }
    }

    private func E(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ r: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: x, y: y).rotated(by: r)
        return CGPath(ellipseIn: CGRect(x: -max(0.01, rx), y: -max(0.01, ry), width: 2 * max(0.01, rx), height: 2 * max(0.01, ry)), transform: &t)
    }

    private func moved(_ p: CGPath, _ t: CGAffineTransform) -> CGPath {
        var t = t
        return p.copy(using: &t) ?? p
    }

    private func rotAt(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: x, y: y).rotated(by: a).translatedBy(x: -x, y: -y)
    }

    private var bodyPath: CGPath { E(8, -26, 30, 22) }
    private var headPath: CGPath { E(-8, -57, 24.5, 23.5) }
    private var tuftPath: CGPath { moved(E(0, 0, 8.5, 5.6), CGAffineTransform(translationX: 35, y: -36).rotated(by: -0.7)) }
    private var wingPath: CGPath { moved(E(15, -28, 13.5, 8.6), rotAt(5, -31, -0.22)) }
    private func foot(_ x: CGFloat) -> CGPath { E(x - 4, -3, 7.5, 3.6) }

    private var beakUp: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -28, y: -54.5))
        p.addCurve(to: CGPoint(x: -42, y: -49.5), control1: CGPoint(x: -36, y: -56), control2: CGPoint(x: -43, y: -53))
        p.addCurve(to: CGPoint(x: -28, y: -47.2), control1: CGPoint(x: -41, y: -46.5), control2: CGPoint(x: -34, y: -46))
        p.closeSubpath()
        return p
    }

    private var beakLo: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -28, y: -47.6))
        p.addCurve(to: CGPoint(x: -38.5, y: -44.4), control1: CGPoint(x: -34, y: -47.2), control2: CGPoint(x: -39, y: -46.6))
        p.addCurve(to: CGPoint(x: -28, y: -44.4), control1: CGPoint(x: -37.8, y: -42.2), control2: CGPoint(x: -32, y: -42.6))
        p.closeSubpath()
        return p
    }

    private var crown: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -23, y: -74))
        p.addCurve(to: CGPoint(x: -4, y: -92), control1: CGPoint(x: -23, y: -90), control2: CGPoint(x: -8, y: -92))
        p.addCurve(to: CGPoint(x: 12, y: -74), control1: CGPoint(x: 4, y: -92), control2: CGPoint(x: 12, y: -88))
        p.closeSubpath()
        return p
    }

    private func clear(_ rig: CourierRig, _ name: String, pivot: CGPoint = .zero, in parent: CALayer) -> CAShapeLayer {
        rig.part(name, CGMutablePath(), fill: .clear, ink: nil, width: 0, pivot: pivot, in: parent)
    }

    /// One duckling's parts, the mockup's paint order: feet, the union outline
    /// of tuft, body and head, the fills and shades, the wing, then the head
    /// (beak, eyes, blush, cap) in a group that tilts.
    private func buildDuck(_ rig: CourierRig, _ n: String) {
        let g = clear(rig, n, in: rig.body)
        let outline = lw * 2
        rig.part(n + ".f2", foot(12), fill: coralShade, ink: ink, width: lw, pivot: CGPoint(x: 12, y: -3), in: g)
        rig.part(n + ".f1", foot(-4), fill: coral, ink: ink, width: lw, pivot: CGPoint(x: -4, y: -3), in: g)
        rig.part(n + ".tuftO", tuftPath, fill: ink, ink: ink, width: outline, pivot: CGPoint(x: 35, y: -36), in: g)
        rig.part(n + ".bodyO", bodyPath, fill: ink, ink: ink, width: outline, in: g)
        let headO = clear(rig, n + ".hO", pivot: CGPoint(x: -2, y: -40), in: g)
        rig.part(n + ".headO", headPath, fill: ink, ink: ink, width: outline, in: headO)
        rig.part(n + ".tuft", tuftPath, fill: green, ink: nil, width: 0, pivot: CGPoint(x: 35, y: -36), in: g)
        rig.part(n + ".body", bodyPath, fill: shade, ink: nil, width: 0, in: g)
        let body = bodyPath
        rig.part(n + ".bodyLit", body.intersection(moved(body, CGAffineTransform(translationX: -4, y: -5))), fill: green, ink: nil, width: 0, in: g)
        rig.part(n + ".belly", body.intersection(E(-4, -12, 21, 13)), fill: cream, ink: nil, width: 0, in: g)
        let wing = rig.part(n + ".wing", wingPath, fill: shade, ink: ink, width: lw * 0.75, pivot: CGPoint(x: 5, y: -31), in: g)
        rig.part(n + ".wingHi", wingPath.intersection(E(12, -31, 10, 4)), fill: Self.rgb(0xA7CB90), ink: nil, width: 0,
                 pivot: CGPoint(x: 5, y: -31), in: wing)
        let h = clear(rig, n + ".h", pivot: CGPoint(x: -2, y: -40), in: g)
        let head = headPath
        rig.part(n + ".head", head, fill: shade, ink: nil, width: 0, in: h)
        rig.part(n + ".headLit", head.intersection(moved(head, CGAffineTransform(translationX: -4, y: -4))), fill: green, ink: nil, width: 0, in: h)
        rig.part(n + ".hilite", E(-18, -69, 7, 4, -0.6), fill: NSColor(white: 1, alpha: 0.5), ink: nil, width: 0, in: h)
        rig.part(n + ".mouth", CGMutablePath(), fill: Self.rgb(0x7A2E22), ink: nil, width: 0, in: h)
        rig.part(n + ".loO", beakLo, fill: ink, ink: ink, width: lw * 1.6, pivot: CGPoint(x: -28, y: -47), in: h)
        rig.part(n + ".upO", beakUp, fill: ink, ink: ink, width: lw * 1.6, in: h)
        rig.part(n + ".lo", beakLo, fill: coralShade, ink: nil, width: 0, pivot: CGPoint(x: -28, y: -47), in: h)
        rig.part(n + ".up", beakUp, fill: coral, ink: nil, width: 0, in: h)
        rig.part(n + ".nostril", E(-37, -52, 2.2, 1), fill: Self.rgb(0xFFC2A8), ink: nil, width: 0, in: h)
        for e in ["eL", "eR"] {
            rig.part(n + "." + e, CGMutablePath(), fill: ink, ink: ink, width: 0, in: h)
            rig.part(n + "." + e + "g", CGMutablePath(), fill: .white, ink: nil, width: 0, in: h)
        }
        let blushA = CGMutablePath(), dots = CGMutablePath()
        for (x, y, rx, ry) in [(-15.0, -47.5, 4.8, 2.8), (7.0, -48.5, 4.4, 2.6)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            blushA.addPath(E(x, y, rx, ry))
            dots.addPath(E(x - rx * 0.35, y - ry * 0.3, rx * 0.22, ry * 0.22))
        }
        rig.part(n + ".blush", blushA, fill: Self.rgb(0xFF9FB2, 0.72), ink: nil, width: 0, in: h)
        rig.part(n + ".blushDot", dots, fill: NSColor(white: 1, alpha: 0.42), ink: nil, width: 0, in: h)
        // The mail cap, on a spring about the brow.
        let c = clear(rig, n + ".cap", pivot: CGPoint(x: -6, y: -75), in: h)
        let visor = E(-26, -74, 10.5, 2.8, -0.12)
        rig.part(n + ".visorO", visor, fill: ink, ink: ink, width: lw * 1.7, in: c)
        rig.part(n + ".crownO", crown, fill: ink, ink: ink, width: lw * 1.7, in: c)
        rig.part(n + ".visor", visor, fill: capShade, ink: nil, width: 0, in: c)
        rig.part(n + ".crown", crown, fill: cap, ink: nil, width: 0, in: c)
        rig.part(n + ".band", CGPath(roundedRect: CGRect(x: -23.5, y: -79, width: 36, height: 5), cornerWidth: 2, cornerHeight: 2, transform: nil),
                 fill: coral, ink: nil, width: 0, in: c)
        rig.part(n + ".button", E(-12, -86, 4, 2, -0.4), fill: Self.rgb(0x4B5D8A), ink: nil, width: 0, in: c)
        rig.part(n + ".pom", E(-4, -92, 2.6, 2), fill: coral, ink: nil, width: 0, in: c)
    }

    // MARK: Layout

    private func lay(_ s: CourierScene, n: Int) -> Lay {
        let edge = 660 + (s.size.width - s.landing.x) / s.s
        let cardR = 660 + s.card.width / 2 / s.s
        let first = cardR + 40 * k / 0.86
        let room = edge - 44 - first
        let sp: CGFloat = n > 1 ? min(56, max(36, room / CGFloat(n - 1))) : 0
        var x0 = first
        let over = x0 + sp * CGFloat(n - 1) + 44 - edge
        if over > 0 { x0 -= over }
        let rest = (0..<n).map { x0 + sp * CGFloat($0) }
        let stack: CGFloat = n <= 3 ? 66 : min(66, 210 / CGFloat(n - 1))
        return Lay(n: n, rest: rest, edge: edge, cardH: s.card.height / s.s, stack: stack)
    }

    private func clamp(_ v: CGFloat, _ a: CGFloat = 0, _ b: CGFloat = 1) -> CGFloat { min(b, max(a, v)) }
    private func seg(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { CourierKit.part(t, a, b) }
    private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func sat(_ x: CGFloat, _ m: CGFloat) -> CGFloat { m * tanh(x / m) }
    private func hash(_ n: Double) -> CGFloat { let x = sin(n * 127.1 + 311.7) * 43758.5453; return CGFloat(x - floor(x)) }

    /// Each duckling's own waddle: a phase lag and a period, so the parade is never in lock-step.
    private func waddle(_ i: Int, _ T: Double, seed: UInt32) -> Double {
        let periods: [Double] = [120, 113, 127, 117, 124]
        let lag = Double(i) * 31 + Double(hash(Double(seed % 997) + Double(i))) * 22
        return (T - lag) / periods[i % periods.count] * 2 * .pi
    }

    private func blink(_ plan: CourierPlan, _ ms: Double, _ i: Int) -> CGFloat {
        CourierKit.blink(plan, at: ms + Double(i) * 577 + 3000)
    }

    // MARK: Waiting (the phone holds the card)

    private func peeker(_ i: Int, _ L: Lay, p: CGFloat, ms: Double, plan: CourierPlan) -> Duck? {
        let st = CGFloat(Courier.ducklingStart(i, of: L.n))
        let a = CourierKit.easeOut((p - st) / 0.15)
        guard a > 0 else { return nil }
        let kw = k * 0.9, r = kw / 0.74
        var d = Duck(x: L.edge + 40 * r - a * 24 * r, y: Self.ground - CGFloat(i) * L.stack, k: kw)
        let pop = CourierKit.backOut((p - st) / 0.12, 2.6)
        let breath = 0.02 * sin(2 * .pi * ms / 1700 + Double(i))
        d.sx = pop / (1 + CGFloat(breath) * 0.6)
        d.sy = pop * (1 + CGFloat(breath))
        d.rot = -0.22 - 0.1 * CourierKit.easeInOut((p - 0.85) / 0.15)
        d.tilt = 0.05 + 0.06 * CGFloat(sin(2 * .pi * ms / 3000 + Double(i) * 1.7))
        d.y += 1.6 * CGFloat(sin(2 * .pi * 1.3 * ms / 1000 + Double(i) * 2.1))
        d.wing = 0.4 * CourierKit.kick(Double(p - st) * 600, f: 6, z: 0.3)
        d.capTurn = -0.12 * CourierKit.kick(Double(p - st) * 600, f: 4, z: 0.3)
        d.blink = blink(plan, ms, i)
        d.shadow = 0
        return d
    }

    func waiting(_ f: CourierFrame, p: CGFloat, ms: Double) -> CourierPose {
        let L = lay(f.scene, n: f.plan.actors)
        peekers = (0..<Self.maxDucks).map { $0 < L.n ? peeker($0, L, p: p, ms: ms, plan: f.plan) : nil }
        marchers = Array(repeating: nil, count: Self.maxDucks)
        puffs = []
        notes = []
        return pose(f, L, card: nil)
    }

    // MARK: The parade

    /// Duckling `i` at T on the plan's clock, without springs.
    private func marcher(_ i: Int, _ T: Double, _ L: Lay, _ plan: CourierPlan) -> Duck? {
        let rest = L.rest[i], last = i == L.n - 1, ground = Self.ground
        var d = Duck(x: rest, y: ground, k: k)
        let jit = CGFloat(plan.jitter)
        if T < 360 {
            let u = seg(T, 0, 360), s = CourierKit.decel(u), ph = waddle(i, T, seed: plan.seed)
            let amp = 1 - CourierKit.easeIn(seg(T, 250, 360))
            d.x = mix(rest + L.march, rest, s)
            d.rot = (last ? 0.17 : 0.14) * CGFloat(sin(ph)) * amp * jit
            d.step = CGFloat(sin(ph)) * amp
            d.y = ground - 2.8 * abs(CGFloat(sin(ph))) * amp * jit
            d.sx = 1 + 0.07 * (1 - u) * (1 - u)
            d.sy = 1 / d.sx
            if plan.gag, last { trip(&d, T) }
            return d
        }
        if T < 420 {
            let s = mix(1, 1.2, CourierKit.easeOut(seg(T, 360, 400)))
            d.sx = s
            d.sy = 1 / s
            return d
        }
        let back = T < 470 ? mix(1.2, 0.87, CourierKit.easeOut(seg(T, 420, 470))) : 1 + (0.87 - 1) * CourierKit.settle(T - 470, f: 3.4, z: 0.5)
        d.sx = back
        d.sy = 1 / back
        if T < 560 {
            d.tilt = 0.15 * sin(.pi * seg(T, 420, 520))
            d.wing = 0.3 * sin(.pi * seg(T, 420, 500))
            return d
        }
        if T < 760 {
            let q0 = T - 560 - Double(i) * 40
            d.jaw = q0 > 0 && q0 < 130 ? CGFloat(sin(.pi * q0 / 130)) : 0
            d.wing = 0.35 * sin(2 * .pi * seg(T, 560 + Double(i) * 40, 760 + Double(i) * 40))
            d.eyes = d.jaw > 0.2 ? .happy : .open
            d.tilt = 0.1 * d.jaw
            return d
        }
        // Turn round and waddle out of the right edge, 60 ms apart.
        let t0 = 760 + Double(i) * 60, end = exitEnd(i, plan)
        guard T <= end else { return nil }
        let tu = seg(T, t0, t0 + 80)
        d.sx = 1
        d.sy = 1
        d.face = cos(.pi * CourierKit.easeInOut(tu))
        d.y = ground - 6 * sin(.pi * tu)
        if T > t0 + 70 {
            let u = seg(T, t0 + 70, end), s = CourierKit.curveA(u), ph = waddle(i, T - t0, seed: plan.seed)
            d.face = -1
            d.x = rest + (L.edge + 64 - L.rest[0]) * s
            d.rot = 0.14 * CGFloat(sin(ph))
            d.step = CGFloat(sin(ph))
            d.y = ground - 2.6 * abs(CGFloat(sin(ph)))
        }
        return d
    }

    private func exitEnd(_ i: Int, _ plan: CourierPlan) -> Double {
        courier.goneMS + 60 * Double(max(0, i - 2))
    }

    /// The gag: the last duckling's foot catches at T 200, it pitches forward,
    /// its cap pops up, and it scrambles back into step by T 340.
    private func trip(_ d: inout Duck, _ T: Double) {
        guard T > 195, T < 360 else { return }
        let fall = CourierKit.easeOut(seg(T, 195, 235))
        let rise = T < 250 ? 1 : CourierKit.settle(T - 250, f: 4, z: 0.45)
        d.rot = -0.55 * fall * rise
        d.x += 18 * sin(.pi * seg(T, 195, 345))
        d.y = Self.ground - 3 * sin(.pi * seg(T, 250, 300))
        d.step = T < 250 ? -1 : d.step
        d.eyes = T < 290 ? .squeeze : .open
        d.capLift = 9 * sin(.pi * seg(T, 200, 300))
        d.capTurn = -0.45 * sin(.pi * seg(T, 200, 310))
        d.wing = 0.55 * sin(.pi * seg(T, 200, 290))
        d.jaw = 0.6 * sin(.pi * seg(T, 205, 260))
    }

    /// Cap, tail and wing lag the body: springs pushed by the duckling's
    /// acceleration over the last 300 ms (the mockup's GAINS).
    private func springs(_ i: Int, _ T: Double, _ L: Lay, _ plan: CourierPlan) -> (cap: CGFloat, tail: CGFloat, ear: CGFloat) {
        let specs: [(Double, Double, Double, CGFloat)] = [(4, 0.3, -0.022, 0.4), (3.2, 0.3, -0.018, 0.6), (4.5, 0.28, -0.028, 0.55)]
        var x = [Double](repeating: 0, count: 3), v = x
        let dt = 6.0, h = 8.0
        var t = max(0, T - 300)
        func px(_ t: Double) -> Double? { marcher(i, t, L, plan).map { Double($0.x) } }
        while t + dt <= T {
            if let a = px(t - h), let b = px(t), let c = px(t + h) {
                let acc = max(-60000, min(60000, (a - 2 * b + c) / (h * h) * 1e6))
                for j in 0..<3 {
                    let (f, z, gain, _) = specs[j], w = 2 * .pi * f
                    let force = gain * acc - w * w * x[j] - 2 * z * w * v[j]
                    v[j] += force * dt / 1000
                    x[j] += v[j] * dt / 1000
                }
            }
            t += dt
        }
        return (sat(CGFloat(x[0]), specs[0].3), sat(CGFloat(x[1]), specs[1].3), sat(CGFloat(x[2]), specs[2].3))
    }

    private func parade(_ T: Double, _ f: CourierFrame, _ L: Lay) {
        let plan = f.plan, clockMS = 600 + T
        marchers = (0..<Self.maxDucks).map { i -> Duck? in
            guard i < L.n, var d = marcher(i, T, L, plan) else { return nil }
            let sp = springs(i, T, L, plan)
            d.capTurn += sp.cap
            d.tail = sp.tail
            d.wing += sp.ear * 0.4
            var b = blink(plan, clockMS, i)
            if T >= 690, T < 760 { b = max(b, CGFloat(CourierPlan.lid(T - 700 - Double(i) * 15))) }
            if d.eyes == .open { d.blink = b }
            return d
        }
        // The peekers duck back out as the parade comes in.
        if T < 60 {
            let out = CourierKit.easeIn(seg(T, 0, 60)) * 40
            peekers = (0..<Self.maxDucks).map { i -> Duck? in
                guard i < L.n, var d = peeker(i, L, p: 1, ms: clockMS, plan: plan) else { return nil }
                d.x += out
                d.y += 2 * CGFloat(sin(2 * .pi * 4 * T / 1000 + Double(i) * .pi))
                return d
            }
        } else {
            peekers = Array(repeating: nil, count: Self.maxDucks)
        }
        puffs = []
        notes = []
        if T >= 360, T < 780 {
            for i in 0..<L.n { puffs.append((L.rest[i], Self.ground, T - 360 - Double(i) * 10, 40 + i)) }
        }
        if T >= 560, T < 860 {
            for i in 0..<L.n {
                let q0 = T - 560 - Double(i) * 40
                guard q0 > 0, q0 < 260, let d = marchers[i] else { continue }
                notes.append((d.x - 36 - CGFloat(q0) * 0.05, Self.ground - 92 - CGFloat(q0) * 0.1 - CGFloat(i) * 4, 1 - CGFloat(q0 / 260)))
            }
        }
    }

    /// The card on the parade's caps (before the toss), mockup units, y down.
    private func onCaps(_ T: Double, _ L: Lay, _ plan: CourierPlan) -> (x: CGFloat, y: CGFloat, rot: CGFloat) {
        // Carried by the ones that are not tripping: the middle of the line.
        var xs: [CGFloat] = [], ys: [CGFloat] = [], sy: CGFloat = 1
        for i in 0..<L.n {
            guard let d = marcher(i, T, L, plan) else { continue }
            if plan.gag, i == L.n - 1, L.n > 1, T > 195, T < 345 { continue }
            xs.append(d.x)
            ys.append(d.y)
            sy = d.sy
        }
        guard !xs.isEmpty else { return (L.middle, Self.ground, 0) }
        let x = xs.reduce(0, +) / CGFloat(xs.count) - 2
        let top = ys.reduce(0, +) / CGFloat(ys.count) - 92 * k * sy
        let ph = waddle(1, T, seed: plan.seed), amp = T < 360 ? 1 - CourierKit.easeIn(seg(T, 250, 360)) : 0
        var rot = 0.025 * CGFloat(sin(ph * 0.5)) * amp
        if plan.gag { rot += 0.07 * sin(.pi * seg(T, 200, 340)) }
        return (x, top - L.cardH / 2 + 3 + 3 * CGFloat(sin(ph)) * amp, rot)
    }

    func arrive(_ f: CourierFrame, T: Double) -> CourierPose {
        let s = f.scene, L = lay(s, n: f.plan.actors), Lms = f.plan.landingMS
        parade(T, f, L)
        let carry: CardCarry
        if T < 420 {
            let c = onCaps(T, L, f.plan)
            carry = CardCarry(center: s.mock(c.x, c.y), scale: 1, rot: -c.rot)
        } else {
            // The toss: off their caps on a 24 pt arc onto the spot, exactly the landed card at L.
            let a = onCaps(419, L, f.plan), e = CourierKit.easeInOut(seg(T, 420, Lms))
            let q = CourierKit.qbez(CGPoint(x: a.x, y: a.y), CGPoint(x: mix(a.x, 660, 0.5), y: min(a.y, 204) - 24 * 1.4), CGPoint(x: 660, y: 204), e)
            let rot = mix(a.rot, 0, e) - 0.12 * sin(.pi * e)
            carry = CardCarry(center: T >= Lms ? s.landing : s.mock(q.x, q.y), scale: 1, rot: T >= Lms ? 0 : -rot)
        }
        return pose(f, L, card: carry)
    }

    func leave(_ f: CourierFrame, T: Double) -> CourierPose? {
        let L = lay(f.scene, n: f.plan.actors)
        guard T <= exitEnd(L.n - 1, f.plan) else { return nil }
        parade(T, f, L)
        guard marchers.contains(where: { $0 != nil }) else { return nil }
        return pose(f, L, card: nil)
    }

    private func pose(_ f: CourierFrame, _ L: Lay, card: CardCarry?) -> CourierPose {
        stickerMode = false
        anchor = CGPoint(x: L.middle, y: Self.ground)
        let at = f.scene.mock(anchor.x, anchor.y)
        var pose = CourierPose(x: at.x, y: at.y)
        pose.shadow = 0
        pose.card = card
        return pose
    }

    // MARK: Reduce motion

    func sticker(_ f: CourierFrame, ms: Double) -> CourierPose {
        stickerMode = true
        let n = f.plan.actors
        anchor = .zero
        marchers = (0..<Self.maxDucks).map { i -> Duck? in
            guard i < n else { return nil }
            var d = Duck(x: CGFloat(i) * 50 * k, y: 0, k: k)
            d.tilt = 0.05 * CGFloat(i - 1)
            d.blink = f.blink
            d.shadow = 0
            return d
        }
        peekers = Array(repeating: nil, count: Self.maxDucks)
        puffs = []
        notes = []
        var pose = CourierPose(x: 0, y: 0)
        pose.scale = 0.95
        return pose
    }

    // MARK: Draw

    func draw(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame) {
        for i in 0..<Self.maxDucks {
            apply(rig, "d\(i)", i < marchers.count ? marchers[i] : nil)
            apply(rig, "w\(i)", i < peekers.count ? peekers[i] : nil)
        }
        let s = f.scene
        for (i, layer) in shadowLayers.enumerated() {
            guard !stickerMode, i < marchers.count, let d = marchers[i], d.shadow > 0 else { layer.isHidden = true; continue }
            let w = 34 * s.s * d.k / 0.74 * (1 - min(0.5, max(0, Self.ground - d.y) / 60))
            layer.isHidden = false
            layer.bounds = CGRect(x: 0, y: 0, width: 2 * w, height: 0.48 * w)
            layer.position = s.mock(d.x + 3, Self.ground + 1)
            layer.opacity = Float(d.shadow * d.alpha)
        }
        // Dust puffs as they stop: three each, the mockup's `puffs`.
        for (j, layer) in puffLayers.enumerated() {
            let pi = j / 3, q = j % 3
            guard pi < puffs.count, puffs[pi].2 >= 0, puffs[pi].2 <= 420 else { layer.isHidden = true; continue }
            let (x, y, age, seed) = puffs[pi], u = CGFloat(age / 420), size: CGFloat = 0.7 * k / 0.74
            let sd = Double(seed), qd = Double(q)
            let a = (hash(sd + qd) - 0.5) * .pi * 0.9 * 0.7 - .pi / 2 + (CGFloat(q) / 2 - 0.5) * .pi * 1.4
            let dist = (10 + hash(sd + qd * 3) * 12) * size * CourierKit.easeOut(u * 1.4)
            let r = (3 + hash(qd + sd * 7) * 3.5) * size * (0.6 + u * 0.9)
            let c = s.mock(x + cos(a) * dist, y - abs(sin(a)) * dist * 0.55 - u * 6 * size)
            let rr = r * s.s
            layer.isHidden = false
            layer.path = CGPath(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr), transform: nil)
            layer.opacity = Float(0.55 * pow(1 - u, 1.4))
        }
        for (j, layer) in noteLayers.enumerated() {
            guard j < notes.count else { layer.isHidden = true; continue }
            let (x, y, a) = notes[j], c = s.mock(x, y)
            layer.isHidden = false
            layer.path = note(at: c, size: 13 * s.s)
            layer.opacity = Float(a)
        }
    }

    /// A quaver: head, stem and flag, y up.
    private func note(at c: CGPoint, size h: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addPath(CGPath(ellipseIn: CGRect(x: c.x - h * 0.34, y: c.y - h * 0.5, width: h * 0.42, height: h * 0.3), transform: nil))
        p.addRect(CGRect(x: c.x + 0.02 * h, y: c.y - h * 0.38, width: h * 0.08, height: h * 0.86))
        p.move(to: CGPoint(x: c.x + 0.1 * h, y: c.y + h * 0.48))
        p.addQuadCurve(to: CGPoint(x: c.x + h * 0.34, y: c.y + h * 0.08), control: CGPoint(x: c.x + h * 0.4, y: c.y + h * 0.36))
        p.addLine(to: CGPoint(x: c.x + h * 0.1, y: c.y + h * 0.3))
        p.closeSubpath()
        return p
    }

    private func apply(_ rig: CourierRig, _ n: String, _ duck: Duck?) {
        guard let group = rig[n] else { return }
        guard let d = duck else { group.isHidden = true; return }
        group.isHidden = false
        group.opacity = Float(d.alpha)
        // Mockup units to drawing units round the anchor: both y down, the body's unit is 0.86 mockup px.
        let dx = (d.x - anchor.x) / k, dy = (d.y - anchor.y) / k, r = d.k / k
        rig.set(n, turn: d.rot, sx: d.sx * d.face * r, sy: d.sy * r, dx: dx, dy: dy)
        rig.set(n + ".f1", turn: -d.step * 0.3, dy: -max(0, d.step) * 5)
        rig.set(n + ".f2", turn: d.step * 0.3, dy: -max(0, -d.step) * 5)
        for t in [".tuftO", ".tuft"] { rig.set(n + t, turn: d.tail) }
        rig.set(n + ".wing", turn: -d.wing)
        for h in [".h", ".hO"] { rig.set(n + h, turn: d.tilt) }
        rig.set(n + ".cap", turn: d.capTurn - 0.08, dy: -d.capLift)
        for b in [".lo", ".loO"] { rig.set(n + b, turn: -d.jaw * 0.55) }
        rig[n + ".mouth"]?.path = d.jaw > 0.05 ? E(-33, -47.4, 5, 2.2 * d.jaw + 0.5) : nil
        eye(rig, n + ".eL", -18, -57, 4.1, 5, d.eyes, d.blink, dir: 1)
        eye(rig, n + ".eR", 3, -58.5, 3.6, 4.5, d.eyes, d.blink, dir: -1)
    }

    /// The mockup's `eye`: open (with the lid), happy (an arch) or squeezed (a chevron).
    private func eye(_ rig: CourierRig, _ name: String, _ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                     _ state: Eyes, _ lid: CGFloat, dir: CGFloat) {
        guard let e = rig[name], let g = rig[name + "g"] else { return }
        let b = clamp(lid)
        func stroke(_ p: CGPath, _ w: CGFloat) {
            e.path = p
            e.fillColor = nil
            e.strokeColor = ink.cgColor
            e.lineWidth = w
            e.lineCap = .round
            g.path = nil
        }
        switch state {
        case .happy:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - rx * 1.15, y: y + ry * 0.35))
            p.addQuadCurve(to: CGPoint(x: x + rx * 1.15, y: y + ry * 0.35), control: CGPoint(x: x, y: y - ry * 1.25))
            stroke(p, lw * 1.5)
        case .squeeze:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - rx * dir * 1.05, y: y - ry * 0.85))
            p.addLine(to: CGPoint(x: x + rx * dir * 0.95, y: y))
            p.addLine(to: CGPoint(x: x - rx * dir * 1.05, y: y + ry * 0.85))
            stroke(p, lw * 1.5)
        case .open where b > 0.82:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x - rx * 1.1, y: y + ry * 0.1))
            p.addQuadCurve(to: CGPoint(x: x + rx * 1.1, y: y + ry * 0.1), control: CGPoint(x: x, y: y + ry * 0.85))
            stroke(p, lw * 1.4)
        case .open:
            e.path = E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92))
            e.fillColor = ink.cgColor
            e.strokeColor = nil
            e.lineWidth = 0
            if b < 0.45 {
                let p = CGMutablePath()
                p.addPath(E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4))
                p.addPath(E(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19))
                g.path = p
            } else {
                g.path = nil
            }
        }
    }

    // MARK: Sounds

    func cues(_ plan: CourierPlan) -> [CourierCue] {
        var out = [CourierCue(ms: 40, name: "steps")]
        if plan.gag { out.append(CourierCue(ms: 200, name: "trip")) }
        out.append(CourierCue(ms: 420, name: "toss"))
        for i in 0..<plan.actors { out.append(CourierCue(ms: 560 + Double(i) * 40, name: "quack\(i)")) }
        out.append(CourierCue(ms: 780, name: "steps"))
        return out
    }

    func sound(_ cue: String) -> [Double]? {
        let rate = PortalSound.rate
        if cue.hasPrefix("quack"), let i = Int(cue.dropFirst(5)) {
            // Three rising pitches (≈ 520, 660, 780 Hz), more for a bigger batch.
            let pitches: [Double] = [520, 660, 780, 880, 990]
            return quack(pitches[min(i, pitches.count - 1)], rate: rate)
        }
        switch cue {
        case "steps":
            // Little webbed feet: soft taps, alternating, 60 ms apart.
            let n = Int(0.36 * rate)
            var out = [Double](repeating: 0, count: n)
            var r = CourierRandom(seed: 41)
            for j in 0..<6 {
                let start = Int(Double(j) * 0.06 * rate), f = j % 2 == 0 ? 340.0 : 300.0
                for s in 0..<Int(0.035 * rate) where start + s < n {
                    let t = Double(s) / rate
                    out[start + s] += 0.22 * exp(-t * 140) * (sin(2 * .pi * f * t) * 0.7 + (r.next() - 0.5) * 0.5)
                }
            }
            return out
        case "toss":
            // A tiny upward "hup": a chirp from 600 to 1100 Hz.
            let n = Int(0.09 * rate)
            var phase = 0.0
            return (0..<n).map { s in
                let t = Double(s) / Double(n), f = 600 + 500 * t * t
                phase += 2 * .pi * f / rate
                return 0.2 * sin(.pi * t) * sin(phase)
            }
        case "trip":
            // A soft bonk and a startled peep.
            let n = Int(0.22 * rate)
            var phase = 0.0
            return (0..<n).map { s in
                let t = Double(s) / rate
                var v = 0.35 * exp(-t * 38) * sin(2 * .pi * (150 - 60 * t) * t)
                if t > 0.06 {
                    let u = t - 0.06
                    phase += 2 * .pi * (1300 - 900 * u) / rate
                    v += 0.16 * exp(-u * 18) * sin(.pi * min(1, u / 0.012)) * sin(phase)
                }
                return v
            }
        default:
            return nil
        }
    }

    /// A small, nasal quack: a buzzy tone that drops a little, with a reedy band.
    private func quack(_ f0: Double, rate: Double) -> [Double] {
        let n = Int(0.09 * rate)
        var phase = 0.0
        return (0..<n).map { s in
            let t = Double(s) / Double(n)
            let f = f0 * (1.06 - 0.12 * t)
            phase += 2 * .pi * f / rate
            let env = min(1, t / 0.08) * pow(1 - t, 1.6)
            var v = 0.0
            for h in 1...6 { v += sin(phase * Double(h)) / Double(h) * (h == 3 || h == 4 ? 1.6 : 1) }
            return 0.12 * env * v
        }
    }
}
