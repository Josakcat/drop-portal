//
//  DigbyCourier.swift
//  DropPortal
//
//  Digby the mole on the Mac, "Mole Express": a dutiful little engineer in a
//  yellow hard hat with a headlamp. He tunnels under the screen and comes up
//  from its BOTTOM edge, below the landing spot. While the phone holds the
//  card the soil there stirs: a small mound pushes up out of the bottom edge,
//  hairline cracks run out and his helmet peeks out with the lamp sweeping
//  up. From the bytes (T = 0) a cracked-soil line runs along the bottom edge
//  from the right corner to the mound; it bursts (a few clods, a dust puff,
//  never a fountain), Digby pops out with the card flat on his helmet, lands
//  with a squash, tosses the card up onto its spot (L), salutes with one
//  blink and ducks back down the hole, which flattens behind him.
//
//  The rig, colours and beats are the approved mockup's
//  (`.droppykit/design/fx-mockups-cute-v2/mockups.html`, "Mole Express",
//  `drawMole`, `moleMac`, `mound`, `moundLip`): drawing units, feet at 0,0,
//  y down, about 100 tall. Mockup Mac pixels are scaled by `scene.s`; his
//  ground is the screen's bottom edge (`bottom`), not the mockup's GM. The
//  body and the card copy sit in a clip container whose bottom
//  is the hill's lip, so he really comes out of the ground.
//

import AppKit
import DropPortalCore

@MainActor
final class DigbyCourier: CourierCharacter {
    let courier: Courier = .mole

    // MARK: Colours (the mockup's)

    private enum Ink {
        static let line = srgb(0x2B1A10)
        static let fur = srgb(0x7A5A48)
        static let shade = srgb(0x5E4334)
        static let light = srgb(0xB58E76)
        static let pink = srgb(0xF39AA8)
        static let hat = srgb(0xFFCF3A)
        static let hatShade = srgb(0xE5A51F)
        static let palm = srgb(0xF2B2A4)
        static let palmIn = srgb(0xF7C9BE)
        static let claw = srgb(0xFBEEE0)
        static let noseHi = srgb(0xFFD3DA)
        static let tongue = srgb(0xFF8A9A)
        static let lampRim = srgb(0x9AA3AD)
        static let lampGlass = srgb(0xFFF6C8)
        static let shine = srgb(0xFFF8D8, 0.6)
        static let dirt = srgb(0x8B5E3C)
        static let dirtShade = srgb(0x74492C)
        static let dirtSpeck = srgb(0xA8774F)
        static let dirtHi = NSColor(srgbRed: 1, green: 230 / 255, blue: 200 / 255, alpha: 0.35)
        static let lip = srgb(0x93643F)
        static let lipShade = srgb(0x7A4D2F)
        static let lipSpeck = srgb(0xB5845A)
        static let hole = srgb(0x2A170C)
        static let crumbLight = srgb(0xB08060)
        static let ghost = srgb(0xC9A58E)
        static let puff = NSColor(srgbRed: 1, green: 250 / 255, blue: 240 / 255, alpha: 1)
    }

    /// The mockup's outline: 2 px at kM 0.86, in drawing units.
    private static let kM: CGFloat = 0.86
    private static let lw: CGFloat = 2 / kM
    /// Mockup Mac pixels: the arrival hill under the landing spot and the right edge.
    /// His ground: the stage's bottom edge (the stage is the whole screen, y up).
    private static let bottom: CGFloat = 0

    // MARK: One frame's state (the mockup's `P` beyond the body)

    private struct Mole {
        /// Feet below the ground line, mockup pixels (negative = above).
        var dy: CGFloat = 0
        var sx: CGFloat = 1, sy: CGFloat = 1
        /// Stretch along the vertical, about the middle.
        var vs: CGFloat = 1
        /// Canvas sense: clockwise on screen.
        var rot: CGFloat = 0
        var tilt: CGFloat = 0
        var lookX: CGFloat = 0
        var breath: CGFloat = 0
        var eyes: Eyes = .open
        var mouth: Mouth = .smile
        var salute: CGFloat = 0
        var pawL: CGFloat = 0
        var alpha: CGFloat = 1
        var blink: CGFloat? = nil
    }

    private enum Eyes { case open, wide, happy }
    private enum Mouth { case smile, o, puff }

    private var cur = Mole()

    // MARK: Layers

    private let clip = CALayer()
    private let ghosts = [CAShapeLayer(), CAShapeLayer()]
    private let back = CALayer()
    private let fore = CALayer()
    private let tunnel = CAShapeLayer()
    private let crack = CAShapeLayer()
    private let beam = CALayer()
    private let edgeHill = Hill(lip: false, seed: 7)
    private let hill = Hill(lip: false, seed: 3)
    private let hillLip = Hill(lip: true, seed: 0)
    private let hole = CAShapeLayer()
    private let crumbsR = Crumbs(), crumbsL = Crumbs(), stir = Crumbs()
    private let puffs = CAShapeLayer()

    private var eyeFill: [CAShapeLayer] = [], eyeShine: [CAShapeLayer] = [], eyeLine: [CAShapeLayer] = []
    private var mouthLine = CAShapeLayer(), mouthFill = CAShapeLayer(), tongue = CAShapeLayer()
    private var silhouette = CGMutablePath()

    func build(_ rig: CourierRig) {
        let lw = Self.lw
        // The body and the card copy go into a clip whose floor is the hill's lip.
        clip.anchorPoint = .zero
        clip.masksToBounds = true
        clip.actions = CourierKit.noActions
        rig.root.insertSublayer(clip, above: rig.behind)
        for g in ghosts {
            g.actions = CourierKit.noActions
            g.fillColor = Ink.ghost.cgColor
            g.zPosition = -2
            clip.addSublayer(g)
        }
        rig.body.removeFromSuperlayer()
        rig.cardCopy.removeFromSuperlayer()
        clip.addSublayer(rig.body)
        clip.addSublayer(rig.cardCopy)

        // The stage's own layers: behind (tunnel, crack, beam, hill, hole), in front (lips, crumbs, puffs).
        for layer in [back, fore] {
            layer.frame = rig.root.bounds
            layer.actions = CourierKit.noActions
        }
        rig.behind.addSublayer(back)
        rig.front.addSublayer(fore)
        // Soil-coloured, not ink: along the screen's bottom edge they must read on dark wallpapers too.
        Self.style(tunnel, fill: nil, stroke: Ink.dirtSpeck.withAlphaComponent(0.9))
        tunnel.lineCap = .round
        Self.style(crack, fill: nil, stroke: Ink.dirtSpeck.withAlphaComponent(0.9))
        crack.lineCap = .round
        beam.actions = CourierKit.noActions
        beam.anchorPoint = CGPoint(x: 0, y: 0.5)
        beam.contents = Self.beamImage
        beam.contentsGravity = .resize
        Self.style(hole, fill: Ink.hole, stroke: nil)
        back.addSublayer(tunnel)
        back.addSublayer(beam)
        back.addSublayer(crack)
        back.addSublayer(hill.layer)
        back.addSublayer(hole)
        fore.addSublayer(hillLip.layer)
        fore.addSublayer(edgeHill.layer)
        for c in [crumbsL, crumbsR, stir] { fore.addSublayer(c.layer) }
        Self.style(puffs, fill: Ink.puff, stroke: nil)
        fore.addSublayer(puffs)

        // The body: one outline for the feet and the body together, then the fills.
        let body = Self.moleBody
        let feet = [Self.E(-16, -3, 10, 5.5), Self.E(16, -3, 10, 5.5)]
        let outline = CGMutablePath()
        feet.forEach { outline.addPath($0) }
        outline.addPath(body)
        rig.part("outline", outline, fill: Ink.line, ink: Ink.line, width: lw * 2)
        let feetPath = CGMutablePath()
        feet.forEach { feetPath.addPath($0) }
        rig.part("feet", feetPath, fill: Ink.palm, width: 0)
        // rimShade: the shade on the lower right, the fur where the body overlaps itself moved up-left.
        rig.part("bodyShade", body, fill: Ink.shade, width: 0)
        var up = CGAffineTransform(translationX: -5, y: -6)
        rig.part("fur", body.intersection(body.copy(using: &up)!), fill: Ink.fur, width: 0)
        rig.part("belly", Self.E(0, -14, 25, 16).intersection(body), fill: Ink.light, width: 0)
        rig.part("hilite", Self.E(-24, -62, 7, 4, -0.9), fill: NSColor(white: 1, alpha: 0.25), width: 0)

        // The head: turns about its neck (the mockup's TM, 0, -40).
        let head = rig.part("head", CGMutablePath(), fill: .clear, width: 0, pivot: CGPoint(x: 0, y: -40))
        rig.part("muzzle", Self.E(0, -38, 14, 10), fill: Ink.light, width: 0, in: head)
        for _ in 0..<2 {
            eyeFill.append(rig.part("eyeFill\(eyeFill.count)", CGMutablePath(), fill: Ink.line, width: 0, in: head))
            eyeShine.append(rig.part("eyeShine\(eyeShine.count)", CGMutablePath(), fill: .white, width: 0, in: head))
            let line = rig.part("eyeLine\(eyeLine.count)", CGMutablePath(), fill: .clear, ink: Ink.line, width: lw * 1.4, in: head)
            line.fillColor = nil
            line.lineCap = .round
            eyeLine.append(line)
        }
        // Blush: pink with a white glint, shifted half as far as the look.
        let blush = rig.part("blush", CGMutablePath(), fill: .clear, width: 0, in: head)
        for x: CGFloat in [-25, 25] {
            rig.part("blush\(x)", Self.E(x, -41, 6, 3.4), fill: Ink.pink.withAlphaComponent(0.7), width: 0, in: blush)
            rig.part("glint\(x)", Self.E(x - 6 * 0.35, -41 - 3.4 * 0.3, 6 * 0.22, 3.4 * 0.22), fill: NSColor(white: 1, alpha: 0.7 * 0.55), width: 0, in: blush)
        }
        // The star nose: eight beads round a middle one, one outline for all.
        let nose = rig.part("nose", CGMutablePath(), fill: .clear, width: 0, in: head)
        let beads = CGMutablePath()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            beads.addPath(Self.E(cos(a) * 4.1, -41 + sin(a) * 3.6, 2.4, 2.4))
        }
        beads.addPath(Self.E(0, -41, 2.8, 2.8))
        rig.part("noseLine", beads, fill: Ink.line, ink: Ink.line, width: lw * 1.4, in: nose)
        rig.part("noseFill", beads, fill: Ink.pink, width: 0, in: nose)
        rig.part("noseHi", Self.E(-1.4, -42.6, 1.6, 1.1), fill: Ink.noseHi, width: 0, in: nose)
        mouthFill = rig.part("mouthFill", CGMutablePath(), fill: Ink.line, width: 0, in: head)
        tongue = rig.part("tongue", CGMutablePath(), fill: Ink.tongue, width: 0, in: head)
        mouthLine = rig.part("mouthLine", CGMutablePath(), fill: .clear, ink: Ink.line, width: lw * 1.1, in: head)
        mouthLine.fillColor = nil
        mouthLine.lineCap = .round

        // The hard hat: dome and brim share an outline; the shade, the shine arc and the lamp on top.
        let dome = CGMutablePath()
        dome.move(to: CGPoint(x: -35, y: -63))
        dome.addCurve(to: CGPoint(x: 0, y: -97), control1: CGPoint(x: -35, y: -86), control2: CGPoint(x: -19, y: -97))
        dome.addCurve(to: CGPoint(x: 35, y: -63), control1: CGPoint(x: 19, y: -97), control2: CGPoint(x: 35, y: -86))
        dome.closeSubpath()
        let brim = CGPath(roundedRect: CGRect(x: -40, y: -67, width: 80, height: 8.5), cornerWidth: 4.25, cornerHeight: 4.25, transform: nil)
        let hat = CGMutablePath()
        hat.addPath(dome)
        hat.addPath(brim)
        rig.part("hatLine", hat, fill: Ink.line, ink: Ink.line, width: lw * 2, in: head)
        rig.part("dome", dome, fill: Ink.hat, width: 0, in: head)
        rig.part("domeShade", dome.intersection(Self.E(14, -60, 30, 20)), fill: Ink.hatShade, width: 0, in: head)
        rig.part("brim", brim, fill: Ink.hatShade, width: 0, in: head)
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: 0, y: -63), radius: 27, startAngle: .pi * 1.18, endAngle: .pi * 1.42, clockwise: false)
        let shine = rig.part("shine", arc, fill: .clear, ink: Ink.shine, width: 3, in: head)
        shine.fillColor = nil
        shine.lineCap = .round
        rig.part("lamp", Self.E(0, -81, 8.2, 8.2), fill: Ink.lampRim, ink: Ink.line, width: lw * 2, in: head)
        rig.part("lampGlass", Self.E(0, -81, 5.6, 5.6), fill: Ink.lampGlass, width: 0, in: head)
        rig.part("lampHi", Self.E(-1.8, -83, 1.8, 1.5), fill: .white, width: 0, in: head)

        // Shovel paws, each a group the frame moves: the right one salutes.
        for name in ["pawL", "pawR"] {
            let paw = rig.part(name, CGMutablePath(), fill: .clear, width: 0)
            rig.part(name + "Line", Self.shovel, fill: Ink.line, ink: Ink.line, width: lw * 2, in: paw)
            rig.part(name + "Claw", Self.shovel, fill: Ink.claw, width: 0, in: paw)
            rig.part(name + "Palm", Self.E(0, 5, 10.5, 8.4), fill: Ink.palm, width: 0, in: paw)
            rig.part(name + "Pad", Self.E(0, 3, 5, 3.6), fill: Ink.palmIn, width: 0, in: paw)
        }

        // The smear's silhouette: body, feet and hat.
        silhouette = CGMutablePath()
        silhouette.addPath(outline)
        silhouette.addPath(hat)
    }

    // MARK: The flow

    /// The phone holds the card: a mound pushes up out of the bottom edge, his helmet peeks out, the lamp sweeps.
    func waiting(_ f: CourierFrame, p: CGFloat, ms: Double) -> CourierPose {
        let s = f.scene.s
        let hh = edgeHillHeight(p, ms)
        let tip = Self.tip(p)
        // The mockup's moleWait: just the hard hat above the hill, with a little bob while he waits.
        let bob = 1.4 * sin(2 * .pi * ms / 1100) * tip
        cur = Mole(dy: -hh * 0.6 + 97 * Self.kM - tip * 24 + bob, lookX: -2, alpha: tip > 0 ? 1 : 0)
        cur.tilt = 0.06 * sin(2 * .pi * ms / 1700) * tip
        return pose(cur, x: digX(f.scene), f.scene, s: s)
    }

    /// From the bytes to L: the crack along the bottom, the burst, the pop, the squash and the toss of the card.
    func arrive(_ f: CourierFrame, T: Double) -> CourierPose {
        cur = mac(T)
        var P = pose(cur, x: digX(f.scene), f.scene, s: f.scene.s)
        let L = f.plan.landingMS
        if T < 360 {
            // Flat on the helmet, nodding with the landing.
            var c = onHelmet(P, f.scene)
            c.rot += 0.07 * CourierKit.kick(T - 250, f: 4, z: 0.35) * CGFloat(f.plan.jitter)
            P.card = c
        } else {
            // The toss: up from his helmet at the bottom edge to the spot, landing exactly at L.
            let a = onHelmet(pose(mac(360), x: P.x, f.scene, s: f.scene.s), f.scene).center
            let e = CourierKit.easeOut(CourierKit.part(T, 360, L))
            let lift = 40 * f.scene.s * CGFloat(f.plan.jitter)
            let ctl = CGPoint(x: CourierKit.mix(a.x, f.scene.landing.x, 0.5), y: max(a.y, f.scene.landing.y) + lift)
            let q = CourierKit.qbez(a, ctl, f.scene.landing, e)
            P.card = CardCarry(center: q, scale: CourierKit.mix(0.55, 1, e), rot: -(CourierKit.mix(-0.08, 0, e) - 0.25 * sin(.pi * e)))
        }
        if T < 120 { P.card?.alpha = 0 }
        return P
    }

    /// L to gone: the salute with one blink, then he ducks back down the hole.
    func leave(_ f: CourierFrame, T: Double) -> CourierPose? {
        guard T <= f.plan.courier.goneMS else { return nil }
        cur = mac(T)
        return pose(cur, x: digX(f.scene), f.scene, s: f.scene.s)
    }

    /// Reduce motion: head and helmet out of a small hill on the card's corner, saluting.
    func sticker(_ f: CourierFrame, ms: Double) -> CourierPose {
        cur = Mole(dy: 0, mouth: .smile, salute: 1)
        cur.tilt = -0.06
        var P = CourierPose(x: 0, y: 0)
        P.shadow = 0
        return P
    }

    // MARK: Drawing

    func draw(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame) {
        let m = cur
        var blink = m.blink ?? f.blink
        if case .leaving(let T) = f.moment, T >= 600, T < 680 { blink = max(blink, CGFloat(CourierPlan.lid(T - 610))) }
        rig.set("head", turn: m.tilt)
        rig.set("nose", dx: m.lookX)
        rig.set("blush", dx: m.lookX * 0.5)
        drawEyes(m, blink: blink)
        drawMouth(m)
        drawPaws(rig, m)
        scenery(rig, pose, f)
    }

    private func drawEyes(_ m: Mole, blink: CGFloat) {
        for (i, x0) in [CGFloat(-14), 14].enumerated() {
            let x = x0 + m.lookX, y: CGFloat = -51
            let fill = CGMutablePath(), shine = CGMutablePath(), line = CGMutablePath()
            var lineWidth = Self.lw * 1.4
            switch m.eyes {
            case .happy:
                let rx: CGFloat = 4.1, ry: CGFloat = 4.9
                line.move(to: CGPoint(x: x - rx * 1.15, y: y + ry * 0.35))
                line.addQuadCurve(to: CGPoint(x: x + rx * 1.15, y: y + ry * 0.35), control: CGPoint(x: x, y: y - ry * 1.25))
                lineWidth = Self.lw * 1.5
            case .open, .wide:
                let sc: CGFloat = m.eyes == .wide ? 1.15 : 1, rx = 4.1 * sc, ry = 4.9 * sc
                let b = CourierKit.clamp(blink)
                if b > 0.82 {
                    line.move(to: CGPoint(x: x - rx * 1.1, y: y + ry * 0.1))
                    line.addQuadCurve(to: CGPoint(x: x + rx * 1.1, y: y + ry * 0.1), control: CGPoint(x: x, y: y + ry * 0.85))
                } else {
                    fill.addPath(Self.E(x, y + ry * b * 0.55, rx, ry * (1 - b * 0.92)))
                    if b < 0.45 {
                        shine.addPath(Self.E(x - rx * 0.3, y - ry * 0.36, rx * 0.42, ry * 0.34, -0.4))
                        shine.addPath(Self.E(x + rx * 0.36, y + ry * 0.38, rx * 0.19, rx * 0.19))
                    }
                }
            }
            eyeFill[i].path = fill
            eyeShine[i].path = shine
            eyeLine[i].path = line
            eyeLine[i].lineWidth = lineWidth
        }
    }

    private func drawMouth(_ m: Mole) {
        let x = m.lookX, y: CGFloat = -32.5, s: CGFloat = 0.85
        let line = CGMutablePath(), fill = CGMutablePath(), tip = CGMutablePath()
        switch m.mouth {
        case .smile:
            line.move(to: CGPoint(x: x - 3.4 * s, y: y))
            line.addQuadCurve(to: CGPoint(x: x + 3.4 * s, y: y), control: CGPoint(x: x, y: y + 3.4 * s))
        case .o:
            fill.addPath(Self.E(x, y + 1.2 * s, 2.6 * s, 3.2 * s))
            tip.addPath(Self.E(x, y + 2.6 * s, 1.6 * s, 1.2 * s))
        case .puff:
            line.move(to: CGPoint(x: x - 2 * s, y: y + s))
            line.addLine(to: CGPoint(x: x + 2 * s, y: y + s))
        }
        mouthLine.path = line
        mouthFill.path = fill
        tongue.path = tip
    }

    /// The mockup's paws: the left hangs, the right swings up to the brim and back.
    private func drawPaws(_ rig: CourierRig, _ m: Mole) {
        rig.set("pawL", turn: 0.5 + m.pawL, sx: -1, dx: -26, dy: -34)
        let sal = m.salute
        let ang = CourierKit.mix(72, -112, sal) * .pi / 180
        let len = CourierKit.mix(15, 24, sal) - 9 * sin(.pi * CourierKit.clamp(sal))
        rig.set("pawR", turn: CourierKit.mix(-0.5, -3.3, sal), dx: 31 + cos(ang) * len, dy: -44 + sin(ang) * len)
    }

    // MARK: The ground

    /// Hills, tunnel, crack, beam, crumbs, puffs, the smear and the clip, for this moment.
    private func scenery(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame) {
        let sc = f.scene, s = sc.s, out = 2 * s
        let ground = Self.bottom
        for layer in [tunnel, crack, beam, hole, puffs] as [CALayer] { layer.isHidden = true }
        for g in ghosts { g.isHidden = true }
        for c in [crumbsL, crumbsR, stir] { c.layer.isHidden = true }
        edgeHill.layer.isHidden = true
        hill.layer.isHidden = true
        hillLip.layer.isHidden = true
        back.opacity = 1
        fore.opacity = 1
        let arrivalX = digX(sc)

        switch f.moment {
        case .waiting(let p, let ms):
            let hh = edgeHillHeight(p, ms)
            let grow = CourierKit.easeOut(p / 0.5)
            // Hairline cracks run out both ways along the bottom edge from the mound.
            let crackPath = CGMutablePath()
            for dir: CGFloat in [-1, 1] {
                let pts: [(CGFloat, CGFloat)] = [(26, 2), (34, 6), (42, 3), (52, 8), (60, 4)]
                crackPath.addPath(Self.polyline(pts.map { CGPoint(x: arrivalX + dir * $0.0 * s, y: ground + $0.1 * s) }, upTo: grow))
            }
            crack.path = crackPath
            crack.lineWidth = 2 * s
            crack.isHidden = grow <= 0
            edgeHill.update(at: CGPoint(x: arrivalX, y: ground - s), s: s, w: 30, h: hh, out: out)
            // The lamp sweeps ±10° from inside the hill once his helmet is out.
            let tip = Self.tip(p)
            if tip > 0 {
                let sweep = sin(2 * .pi * ms / 600) * 10 * .pi / 180
                beam.isHidden = false
                beam.opacity = Float(tip)
                beam.bounds = CGRect(x: 0, y: 0, width: 150 * s, height: 56 * s)
                beam.position = CGPoint(x: arrivalX, y: ground + (hh + 2) * s)
                beam.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 2 + 0.25 - sweep))
            }
            // The hill stirs: a few specks hop off it every 0.9 s.
            if p > 0.15 {
                let age = ms.truncatingRemainder(dividingBy: 900)
                stir.update(x: arrivalX - 6 * s, y: ground + hh * s, age: age, n: 3, dir: -1, seed: 5 + floor(ms / 900), life: 300, s: s, scale: 0.7)
            }
            setClip(ground + hh * 0.55 * s, rig)

        case .arriving(let T), .leaving(let T):
            // The waiting mound gives way to the arrival hill in the same spot.
            let edgeH = 18 * 1.6 * (1 - CourierKit.easeIn(CourierKit.part(T, 0, 90)))
            edgeHill.update(at: CGPoint(x: arrivalX, y: ground - s), s: s, w: 30, h: edgeH, out: out)
            // His way under the screen: a cracked-soil line along the bottom edge from the
            // right corner to the hill, cracking in ahead of him, then fading.
            let tu = CourierKit.part(T, 0, 120), tf = 1 - CourierKit.part(T, 760, 1050)
            if tu > 0, tf > 0 {
                let x0 = sc.size.width + 4 * s, n = max(4, Int((x0 - arrivalX) / (14 * s)))
                let pts = (0...n).map { i -> CGPoint in
                    let u = CGFloat(i) / CGFloat(n)
                    return CGPoint(x: CourierKit.mix(x0, arrivalX + 30 * s, u), y: ground + (4 + 4 * Self.hash(CGFloat(i) + 3)) * s)
                }
                tunnel.path = Self.polyline(pts, upTo: tu)
                tunnel.lineWidth = 2.4 * s
                tunnel.lineJoin = .round
                tunnel.opacity = Float(tf)
                tunnel.isHidden = false
            }
            let hh = arrivalHillHeight(T)
            hill.update(at: CGPoint(x: arrivalX, y: ground - 2 * s), s: s, w: 40, h: hh, out: out)
            hillLip.update(at: CGPoint(x: arrivalX, y: ground - 3 * s), s: s, w: 36, h: hh, out: out)
            if T >= 110, T < 1000 {
                let ho = CourierKit.part(T, 110, 150) * (1 - CourierKit.part(T, 900, 1000))
                hole.path = Self.ellipse(CGPoint(x: arrivalX, y: ground - (2 - hh * 0.62) * s), 24 * ho * s, (5 * ho + 1) * s)
                hole.isHidden = ho <= 0
            }
            // The burst: crumbs both ways.
            crumbsR.update(x: arrivalX + 22 * s, y: ground + hh * 0.6 * s, age: T - 120, n: 9, dir: 1, seed: 8, life: 340, s: s)
            crumbsL.update(x: arrivalX - 22 * s, y: ground + hh * 0.6 * s, age: T - 125, n: 7, dir: -1, seed: 12, life: 320, s: s)
            // The smear as he pops: two earlier poses, flat, at 40% and 20%.
            if T > 125, T < 175 {
                for (i, d) in [17.0, 34.0].enumerated() {
                    let g = mac(T - d), gp = self.pose(g, x: arrivalX, sc, s: s)
                    guard g.alpha > 0 else { continue }
                    var t = bodyTransform(gp, sc)
                    ghosts[i].path = silhouette.copy(using: &t)
                    ghosts[i].opacity = i == 0 ? 0.4 : 0.2
                    ghosts[i].isHidden = false
                }
            }
            // Dust as he ducks back down.
            if T >= 740, T < 1180 { drawPuffs(x: arrivalX, y: ground + 4 * s, age: T - 760, s: s) }
            setClip(ground + (hh * 0.55 - 2) * s, rig)

        case .sticker:
            // A small hill on the card's corner, his head and helmet poking out of it.
            let u = sc.unit
            let k = u / s
            back.opacity = Float(pose.alpha)
            fore.opacity = Float(pose.alpha)
            hill.update(at: CGPoint(x: pose.x, y: pose.y), s: s, w: 44 * k, h: 26 * k, out: out)
            hillLip.update(at: CGPoint(x: pose.x, y: pose.y - s), s: s, w: 40 * k, h: 26 * k, out: out)
            setClip(pose.y + 10 * u, rig)
        }
    }

    private func setClip(_ y: CGFloat, _ rig: CourierRig) {
        let size = rig.root.bounds.size
        clip.bounds = CGRect(x: 0, y: y, width: size.width, height: max(0, size.height - y))
        clip.position = CGPoint(x: 0, y: y)
    }

    private func drawPuffs(x: CGFloat, y: CGFloat, age: Double, s: CGFloat) {
        guard age >= 0, age <= 420 else { return }
        let u = CGFloat(age / 420), n = 5, seed: CGFloat = 14
        let path = CGMutablePath()
        for i in 0..<n {
            let fi = CGFloat(i)
            let a = (Self.hash(seed + fi) - 0.5) * .pi * 0.9 - .pi / 2 + (fi / CGFloat(n - 1) - 0.5) * .pi * 1.4
            let d = (10 + Self.hash(seed + fi * 3) * 12) * CourierKit.easeOut(u * 1.4)
            let r = (3 + Self.hash(fi + seed * 7) * 3.5) * (0.6 + u * 0.9)
            let c = CGPoint(x: x + cos(a) * d * s, y: y + (abs(sin(a)) * d * 0.55 + u * 6) * s)
            path.addPath(Self.ellipse(c, r * s, r * s))
        }
        puffs.path = path
        puffs.opacity = Float(0.55 * pow(1 - u, 1.4))
        puffs.isHidden = false
    }

    // MARK: Poses

    /// The waiting mound on the bottom edge, mockup pixels: swells with p, stirs while held.
    private func edgeHillHeight(_ p: CGFloat, _ ms: Double) -> CGFloat {
        let grow = CourierKit.easeOut(p / 0.5)
        return 18 * 1.6 * grow * (1 + 0.035 * CGFloat(sin(2 * .pi * ms / 700)) * CourierKit.clamp((p - 0.3) / 0.3))
    }

    /// How far his hard hat is out of the waiting mound while held.
    private static func tip(_ p: CGFloat) -> CGFloat { CourierKit.easeOut((p - 0.45) / 0.55) }

    /// Where he comes up: on the bottom edge under the landing spot, a little to its right so the toss reads.
    private func digX(_ s: CourierScene) -> CGFloat { s.landing.x + s.card.width * 0.3 }

    /// The arrival hill, mockup pixels: swells with a wobble, holds, flattens behind him.
    private func arrivalHillHeight(_ T: Double) -> CGFloat {
        if T < 120 { return 30 * CourierKit.backOut(CourierKit.part(T, 0, 120), 2.2) }
        if T < 800 { return 30 + 2 * CourierKit.kick(T - 120, f: 5, z: 0.3) }
        return 30 * (1 - CourierKit.easeInOut(CourierKit.part(T, 800, 1050)))
    }

    /// The mockup's `moleMac`, T ms after the bytes.
    private func mac(_ T: Double) -> Mole {
        let kM = Self.kM
        var P = Mole(dy: -6, eyes: .open, mouth: .smile)
        if T < 120 {
            // Still under the hill, coming up the tunnel.
            P.dy = -6 + 100 * kM
            P.vs = 1.15
            P.eyes = .wide
            P.mouth = .o
            P.alpha = 0
            return P
        }
        if T < 200 {
            let r = CourierKit.easeOut(CourierKit.part(T, 120, 200))
            P.dy = -6 + (1 - r) * 100 * kM - 10 * r
            P.vs = CourierKit.mix(1.15, 1.08, CourierKit.part(T, 120, 200))
            P.eyes = .wide
            P.mouth = .o
            P.pawL = 0.5 * CourierKit.kick(T - 125, f: 5, z: 0.3)
            return P
        }
        if T < 300 {
            let u = CourierKit.part(T, 200, 250)
            P.dy = -6 - 10 * (1 - CourierKit.easeIn(u))
            if T >= 250 {
                let q = CourierKit.landSquash(T - 250)
                P.sx = q
                P.sy = 1 / q
            }
            P.mouth = .o
            P.pawL = 0.5 * CourierKit.kick(T - 125, f: 5, z: 0.3)
            P.tilt = 0.08 * CourierKit.kick(T - 250, f: 4, z: 0.35)
            return P
        }
        if T < 420 {
            let q0 = CourierKit.landSquash(T - 250)
            if T < 360 {
                let d = CourierKit.easeInOut(CourierKit.part(T, 300, 360))
                P.sx = q0 * CourierKit.mix(1, 1.1, d)
                P.mouth = .puff
            } else {
                let d = CourierKit.part(T, 360, 420)
                P.sx = CourierKit.mix(1.1, 0.92, CourierKit.easeOut(d * 2))
                P.dy -= 4 * sin(.pi * d)
                P.mouth = .o
            }
            P.sy = 1 / P.sx
            P.lookX = -2 * CourierKit.part(T, 330, 400)
            P.tilt = 0.08 * CourierKit.kick(T - 250, f: 4, z: 0.35) - 0.05 * CourierKit.part(T, 360, 420)
            return P
        }
        if T < 700 {
            let q = 1 + (0.92 - 1) * CourierKit.settle(T - 420, f: 3, z: 0.5)
            P.sx = q
            P.sy = 1 / q
            P.salute = T < 500 ? 0 : T < 580 ? CourierKit.backOut(CourierKit.part(T, 500, 580), 1.4) : 1
            P.tilt = -0.06 * P.salute - 0.05 * (1 - CourierKit.part(T, 420, 520))
            P.lookX = -2 * (1 - CourierKit.easeInOut(CourierKit.part(T, 440, 540)))
            P.breath = 0.014 * sin(2 * .pi * (T - 420) / 900)
            // A proud little puff of the chest on the salute.
            P.pawL = 0.12 * CourierKit.kick(T - 500, f: 4, z: 0.4)
            return P
        }
        P.salute = 1 - CourierKit.easeInOut(CourierKit.part(T, 700, 760))
        let u = CourierKit.part(T, 740, 960)
        P.dy = -6 + CourierKit.easeIn(u) * 110 * kM
        P.sx = 1 - 0.06 * sin(.pi * u)
        P.sy = 1 / P.sx
        P.eyes = T > 760 ? .happy : .open
        return P
    }

    /// A mole state on the stage: feet `dy` mockup pixels below the ground at `x`.
    private func pose(_ m: Mole, x: CGFloat, _ sc: CourierScene, s: CGFloat) -> CourierPose {
        var P = CourierPose(x: x, y: Self.bottom - m.dy * s)
        var sx = m.sx / (1 + m.breath * 0.6), sy = m.sy * (1 + m.breath)
        if m.vs != 1 {
            // Stretch about the middle (44 units up): the feet drop a little.
            sx /= m.vs
            sy *= m.vs
            P.y -= 44 * Self.kM * (m.vs - 1) * s
        }
        P.sx = sx
        P.sy = sy
        P.rot = -m.rot
        P.alpha = m.alpha
        P.shadow = 0
        return P
    }

    /// The body's transform on the stage, as `CourierRig.place` builds it.
    private func bodyTransform(_ P: CourierPose, _ sc: CourierScene) -> CGAffineTransform {
        let u = sc.unit * P.scale
        return CGAffineTransform(translationX: P.x, y: P.y).rotated(by: P.rot).scaledBy(x: P.sx * P.face * u, y: -P.sy * u)
    }

    /// The card flat on the hard hat's top (the drawing's 0, -97), at 55%.
    private func onHelmet(_ P: CourierPose, _ sc: CourierScene, scale: CGFloat = 0.55) -> CardCarry {
        let top = CGPoint(x: 0, y: -97).applying(bodyTransform(P, sc))
        let hh = sc.card.height * scale
        return CardCarry(center: CGPoint(x: top.x - sin(P.rot) * hh / 2, y: top.y + cos(P.rot) * hh / 2), scale: scale, rot: P.rot)
    }

    // MARK: Sounds

    func cues(_ plan: CourierPlan) -> [CourierCue] {
        // Three soft digs while the tunnel runs, a boing as he pops, a tap of the brim, a little sink.
        [CourierCue(ms: 8, name: "dig"), CourierCue(ms: 48, name: "dig"), CourierCue(ms: 88, name: "dig"),
         CourierCue(ms: 128, name: "pop"), CourierCue(ms: 545, name: "salute"), CourierCue(ms: 770, name: "sink")]
    }

    func sound(_ cue: String) -> [Double]? {
        let rate = 44_100.0
        func tone(_ seconds: Double, _ f: (Double) -> Double) -> [Double] { (0..<Int(seconds * rate)).map { f(Double($0) / rate) } }
        func env(_ t: Double, _ attack: Double, _ decay: Double) -> Double { t < attack ? t / attack : exp(-(t - attack) / decay) }
        var noise = CourierRandom(seed: 0x6D6F6C65)
        switch cue {
        case "dig":
            // A soft scrape: low-passed noise over a 140 Hz thump.
            var lp = 0.0
            return tone(0.06) { t in
                lp += 0.18 * ((noise.next() * 2 - 1) - lp)
                return 0.32 * (0.8 * lp + 0.5 * sin(2 * .pi * 140 * t)) * env(t, 0.002, 0.014)
            }
        case "pop":
            // Boing: a pitch that springs up with a wobble.
            var phase = 0.0
            return tone(0.24) { t in
                let f = 300 + 360 * (1 - exp(-t / 0.025)) + 40 * sin(2 * .pi * 17 * t) * exp(-t / 0.08)
                phase += 2 * .pi * f / rate
                return 0.36 * (sin(phase) + 0.25 * sin(2 * phase)) * env(t, 0.004, 0.07)
            }
        case "salute":
            // A tiny bright tap on the brim.
            return tone(0.16) { t in 0.2 * (sin(2 * .pi * 1568 * t) + 0.4 * sin(2 * .pi * 2352 * t)) * env(t, 0.002, 0.04) }
        case "sink":
            // A falling bloop into the ground.
            var phase = 0.0, lp = 0.0
            return tone(0.26) { t in
                let f = 160 + 260 * exp(-t / 0.06)
                phase += 2 * .pi * f / rate
                lp += 0.06 * ((noise.next() * 2 - 1) - lp)
                return 0.3 * (sin(phase) + 0.6 * lp) * env(t, 0.006, 0.07)
            }
        default: return nil
        }
    }

    // MARK: Paths

    private static func E(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ r: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: x, y: y).rotated(by: r)
        return CGPath(ellipseIn: CGRect(x: -max(0.01, rx), y: -max(0.01, ry), width: 2 * max(0.01, rx), height: 2 * max(0.01, ry)), transform: &t)
    }

    static func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ rot: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rot)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
    }

    /// The mockup's teardrop body.
    private static let moleBody: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -90))
        p.addCurve(to: CGPoint(x: 41, y: -50), control1: CGPoint(x: 24, y: -90), control2: CGPoint(x: 39, y: -72))
        p.addCurve(to: CGPoint(x: 0, y: -1), control1: CGPoint(x: 43, y: -26), control2: CGPoint(x: 40, y: -1))
        p.addCurve(to: CGPoint(x: -41, y: -50), control1: CGPoint(x: -40, y: -1), control2: CGPoint(x: -43, y: -26))
        p.addCurve(to: CGPoint(x: 0, y: -90), control1: CGPoint(x: -39, y: -72), control2: CGPoint(x: -24, y: -90))
        p.closeSubpath()
        return p
    }()

    /// A shovel paw: a round palm and three claws.
    private static let shovel: CGPath = {
        let p = CGMutablePath()
        p.addPath(E(0, 6, 10.5, 9))
        for x: CGFloat in [-6, 0, 6] { p.addPath(E(x, 14, 3.6, 3.6)) }
        return p
    }()

    static func hash(_ n: CGFloat) -> CGFloat {
        let x = sin(Double(n) * 127.1 + 311.7) * 43758.5453
        return CGFloat(x - floor(x))
    }

    private static func polyline(_ pts: [CGPoint], upTo u: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first, u > 0 else { return path }
        path.move(to: first)
        let n = CGFloat(pts.count - 1), f = u * n
        for i in 1..<pts.count {
            if CGFloat(i) <= f { path.addLine(to: pts[i]) } else {
                let r = f - CGFloat(i - 1)
                if r > 0 { path.addLine(to: CGPoint(x: CourierKit.mix(pts[i - 1].x, pts[i].x, r), y: CourierKit.mix(pts[i - 1].y, pts[i].y, r))) }
                break
            }
        }
        return path
    }

    static func style(_ layer: CAShapeLayer, fill: NSColor?, stroke: NSColor?) {
        layer.actions = CourierKit.noActions
        layer.fillColor = fill?.cgColor
        layer.strokeColor = stroke?.cgColor
        layer.lineJoin = .round
    }

    /// The headlamp's beam, a soft wedge from #fff3b0 at 35% to nothing (150 × 56 mockup pixels).
    private static let beamImage: CGImage? = {
        let w = 300, h = 112
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.move(to: CGPoint(x: 0, y: CGFloat(h) / 2))
        ctx.addLine(to: CGPoint(x: CGFloat(w), y: 0))
        ctx.addLine(to: CGPoint(x: CGFloat(w), y: CGFloat(h)))
        ctx.closePath()
        ctx.clip()
        let colors = [NSColor(srgbRed: 1, green: 243 / 255, blue: 176 / 255, alpha: 0.35).cgColor,
                      NSColor(srgbRed: 1, green: 243 / 255, blue: 176 / 255, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: CGFloat(w), y: 0), options: [])
        }
        return ctx.makeImage()
    }()
}

// MARK: - A molehill

/// The mockup's `mound` (and `moundLip` with `lip`), in mockup pixels about its
/// base, y down, drawn on the stage at `s` points per pixel.
@MainActor
private final class Hill {
    let layer = CALayer()
    private let line = CAShapeLayer(), fill = CAShapeLayer(), shade = CAShapeLayer(), specks = CAShapeLayer(), hi = CAShapeLayer()
    private let lip: Bool, seed: CGFloat

    init(lip: Bool, seed: CGFloat) {
        self.lip = lip
        self.seed = seed
        layer.actions = CourierKit.noActions
        DigbyCourier.style(line, fill: nil, stroke: srgb(0x2B1A10))
        DigbyCourier.style(fill, fill: lip ? srgb(0x93643F) : srgb(0x8B5E3C), stroke: nil)
        DigbyCourier.style(shade, fill: lip ? srgb(0x7A4D2F) : srgb(0x74492C), stroke: nil)
        DigbyCourier.style(specks, fill: lip ? srgb(0xB5845A) : srgb(0xA8774F), stroke: nil)
        DigbyCourier.style(hi, fill: NSColor(srgbRed: 1, green: 230 / 255, blue: 200 / 255, alpha: 0.35), stroke: nil)
        for l in [line, fill, shade, specks, hi] { layer.addSublayer(l) }
        hi.isHidden = lip
    }

    func update(at base: CGPoint, s: CGFloat, w: CGFloat, h: CGFloat, out: CGFloat) {
        guard h > 0.3 else { layer.isHidden = true; return }
        layer.isHidden = false
        let H = DigbyCourier.hash
        var t = CGAffineTransform(translationX: base.x, y: base.y).scaledBy(x: s, y: -s)
        let p = CGMutablePath()
        let inner: CGPath, dots = CGMutablePath()
        if lip {
            let lh = h * 0.5
            p.move(to: CGPoint(x: -w * 0.9, y: 1))
            p.addCurve(to: CGPoint(x: 0, y: -lh), control1: CGPoint(x: -w * 0.7, y: -lh * 0.7), control2: CGPoint(x: -w * 0.35, y: -lh))
            p.addCurve(to: CGPoint(x: w * 0.9, y: 1), control1: CGPoint(x: w * 0.35, y: -lh), control2: CGPoint(x: w * 0.7, y: -lh * 0.7))
            p.closeSubpath()
            inner = DigbyCourier.ellipse(CGPoint(x: w * 0.35, y: 2), w * 0.7, lh * 0.6)
            for i in 0..<4 {
                let fi = CGFloat(i)
                dots.addPath(DigbyCourier.ellipse(CGPoint(x: (H(fi + 9) - 0.5) * w * 1.2, y: -lh * (0.3 + H(fi * 7) * 0.5)), 1.7, 1.3))
            }
        } else {
            p.move(to: CGPoint(x: -w, y: 1))
            p.addCurve(to: CGPoint(x: -w * 0.1, y: -h), control1: CGPoint(x: -w * 0.75, y: -h * 0.25), control2: CGPoint(x: -w * 0.55, y: -h))
            p.addCurve(to: CGPoint(x: w, y: 1), control1: CGPoint(x: w * 0.35, y: -h * 1.04), control2: CGPoint(x: w * 0.65, y: -h * 0.5))
            p.closeSubpath()
            inner = DigbyCourier.ellipse(CGPoint(x: w * 0.4, y: 0), w * 0.8, h * 0.7)
            for i in 0..<6 {
                let fi = CGFloat(i)
                dots.addPath(DigbyCourier.ellipse(CGPoint(x: (H(fi + seed) - 0.5) * w * 1.3, y: -h * (0.25 + H(fi * 3 + seed) * 0.6)),
                                                  1.8 + H(fi) * 1.6, 1.4 + H(fi + 2)))
            }
            hi.path = p.intersection(DigbyCourier.ellipse(CGPoint(x: -w * 0.3, y: -h * 0.8), w * 0.25, h * 0.12, -0.2)).copy(using: &t)
        }
        line.path = p.copy(using: &t)
        line.lineWidth = out * 2
        fill.path = line.path
        shade.path = p.intersection(inner).copy(using: &t)
        specks.path = p.intersection(dots).copy(using: &t)
    }
}

// MARK: - Crumbs

/// The mockup's `crumbs`: dirt flung out of the hill with gravity, mockup pixels per second.
@MainActor
private final class Crumbs {
    let layer = CALayer()
    private let dark = CAShapeLayer(), light = CAShapeLayer()

    init() {
        layer.actions = CourierKit.noActions
        DigbyCourier.style(dark, fill: srgb(0x8B5E3C), stroke: srgb(0x2B1A10))
        DigbyCourier.style(light, fill: srgb(0xB08060), stroke: srgb(0x2B1A10))
        layer.addSublayer(dark)
        layer.addSublayer(light)
    }

    func update(x: CGFloat, y: CGFloat, age: Double, n: Int, dir: CGFloat, seed: CGFloat, life: Double, s: CGFloat, scale: CGFloat = 1) {
        guard age >= 0, age <= life else { layer.isHidden = true; return }
        layer.isHidden = false
        let H = DigbyCourier.hash, st = CGFloat(age / 1000)
        let a = CGMutablePath(), b = CGMutablePath()
        for i in 0..<n {
            let fi = CGFloat(i)
            let vx = (dir * (40 + H(seed + fi) * 150) + (H(fi + 9) - 0.5) * 60) * scale
            let vy = -(120 + H(seed + fi * 5) * 170) * scale
            let px = x + vx * st * s, py = y - (vy * st + 900 * st * st) * s
            let r = (1.6 + H(fi + seed) * 2.4) * s * max(0.7, scale)
            (i % 3 == 0 ? b : a).addPath(DigbyCourier.ellipse(CGPoint(x: px, y: py), r * 1.15, r, H(fi) * 3))
        }
        dark.path = a
        light.path = b
        dark.lineWidth = 0.8 * s
        light.lineWidth = 0.8 * s
        layer.opacity = Float(1 - CourierKit.easeIn(CGFloat(age / life)))
    }
}
