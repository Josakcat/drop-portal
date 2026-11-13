//
//  TofuCourier.swift
//  DropPortal
//
//  Tofu the cat on the Mac, the show-off: lands every pounce, then acts like
//  it was nothing. The approved mockup's rig (`drawCat`, `catWait`, `catMac`
//  and `flap` in `.droppykit/design/fx-mockups-cute-v2/mockups.html`), as
//  `CAShapeLayer` parts in its units (feet at 0,0, y down, facing left):
//
//  - waiting: Tofu's head peeks round the right edge, eyes and pink ears up,
//    one paw hooks the edge at p .7, the hinged cat flap appears as the phone
//    lets go; then the ears twitch and the eyes blink.
//  - arrival: the flap swings open, Tofu bursts through mid-leap with the card
//    in its mouth (the card dangles), skids with paw prints and puffs, hops and
//    tosses the card onto its spot, exactly at L.
//  - after: lands with a squash, a quick nonchalant paw lick and a tail flick
//    (it was nothing), turns and trots back through the flap, which swings shut.
//  - sticker: the happy pose, a paw up, one blink.
//
//  The union outline is the mockup's: every part's ink (fill plus a stroke at
//  twice the line) sits behind all the fills, so only the silhouette is drawn.
//

import AppKit
import DropPortalCore

@MainActor
final class TofuCourier: CourierCharacter {
    let courier: Courier = .pounce

    // The palette: coat, shade, cream, ears and blush, outline.
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    private let ink = hex(0x2B1A10), coat = hex(0xF2A03D), shade = hex(0xC8661E), cream = hex(0xFFF3E2), pink = hex(0xF59AA8)
    /// The outline in drawing units: 2 of the mockup's pixels at its Mac scale.
    private let lw: CGFloat = 2 / 0.86

    /// The body, the shadow and the card copy, clipped at the flap while Tofu goes through it.
    private let clip = CALayer()
    // The flap on the right edge (stage points), drawn in its own units, y down.
    private let flapG = CALayer()
    private let flapPanel = CAShapeLayer()
    private let flapPaw = CAShapeLayer()
    // The paw that hooks the edge while waiting.
    private let edgePaw = CALayer()
    // Puffs, paw prints and speed lines.
    private var puffs: [CAShapeLayer] = []
    private var prints: [CAShapeLayer] = []
    private var lines: [CAShapeLayer] = []

    // MARK: - Build

    func build(_ rig: CourierRig) {
        clip.frame = rig.root.bounds
        clip.actions = CourierKit.noActions
        rig.root.insertSublayer(clip, above: rig.behind)
        for layer in [rig.shadow, rig.body, rig.cardCopy] as [CALayer] {
            layer.removeFromSuperlayer()
            clip.addSublayer(layer)
        }
        buildFlap(rig)
        buildCat(rig)
        buildEffects(rig)
    }

    private func buildCat(_ rig: CourierRig) {
        let none = NSColor.clear
        // The tail: an outlined stroke with dashed stripes, turning about its root.
        let tail = Self.tailPath()
        let tailG = rig.part("tail", CGMutablePath(), fill: none, width: 0, pivot: CGPoint(x: 40, y: -30))
        stroke(rig.part("tailInk", tail, fill: none, ink: ink, width: 9 + lw * 2, pivot: CGPoint(x: 40, y: -30), in: tailG))
        stroke(rig.part("tailCoat", tail, fill: none, ink: coat, width: 9, pivot: CGPoint(x: 40, y: -30), in: tailG))
        let stripes = rig.part("tailStripe", tail, fill: none, ink: shade, width: 4.5, pivot: CGPoint(x: 40, y: -30), in: tailG)
        stroke(stripes)
        stripes.lineDashPattern = [3.5, 6]
        stripes.lineDashPhase = -6

        // The far legs, in shade, outlined on their own.
        let farF = Self.capsule(-21, -14, 13, 9.5), farB = Self.capsule(27, -14, 13, 9.5)
        inkPart(rig, "legFfarInk", farF, pivot: CGPoint(x: -21, y: -14))
        inkPart(rig, "legBfarInk", farB, pivot: CGPoint(x: 27, y: -14))
        rig.part("legFfar", farF, fill: shade, width: 0, pivot: CGPoint(x: -21, y: -14))
        rig.part("legBfar", farB, fill: shade, width: 0, pivot: CGPoint(x: 27, y: -14))

        // The union's ink: body, near legs, ears and head, behind every fill.
        let body = Self.ellipse(13, -27, 31, 20.5), head = Self.ellipse(-14, -53, 35, 29)
        let nearF = Self.capsule(-9, -14, 13, 10), nearB = Self.capsule(37, -14, 13, 10)
        let earL = Self.ear(-35, -73, -0.42), earR = Self.ear(3, -78, 0.28)
        inkPart(rig, "bodyInk", body, pivot: .zero)
        inkPart(rig, "legFInk", nearF, pivot: CGPoint(x: -9, y: -14))
        inkPart(rig, "legBInk", nearB, pivot: CGPoint(x: 37, y: -14))
        let headInk = rig.part("headInk", CGMutablePath(), fill: none, width: 0, pivot: CGPoint(x: -4, y: -36))
        inkPart(rig, "earLInk", earL, pivot: CGPoint(x: -35, y: -73), in: headInk)
        inkPart(rig, "earRInk", earR, pivot: CGPoint(x: 3, y: -78), in: headInk)
        inkPart(rig, "headShapeInk", head, pivot: CGPoint(x: -4, y: -36), in: headInk)

        // The body: shade with the lit coat on top (the mockup's rimShade), stripes, the cream chest.
        let bodyG = rig.part("body", body, fill: shade, width: 0)
        rig.part("bodyLit", lit(body, -4, -5), fill: coat, width: 0, in: bodyG)
        for x: CGFloat in [18, 28] {
            rig.part("bodyStripe\(Int(x))", Self.ellipse(x, -46, 3, 9, rot: 0.2).intersection(body), fill: shade.withAlphaComponent(0.75), width: 0, in: bodyG)
        }
        rig.part("chest", Self.ellipse(-6, -22, 13, 13).intersection(body), fill: cream, width: 0, in: bodyG)

        // The near legs with cream paws.
        for (name, path, x) in [("legF", nearF, CGFloat(-9)), ("legB", nearB, 37)] {
            let leg = rig.part(name, path, fill: coat, width: 0, pivot: CGPoint(x: x, y: -14))
            rig.part(name + "Paw", Self.ellipse(x, -1, 7, 5).intersection(path), fill: cream, width: 0, pivot: CGPoint(x: x, y: -14), in: leg)
        }

        // The head, turned about (-4, -36): ears, the face.
        let headG = rig.part("head", CGMutablePath(), fill: none, width: 0, pivot: CGPoint(x: -4, y: -36))
        for (name, path, at, a) in [("earL", earL, CGPoint(x: -35, y: -73), CGFloat(-0.42)), ("earR", earR, CGPoint(x: 3, y: -78), 0.28)] {
            let ear = rig.part(name, path, fill: coat, width: 0, pivot: at, in: headG)
            let inner = Self.earShape.copy(using: [CGAffineTransform(translationX: at.x, y: at.y).rotated(by: a).scaledBy(x: 0.55, y: 0.6).translatedBy(x: 0, y: -3)])
            rig.part(name + "Pink", inner, fill: pink, width: 0, pivot: at, in: ear)
        }
        let face = rig.part("headShape", head, fill: shade, width: 0, pivot: CGPoint(x: -4, y: -36), in: headG)
        rig.part("headLit", lit(head, -4, -5), fill: coat, width: 0, pivot: CGPoint(x: -4, y: -36), in: face)
        for (i, (x, a)) in [(CGFloat(-24), CGFloat(-0.25)), (-14, 0), (-4, 0.25)].enumerated() {
            rig.part("headStripe\(i)", Self.ellipse(x, -80, 2.6, 8, rot: a).intersection(head), fill: shade.withAlphaComponent(0.8), width: 0,
                     pivot: CGPoint(x: -4, y: -36), in: face)
        }
        let p0 = CGPoint(x: -4, y: -36)
        rig.part("hilite", Self.ellipse(-32, -70, 9, 5, rot: -0.6), fill: NSColor(white: 1, alpha: 0.45), width: 0, pivot: p0, in: face)
        rig.part("muzzle", Self.ellipse(-19, -42.5, 14, 9), fill: cream, width: 0, pivot: p0, in: face)
        // Eyes: open (with glints), shut, happy.
        for (side, x, y, rx, ry) in [("L", CGFloat(-31), CGFloat(-51), CGFloat(4.8), CGFloat(5.9)), ("R", -4, -52, 4.6, 5.6)] {
            let c = CGPoint(x: x, y: y)
            let eye = rig.part("eye" + side, Self.ellipse(x, y, rx, ry), fill: ink, width: 0, pivot: c, in: face)
            let glint = CGMutablePath()
            glint.addPath(Self.ellipse(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, rot: -0.4))
            glint.addPath(Self.ellipse(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19))
            rig.part("glint" + side, glint, fill: .white, width: 0, pivot: c, in: eye)
            let shut = CGMutablePath()
            shut.move(to: CGPoint(x: x - rx * 1.1, y: y + ry * 0.1))
            shut.addQuadCurve(to: CGPoint(x: x + rx * 1.1, y: y + ry * 0.1), control: CGPoint(x: x, y: y + ry * 0.85))
            stroke(rig.part("shut" + side, shut, fill: none, ink: ink, width: lw * 1.4, pivot: c, in: face))
            let happy = CGMutablePath()
            happy.move(to: CGPoint(x: x - rx * 1.15, y: y + ry * 0.35))
            happy.addQuadCurve(to: CGPoint(x: x + rx * 1.15, y: y + ry * 0.35), control: CGPoint(x: x, y: y - ry * 1.25))
            stroke(rig.part("happy" + side, happy, fill: none, ink: ink, width: lw * 1.5, pivot: c, in: face))
        }
        for (i, (x, y)) in [(CGFloat(-39), CGFloat(-42)), (4, -43.5)].enumerated() {
            rig.part("blush\(i)", Self.ellipse(x, y, 5.5, 3.3), fill: pink.withAlphaComponent(0.8), width: 0, pivot: p0, in: face)
            rig.part("blushDot\(i)", Self.ellipse(x - 5.5 * 0.35, y - 3.3 * 0.3, 1.2, 0.75), fill: NSColor(white: 1, alpha: 0.44), width: 0, pivot: p0, in: face)
        }
        // Nose, the four mouths, whiskers.
        let nx: CGFloat = -18.5, ny: CGFloat = -46.8
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: nx - 2.6, y: ny - 1.2))
        nose.addQuadCurve(to: CGPoint(x: nx + 2.6, y: ny - 1.2), control: CGPoint(x: nx, y: ny - 2.2))
        nose.addQuadCurve(to: CGPoint(x: nx, y: ny + 2), control: CGPoint(x: nx + 0.6, y: ny + 2))
        nose.addQuadCurve(to: CGPoint(x: nx - 2.6, y: ny - 1.2), control: CGPoint(x: nx - 0.6, y: ny + 2))
        rig.part("nose", nose, fill: Self.hex(0xE2788A), width: 0, pivot: p0, in: face)
        let mx = nx, my = ny + 3.2, s: CGFloat = 0.8
        let w = CGMutablePath()
        w.move(to: CGPoint(x: mx - 4 * s, y: my))
        w.addQuadCurve(to: CGPoint(x: mx, y: my + 0.4 * s), control: CGPoint(x: mx - 2 * s, y: my + 2.6 * s))
        w.addQuadCurve(to: CGPoint(x: mx + 4 * s, y: my), control: CGPoint(x: mx + 2 * s, y: my + 2.6 * s))
        stroke(rig.part("mouthW", w, fill: none, ink: ink, width: lw * 1.1, pivot: p0, in: face))
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: mx - 3.4 * s, y: my))
        smile.addQuadCurve(to: CGPoint(x: mx + 3.4 * s, y: my), control: CGPoint(x: mx, y: my + 3.4 * s))
        stroke(rig.part("mouthSmile", smile, fill: none, ink: ink, width: lw * 1.1, pivot: p0, in: face))
        let puff = CGMutablePath()
        puff.move(to: CGPoint(x: mx - 2 * s, y: my + s))
        puff.addLine(to: CGPoint(x: mx + 2 * s, y: my + s))
        stroke(rig.part("mouthPuff", puff, fill: none, ink: ink, width: lw * 1.1, pivot: p0, in: face))
        let open = CGMutablePath()
        open.move(to: CGPoint(x: mx - 4 * s, y: my))
        open.addQuadCurve(to: CGPoint(x: mx + 4 * s, y: my), control: CGPoint(x: mx, y: my + 0.5 * s))
        open.addQuadCurve(to: CGPoint(x: mx - 4 * s, y: my), control: CGPoint(x: mx, y: my + 6 * s))
        let openL = rig.part("mouthOpen", open, fill: ink, ink: ink, width: lw * 0.6, pivot: p0, in: face)
        rig.part("tongue", Self.ellipse(mx, my + 3.3 * s, 2.2 * s, 1.4 * s), fill: Self.hex(0xFF8A9A), width: 0, pivot: p0, in: openL)
        let whiskers = CGMutablePath()
        for (y, d) in [(CGFloat(-44), CGFloat(-1.5)), (-41.5, 1.5)] {
            whiskers.move(to: CGPoint(x: nx - 9, y: y))
            whiskers.addQuadCurve(to: CGPoint(x: nx - 29, y: y + d * 2), control: CGPoint(x: nx - 20, y: y + d - 1))
        }
        stroke(rig.part("whiskers", whiskers, fill: none, ink: ink.withAlphaComponent(0.5), width: lw * 0.55, pivot: p0, in: face))
    }

    private func buildFlap(_ rig: CourierRig) {
        // The mockup's flap: 76 tall, 0.46 as wide, a dark frame, the hole, the cream panel on a top hinge.
        let H: CGFloat = 76, W = H * 0.46
        flapG.actions = CourierKit.noActions
        flapG.bounds = .zero
        let frame = shape(CGPath(roundedRect: CGRect(x: -W / 2 - 5, y: -H / 2 - 5, width: W + 10, height: H + 10), cornerWidth: W * 0.42, cornerHeight: W * 0.42, transform: nil), ink)
        let hole = CGPath(roundedRect: CGRect(x: -W / 2, y: -H / 2, width: W, height: H), cornerWidth: W * 0.36, cornerHeight: W * 0.36, transform: nil)
        let holeL = shape(hole, Self.hex(0x120A05))
        flapPanel.actions = CourierKit.noActions
        flapPanel.strokeColor = NSColor(srgbRed: 43 / 255, green: 26 / 255, blue: 16 / 255, alpha: 0.5).cgColor
        flapPanel.lineWidth = 1.3
        flapPanel.lineJoin = .round
        let mask = shape(hole, .black)
        let inside = CALayer()
        inside.actions = CourierKit.noActions
        inside.mask = mask
        inside.addSublayer(flapPanel)
        let pad = CGMutablePath()
        pad.addPath(Self.ellipse(0, 3, 3.6, 3))
        for (x, y) in [(CGFloat(-4), CGFloat(-2.5)), (-1.4, -4.6), (1.4, -4.6), (4, -2.5)] { pad.addPath(Self.ellipse(x, y, 1.4, 1.4)) }
        flapPaw.path = pad
        flapPaw.fillColor = Self.hex(0xC9905E, 0.8).cgColor
        flapPaw.actions = CourierKit.noActions
        inside.addSublayer(flapPaw)
        let hinge = shape(CGPath(roundedRect: CGRect(x: -W / 2 - 2, y: -H / 2 + 1, width: W + 4, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil), Self.hex(0x5B3B26))
        for layer in [frame, holeL, inside, hinge] { flapG.addSublayer(layer) }
        rig.behind.addSublayer(flapG)

        // The paw on the edge: coat with a pink pad and three beans.
        edgePaw.actions = CourierKit.noActions
        edgePaw.bounds = .zero
        let toe = shape(Self.ellipse(0, 0, 7, 8.5), coat)
        toe.strokeColor = ink.cgColor
        toe.lineWidth = 2
        edgePaw.addSublayer(toe)
        let beans = CGMutablePath()
        beans.addPath(Self.ellipse(-1, 2, 3, 2.6))
        for (x, y) in [(CGFloat(-3.6), CGFloat(-4)), (0, -5.4), (-5.2, -0.4)] { beans.addPath(Self.ellipse(x, y, 1.3, 1.3)) }
        edgePaw.addSublayer(shape(beans, pink))
        rig.front.addSublayer(edgePaw)
    }

    private func buildEffects(_ rig: CourierRig) {
        let print = CGMutablePath()
        print.addPath(Self.ellipse(0, 1.5, 3.4, 2.8))
        for (x, y) in [(CGFloat(-3.6), CGFloat(-2.6)), (-1.2, -4.2), (1.2, -4.2), (3.6, -2.6)] { print.addPath(Self.ellipse(x, y, 1.3, 1.3)) }
        for _ in 0..<4 {
            let l = shape(print, Self.hex(0xF6D9C4))
            prints.append(l)
            rig.behind.addSublayer(l)
        }
        for _ in 0..<6 {
            let l = shape(Self.ellipse(0, 0, 1, 1), NSColor(srgbRed: 1, green: 250 / 255, blue: 240 / 255, alpha: 1))
            puffs.append(l)
            rig.front.addSublayer(l)
        }
        for _ in 0..<3 {
            let l = CAShapeLayer()
            l.actions = CourierKit.noActions
            l.strokeColor = NSColor.white.cgColor
            l.lineCap = .round
            lines.append(l)
            rig.front.addSublayer(l)
        }
    }

    // MARK: - The flow

    func waiting(_ f: CourierFrame, p: CGFloat, ms: Double) -> CourierPose { state(f).pose }
    func arrive(_ f: CourierFrame, T: Double) -> CourierPose { state(f).pose }
    func leave(_ f: CourierFrame, T: Double) -> CourierPose? { T > courier.goneMS ? nil : state(f).pose }
    func sticker(_ f: CourierFrame, ms: Double) -> CourierPose { state(f).pose }

    private enum Eyes { case open, wide, happy }
    private enum Mouth { case w, open, smile, puff }

    /// Everything about one frame: the body's pose and the parts the mockup moves.
    private struct Cat {
        var pose: CourierPose
        var headOnly = false
        var tilt: CGFloat = 0, ear: CGFloat = 0, tail: CGFloat = 0.2
        var legF: CGFloat = 0, legB: CGFloat = 0, step: CGFloat = 0
        /// The near front paw raised to the mouth (radians on top of legF).
        var groom: CGFloat = 0
        var eyes = Eyes.open, mouth = Mouth.w
        var lid: CGFloat = 0
        var lookX: CGFloat = 0
        /// The flap: size, swing (radians) and opacity; the edge paw's size.
        var flap: CGFloat = 0, swing: CGFloat = 0, flapAlpha: CGFloat = 0, paw: CGFloat = 0
        /// Clip the body at the flap (going through it).
        var clipped = false
        /// T on the plan's clock for the puffs, prints and lines; nil while waiting.
        var T: Double?
    }

    private func state(_ f: CourierFrame) -> Cat {
        let s = f.scene
        switch f.moment {
        case .waiting(let p, let ms): return wait(s, p: p, ms: ms, lid: f.blink)
        case .arriving(let T), .leaving(let T): return run(f, T: T)
        case .sticker:
            var c = Cat(pose: CourierPose(x: 0, y: 0))
            c.eyes = f.blink > 0.5 ? .open : .happy
            c.lid = f.blink > 0.5 ? 1 : 0
            c.mouth = .open
            c.legF = 0.9
            c.tail = 0.4
            c.tilt = 0.05
            return c
        }
    }

    /// The mockup's Mac edge (x 945) is the screen's right edge; its ground (336) the scene's.
    private func edgeX(_ s: CourierScene, _ units: CGFloat) -> CGFloat { s.size.width + units * s.s }
    private func spotX(_ s: CourierScene) -> CGFloat { s.mock(764, 336).x }
    private func flapCenter(_ s: CourierScene) -> CGPoint { CGPoint(x: edgeX(s, -7), y: s.ground + 50 * s.s) }

    /// Waiting: the head peeks round the edge with the phone's p, a paw hooks it, the flap appears.
    private func wait(_ s: CourierScene, p: CGFloat, ms: Double, lid: CGFloat) -> Cat {
        let a = CourierKit.easeOut(p)
        var c = Cat(pose: CourierPose(x: edgeX(s, 40 - a * 36), y: s.ground + 28 * s.s, rot: 0.55))
        c.headOnly = true
        c.lookX = -1
        c.lid = lid
        // The ears perk as the eyes come round (p .4), then twitch ±8° every 600 ms once the card is let go.
        c.ear = 0.16 * CourierKit.kick(Double(p) * 600 - 240, f: 6, z: 0.3)
        if p >= 0.999 {
            let ph = ms.truncatingRemainder(dividingBy: 600)
            c.ear += 0.14 * CourierKit.kick(ph, f: 7, z: 0.3) * (Int(ms / 600) % 2 == 0 ? -1 : 1)
        }
        c.paw = CourierKit.backOut(CourierKit.part(Double(p), 0.7, 0.85), 2.2)
        c.flap = 1
        c.flapAlpha = CourierKit.easeOut(CourierKit.part(Double(p), 0.85, 1))
        return c
    }

    /// From the bytes to gone, on the plan's clock (the mockup's `catMac`).
    private func run(_ f: CourierFrame, T: Double) -> Cat {
        let s = f.scene, L = courier.landingMS, exit = courier.exitMS, gone = courier.goneMS
        let g = s.ground, spot = spotX(s), J = CGFloat(f.plan.jitter)
        var c = Cat(pose: CourierPose(x: spot, y: g))
        c.T = T
        c.lid = f.blink
        c.clipped = true
        c.flap = 1
        c.flapAlpha = 1 - CourierKit.easeIn(CourierKit.part(T, gone - 50, gone))
        // The flap: swings open as Tofu bursts through, settles, is bumped on the way home.
        if T < 60 { c.swing = 0.9 * CourierKit.easeOut(CGFloat(T / 60)) }
        else if T < 240 { c.swing = 0.9 }
        else { c.swing = 0.9 * CourierKit.settle(T - 240, f: 3, z: 0.32) }
        if T > gone - 100 { c.swing -= 0.6 * CourierKit.kick(T - (gone - 90), f: 3, z: 0.35) }

        if T < 60 {
            // The head ducks back behind the edge as the flap opens.
            let u = CourierKit.easeIn(CGFloat(T / 60))
            c.pose = CourierPose(x: edgeX(s, 4 + 60 * u), y: g + 28 * s.s, rot: 0.55, alpha: 1 - u)
            c.headOnly = true
            c.clipped = false
            c.ear = -0.3 * u
            return c
        }
        if T < 240 {
            // The burst: mid-leap on the descending half of the arc, stretched along the flight.
            let u = CourierKit.part(T, 60, 240)
            c.pose.x = CourierKit.mix(edgeX(s, 45), spot + 48 * s.s, u)
            c.pose.y = g + 58 * s.s * J * (1 - u * u)
            let vx: CGFloat = -178 / 180, vy = 58 * 2 * u / 180
            c.pose.rot = -CourierKit.clamp(-atan2(vy, -vx) * 0.7, -0.6, 0.6)
            let vs: CGFloat = T < 110 ? 1.25 : 1.15
            c.pose.sx = vs
            c.pose.sy = 1 / vs
            c.legF = CourierKit.mix(1.1, 0.55, u)
            c.legB = CourierKit.mix(-1.1, -0.4, u)
            c.eyes = .wide
            c.mouth = .puff
            c.tail = 0.5 + 0.4 * CourierKit.kick(T - 60, f: 5, z: 0.35)
            c.ear = -0.3 + 0.15 * CourierKit.kick(T - 60, f: 6, z: 0.3)
            c.tilt = 0.14
            c.pose.card = carry(c, s, wobble: 0.2 * CourierKit.kick(T - 60, f: 4, z: 0.3))
            c.pose.cardBehind = true
            return c
        }
        if T < 360 {
            // The skid: leans back, decelerates, squashes.
            let u = CourierKit.part(T, 240, 360)
            let q = CourierKit.landSquash(T - 240, peak: 1.18, rebound: 0.96, hold: 30)
            c.pose.x = spot + (48 - 46 * CourierKit.easeOut(u)) * s.s
            c.pose.sx = q
            c.pose.sy = 1 / q
            c.pose.rot = -0.14 * sin(.pi * min(1, u * 1.15))
            c.legF = 0.65 * (1 - u)
            c.legB = 0.25
            c.mouth = .puff
            c.tail = 0.6 + 0.25 * CourierKit.kick(T - 240, f: 4, z: 0.35)
            c.ear = -0.3 * (1 - CourierKit.easeOut(u)) + 0.12 * CourierKit.kick(T - 250, f: 6, z: 0.3)
            c.tilt = 0.14
            c.pose.card = carry(c, s, wobble: -0.25 * CourierKit.kick(T - 240, f: 4, z: 0.3))
            c.pose.cardBehind = true
            return c
        }
        if T < L {
            // The toss: a little hop, the head flicks, the card arcs onto its spot and lands exactly at L.
            let u = CourierKit.part(T, 360, L)
            c.pose.y = g + 14 * s.s * sin(.pi * u)
            c.tilt = -0.3 * sin(.pi * CourierKit.part(T, 360, 430))
            c.legF = 0.3 * sin(.pi * u)
            c.legB = -0.3 * sin(.pi * u)
            c.mouth = T < 380 ? .puff : .open
            let q = CourierKit.landSquash(T - 240, peak: 1.18, rebound: 0.96, hold: 30)
            c.pose.sx = q
            c.pose.sy = 1 / q
            c.tail = 0.3 + 0.3 * CourierKit.kick(T - 360, f: 4, z: 0.4)
            c.ear = 0.1 * CourierKit.kick(T - 360, f: 6, z: 0.3)
            var held = Cat(pose: CourierPose(x: spot, y: g))
            held.tilt = 0.14
            let m0 = carry(held, s, wobble: 0)
            let e = CourierKit.easeOut(u)
            let ctrl = CGPoint(x: CourierKit.mix(m0.center.x, s.landing.x, 0.45), y: max(m0.center.y, s.landing.y) + 48 * s.s * J)
            c.pose.card = CardCarry(center: CourierKit.qbez(m0.center, ctrl, s.landing, e), scale: CourierKit.mix(0.3, 1, e),
                                    rot: CourierKit.mix(m0.rot, 0, e))
            return c
        }
        if T < exit {
            // It was nothing: lands with a squash, a smug look, a quick paw lick, a tail flick, one blink.
            let q = CourierKit.landSquash(T - L)
            c.pose.sx = q
            c.pose.sy = 1 / q
            let up = CourierKit.easeOut(CourierKit.part(T, L + 30, L + 70)) * (1 - CourierKit.easeInOut(CourierKit.part(T, exit - 50, exit - 10)))
            let lick = sin(2 * .pi * CGFloat(T - L - 70) / 60) * CourierKit.part(T, L + 70, L + 80) * (1 - CourierKit.part(T, exit - 60, exit - 50))
            c.groom = 2.0 * up + 0.14 * lick
            c.tilt = 0.08 * sin(.pi * CourierKit.part(T, L, exit - 40)) - 0.14 * up + 0.05 * lick
            c.eyes = T < exit - 60 ? .happy : .open
            c.mouth = up > 0.5 ? (lick > 0 ? .open : .w) : (T < exit - 60 ? .open : .smile)
            c.lookX = 2 * up
            c.tail = 0.35 * sin(.pi * CourierKit.part(T, L, exit))
            c.ear = 0.1 * CourierKit.kick(T - L, f: 5, z: 0.3) + 0.12 * CourierKit.kick(T - (exit - 40), f: 7, z: 0.3)
            if T >= exit - 60 { c.lid = max(c.lid, CGFloat(CourierPlan.lid(T - (exit - 50)))) }
            return c
        }
        // Turns (one beat), hops, trots home through the flap.
        let tu = CourierKit.part(T, exit, exit + 70)
        c.pose.face = cos(.pi * CourierKit.easeInOut(tu))
        c.pose.y = g + 6 * s.s * sin(.pi * tu)
        c.mouth = .smile
        c.tail = 0.2 + 0.3 * CourierKit.kick(T - exit, f: 3, z: 0.4)
        if T > exit + 60 {
            let u = CourierKit.part(T, exit + 60, gone - 20), e = CourierKit.curveA(u)
            c.pose.face = -1
            c.pose.x = CourierKit.mix(spot, edgeX(s, 65), e)
            c.pose.y = g + 5 * s.s * abs(sin(u * .pi * 4))
            c.step = sin(u * .pi * 8)
            let slope = (e - CourierKit.curveA(max(0, u - 0.01))) / 0.01
            c.pose.sx = 1 + 0.1 * CourierKit.clamp(slope / 2.5)
            c.pose.sy = 1 / c.pose.sx
            c.tail = 0.3 + 0.15 * sin(u * .pi * 8)
        }
        return c
    }

    /// The card held by its top right corner in the mouth, hanging down and forward (stage points).
    private func carry(_ c: Cat, _ s: CourierScene, wobble: CGFloat) -> CardCarry {
        let mouth = point(c, s, CGPoint(x: -17, y: -38), aboutHead: true)
        let r = -0.05 + wobble - c.pose.rot * 0.5
        let a = s.card.width * 0.3 / 2 - 6 * s.s, b = s.card.height * 0.3 / 2 - 6 * s.s
        let rr = -r
        let center = CGPoint(x: mouth.x - (a * cos(rr) - b * sin(rr)), y: mouth.y - (a * sin(rr) + b * cos(rr)))
        return CardCarry(center: center, scale: 0.3, rot: rr)
    }

    /// A drawing point on the stage: through the head's tilt, then the body's pose.
    private func point(_ c: Cat, _ s: CourierScene, _ q: CGPoint, aboutHead: Bool) -> CGPoint {
        var x = q.x, y = q.y
        if aboutHead {
            let t = c.tilt, dx = x + 4, dy = y + 36
            x = -4 + dx * cos(t) - dy * sin(t)
            y = -36 + dx * sin(t) + dy * cos(t)
        }
        let u = s.unit * c.pose.scale, p = c.pose
        let vx = p.sx * p.face * u * x, vy = -p.sy * u * y
        return CGPoint(x: p.x + vx * cos(p.rot) - vy * sin(p.rot), y: p.y + vx * sin(p.rot) + vy * cos(p.rot))
    }

    // MARK: - Draw

    func draw(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame) {
        var c = state(f)
        c.pose = pose
        let s = f.scene
        let sticker: Bool
        if case .sticker = f.moment { sticker = true } else { sticker = false }

        // Head only while peeking; everything otherwise.
        for name in ["tail", "legFfarInk", "legBfarInk", "legFfar", "legBfar", "bodyInk", "legFInk", "legBInk", "body", "legF", "legB"] {
            rig[name]?.isHidden = c.headOnly
        }
        rig.set("tail", turn: c.tail)
        let lf = c.legF, lb = c.legB, st = c.step
        rig.set("legFfarInk", turn: lf * 0.85 - st * 0.4); rig.set("legFfar", turn: lf * 0.85 - st * 0.4)
        rig.set("legBfarInk", turn: lb * 0.85 + st * 0.4); rig.set("legBfar", turn: lb * 0.85 + st * 0.4)
        let lift = c.groom / 2.0
        for name in ["legFInk", "legF"] { rig.set(name, turn: lf + st * 0.4 + c.groom, dx: -2 * lift, dy: -3 * lift) }
        rig.set("legBInk", turn: lb - st * 0.4); rig.set("legB", turn: lb - st * 0.4)
        rig.set("headInk", turn: c.tilt); rig.set("head", turn: c.tilt)
        for name in ["earL", "earLInk"] { rig.set(name, turn: c.ear) }
        for name in ["earR", "earRInk"] { rig.set(name, turn: c.ear * 0.8) }

        // Eyes: open (wide is 1.15), the blink's lid, shut past .82, happy arcs.
        let lid = CourierKit.clamp(c.lid)
        let happy = c.eyes == .happy, shut = !happy && lid > 0.82
        for (side, ry, look) in [("L", CGFloat(5.9), c.lookX), ("R", 5.6, c.lookX)] {
            let k: CGFloat = c.eyes == .wide ? 1.15 : 1
            rig["eye" + side]?.isHidden = happy || shut
            rig.set("eye" + side, sx: k, sy: k * (1 - lid * 0.92), dx: look, dy: ry * lid * 0.55)
            rig["glint" + side]?.isHidden = lid >= 0.45
            rig["shut" + side]?.isHidden = !shut
            rig.set("shut" + side, dx: look)
            rig["happy" + side]?.isHidden = !happy
            rig.set("happy" + side, dx: look)
        }
        rig["mouthW"]?.isHidden = c.mouth != .w
        rig["mouthOpen"]?.isHidden = c.mouth != .open
        rig["mouthSmile"]?.isHidden = c.mouth != .smile
        rig["mouthPuff"]?.isHidden = c.mouth != .puff

        // The clip at the flap while Tofu goes through it.
        let fc = flapCenter(s)
        clip.masksToBounds = c.clipped && !sticker
        clip.frame = CGRect(x: 0, y: 0, width: c.clipped && !sticker ? fc.x + s.s : rig.root.bounds.width, height: rig.root.bounds.height)

        // The card in the mouth sits behind the body by order too (a flattened render ignores zPosition).
        if pose.cardBehind, rig.cardCopy.superlayer === clip, clip.sublayers?.firstIndex(of: rig.cardCopy) != 1 {
            rig.cardCopy.removeFromSuperlayer()
            clip.insertSublayer(rig.cardCopy, below: rig.body)
        } else if !pose.cardBehind, clip.sublayers?.last !== rig.cardCopy {
            rig.cardCopy.removeFromSuperlayer()
            clip.addSublayer(rig.cardCopy)
        }

        drawFlap(s, c, sticker: sticker)
        drawEffects(s, c, sticker: sticker)
    }

    private func drawFlap(_ s: CourierScene, _ c: Cat, sticker: Bool) {
        flapG.isHidden = sticker || c.flap <= 0 || c.flapAlpha <= 0
        edgePaw.isHidden = sticker || c.paw <= 0
        let fc = flapCenter(s)
        if !flapG.isHidden {
            flapG.position = fc
            // Its units, y down, slanted like the mockup's (side 1).
            let k = c.flap * s.s
            let m = CGAffineTransform(a: 1, b: 0.12, c: 0, d: 1, tx: 0, ty: 0).concatenating(CGAffineTransform(scaleX: k, y: -k))
            flapG.setAffineTransform(m)
            flapG.opacity = Float(c.flapAlpha)
            let H: CGFloat = 76, W = H * 0.46, top = -H / 2 + 4, len = H - 10
            let cs = cos(c.swing), sn = sin(c.swing)
            let by = top + len * abs(cs), bx = -sn * W * 0.55
            let panel = CGMutablePath()
            panel.move(to: CGPoint(x: -W / 2 + 3, y: top))
            panel.addLine(to: CGPoint(x: W / 2 - 3, y: top))
            panel.addLine(to: CGPoint(x: W / 2 - 3 + bx, y: by))
            panel.addQuadCurve(to: CGPoint(x: -W / 2 + 3 + bx, y: by), control: CGPoint(x: bx, y: by + 6 * abs(cs)))
            panel.closeSubpath()
            flapPanel.path = panel
            flapPanel.fillColor = (cs > 0 ? Self.hex(0xFFD9A0, 0.9) : Self.hex(0xD6AA76, 0.9)).cgColor
            flapPaw.isHidden = abs(cs) <= 0.5
            flapPaw.setAffineTransform(CGAffineTransform(translationX: bx * 0.6, y: (top + by) / 2).scaledBy(x: 1, y: abs(cs)))
        }
        if !edgePaw.isHidden {
            edgePaw.position = CGPoint(x: edgeX(s, -3), y: s.ground + 50 * s.s)
            edgePaw.setAffineTransform(CGAffineTransform(scaleX: c.paw * s.s, y: -c.paw * s.s))
        }
    }

    private func drawEffects(_ s: CourierScene, _ c: Cat, sticker: Bool) {
        let T = sticker ? nil : c.T
        let spot = spotX(s), g = s.ground
        // Paw prints from the skid, every 80 ms, each fading over 300 ms.
        for (i, l) in prints.enumerated() {
            let tb = 250 + Double(i) * 80
            guard let T, T >= tb, T < tb + 300 else { l.isHidden = true; continue }
            l.isHidden = false
            l.opacity = Float(0.55 * (1 - CourierKit.part(T, tb, tb + 300)))
            l.position = CGPoint(x: spot + (36 - 14 * CGFloat(i)) * s.s, y: g - (3 + CGFloat(i % 2) * 4) * s.s)
            l.setAffineTransform(CGAffineTransform(scaleX: 1.2 * s.s, y: -1.2 * 0.55 * s.s))
        }
        // Puffs kicked up by the skid.
        let age = (T ?? -1) - 240
        for (i, l) in puffs.enumerated() {
            guard age >= 0, age <= 420 else { l.isHidden = true; continue }
            let u = CGFloat(age / 420), seed = 9.0
            let a = CGFloat(Self.hash(seed + Double(i)) - 0.5) * .pi * 0.9 * 0.8
            let d = (10 + CGFloat(Self.hash(seed + Double(i) * 3)) * 12) * CourierKit.easeOut(u * 1.4)
            let r = (3 + CGFloat(Self.hash(Double(i) + seed * 7)) * 3.5) * (0.6 + u * 0.9)
            l.isHidden = false
            l.opacity = Float(0.55 * pow(1 - u, 1.4))
            l.position = CGPoint(x: spot + (48 + cos(a) * d) * s.s, y: g + (abs(sin(a)) * d * 0.55 + u * 6) * s.s)
            l.setAffineTransform(CGAffineTransform(scaleX: r * s.s, y: r * s.s))
        }
        // Speed lines behind the burst.
        let showLines = T.map { $0 >= 60 && $0 < 200 } ?? false
        for (i, l) in lines.enumerated() {
            l.isHidden = !showLines
            guard showLines, let T else { continue }
            let a = 1 - CourierKit.part(T, 140, 200)
            let x = c.pose.x + 40 * s.s, y = g + 40 * s.s - (CGFloat(i) - 1) * 9 * s.s
            let len = 30 * (0.6 + CGFloat(Self.hash(Double(i) + 3)) * 0.5) * s.s
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x + 6 * s.s, y: y))
            path.addLine(to: CGPoint(x: x + 6 * s.s + len, y: y))
            l.path = path
            l.lineWidth = 2 * s.s
            l.opacity = Float(0.5 * a)
        }
    }

    // MARK: - Sounds

    func cues(_ plan: CourierPlan) -> [CourierCue] {
        [CourierCue(ms: 50, name: "flap"), CourierCue(ms: courier.landingMS + 40, name: "mrrp"), CourierCue(ms: courier.goneMS - 95, name: "shut")]
    }

    func sound(_ cue: String) -> [Double]? {
        let rate = 44_100.0
        var noise: UInt32 = 0x9E37_79B9
        func white() -> Double {
            noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5
            return Double(noise) / 2_147_483_648 - 1
        }
        func env(_ t: Double, _ attack: Double, _ decay: Double) -> Double { t < 0 ? 0 : t < attack ? t / attack : exp(-(t - attack) / decay) }
        func tone(_ seconds: Double, _ f: (Double) -> Double) -> [Double] { (0..<Int(seconds * rate)).map { f(Double($0) / rate) } }
        switch cue {
        case "flap":
            // A soft wooden "thup" as the flap is batted open.
            return tone(0.12) { t in
                0.45 * sin(2 * .pi * (190 * t - 300 * t * t)) * env(t, 0.003, 0.035) + 0.18 * white() * env(t, 0.001, 0.006)
            }
        case "mrrp":
            // A rolled little chirp, about 400 → 700 Hz in 120 ms.
            return tone(0.16) { t in
                let ph = 2 * .pi * (400 * t + 1250 * t * t)
                let roll = 1 - 0.35 * (0.5 + 0.5 * sin(2 * .pi * 28 * t))
                return 0.32 * (sin(ph) + 0.3 * sin(2 * ph) + 0.12 * sin(3 * ph)) * roll * env(t, 0.012, 0.07)
            }
        case "shut":
            // The flap clacks shut and swings once more.
            return tone(0.2) { t in
                let a = 0.4 * sin(2 * .pi * 160 * t) * env(t, 0.002, 0.03) + 0.14 * white() * env(t, 0.001, 0.005)
                let b = 0.2 * sin(2 * .pi * 210 * (t - 0.075)) * env(t - 0.075, 0.002, 0.025)
                return a + b
            }
        default: return nil
        }
    }

    // MARK: - Paths and helpers

    private static func hash(_ n: Double) -> Double { let x = sin(n * 127.1 + 311.7) * 43758.5453; return x - floor(x) }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rot: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: x, y: y).rotated(by: rot)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
    }

    /// The mockup's capsule leg: 13 long, hanging down from (x, y).
    private static func capsule(_ x: CGFloat, _ y: CGFloat, _ len: CGFloat, _ w: CGFloat) -> CGPath {
        var t = CGAffineTransform(translationX: x, y: y)
        return CGPath(roundedRect: CGRect(x: -w / 2, y: -w / 2, width: w, height: len + w / 2), cornerWidth: w / 2, cornerHeight: w / 2, transform: &t)
    }

    /// The mockup's ear (EARP).
    private static let earShape: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -11, y: 3))
        p.addQuadCurve(to: CGPoint(x: -2, y: -19), control: CGPoint(x: -9, y: -12))
        p.addQuadCurve(to: CGPoint(x: 2.4, y: -19.2), control: CGPoint(x: 0, y: -21.5))
        p.addQuadCurve(to: CGPoint(x: 11, y: 3), control: CGPoint(x: 9.5, y: -12))
        p.closeSubpath()
        return p
    }()

    private static func ear(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat) -> CGPath {
        earShape.copy(using: [CGAffineTransform(translationX: x, y: y).rotated(by: a)])
    }

    private static func tailPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 40, y: -30))
        p.addCurve(to: CGPoint(x: 60, y: -62), control1: CGPoint(x: 56, y: -32), control2: CGPoint(x: 64, y: -46))
        p.addCurve(to: CGPoint(x: 47, y: -69), control1: CGPoint(x: 58, y: -70), control2: CGPoint(x: 51, y: -74))
        return p
    }

    /// The lit part of a shape: itself shifted up-left, clipped to itself (the mockup's rimShade).
    private func lit(_ path: CGPath, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
        path.copy(using: [CGAffineTransform(translationX: dx, y: dy)]).intersection(path)
    }

    /// An ink part for the union outline: filled and stroked at twice the line.
    private func inkPart(_ rig: CourierRig, _ name: String, _ path: CGPath, pivot: CGPoint, in parent: CALayer? = nil) {
        rig.part(name, path, fill: ink, ink: ink, width: lw * 2, pivot: pivot, in: parent)
    }

    private func stroke(_ l: CAShapeLayer) {
        l.fillColor = nil
        l.lineCap = .round
    }

    private func shape(_ path: CGPath, _ fill: NSColor) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.actions = CourierKit.noActions
        l.path = path
        l.fillColor = fill.cgColor
        return l
    }
}

private extension CGPath {
    func copy(using transforms: [CGAffineTransform]) -> CGPath {
        var t = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
        return copy(using: &t) ?? self
    }
}
