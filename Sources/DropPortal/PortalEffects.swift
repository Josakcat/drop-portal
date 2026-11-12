//
//  PortalEffects.swift
//  DropPortal
//
//  The Mac half of each crossing effect, in Core Animation layers only:
//  `CardLook` changes the peek card as it comes through the right screen edge
//  (driven by the spring in `LandingPresenter`, so it follows the finger 1:1),
//  and `SeamView` is the light on the edge itself. Both are plain layers, so
//  the harness renders them the same way. Reduce motion: no shape, light only.
//

import AppKit
import DropPortalCore

enum PortalColors {
    static let white = NSColor(srgbRed: 0.9, green: 0.94, blue: 1, alpha: 1)
    static let blue = NSColor(srgbRed: 0.357, green: 0.549, blue: 1, alpha: 1)
    static let water = NSColor(srgbRed: 0.33, green: 0.63, blue: 1, alpha: 1)
    static let violet = NSColor(srgbRed: 0.56, green: 0.48, blue: 1, alpha: 1)
    static let lavender = NSColor(srgbRed: 0.84, green: 0.79, blue: 1, alpha: 1)
    static let cyan = NSColor(srgbRed: 0.45, green: 0.92, blue: 1, alpha: 1)
    static let paper = NSColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)
}

private func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

/// Paper: a grey of the spec's, tinted a little with the effect's colour (more in the shadows).
func paper(_ hex: UInt32, _ alpha: CGFloat, _ p: PortalPalette) -> NSColor {
    let base = srgb(hex, alpha)
    let shade = 1 - base.brightnessComponent
    // The spec's greys are bluish; take their lightness only, so the tint decides the hue.
    let grey = base.brightnessComponent * 0.97
    let neutral = NSColor(srgbRed: grey, green: grey, blue: grey * 1.02, alpha: alpha)
    return (neutral.blended(withFraction: min(0.45, 0.06 + 1.2 * shade), of: p.glow) ?? base).withAlphaComponent(alpha)
}

/// `t` about a point `d` away from the layer's pivot. A layer's
/// sublayerTransform turns about its anchor point, and AppKit gives a view's
/// layer the anchor (0, 0): without this the card would spin about the panel's corner.
func centred(_ t: CATransform3D, _ d: CGPoint) -> CATransform3D {
    CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-d.x, -d.y, 0), t),
                        CATransform3DMakeTranslation(d.x, d.y, 0))
}

/// A lean about the vertical axis, in perspective, and a lift toward the viewer.
func depth(_ lean: CGFloat, _ lift: CGFloat) -> CATransform3D {
    var t = CATransform3DIdentity
    t.m34 = -1 / 900
    t = CATransform3DRotate(t, lean, 0, 1, 0)
    return CATransform3DScale(t, 1 + lift, 1 + lift, 1)
}

/// Runs `body` with implicit animations off.
private func still(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

// MARK: - The card

/// One crossing card's look. `host` is the layer the card sits in, `margin`
/// points larger than the card on every side so a squash, a fold or a plane
/// has room; every whole-card shape goes through `host.sublayerTransform`,
/// about the card's centre. While the finger holds the card everything here
/// follows the drag's progress p (`update`); from the release (`commit`) to
/// the landing (`land`) timed motions own it, on the spec's curves.
@MainActor
final class CardLook {
    /// Room around the card inside its panel.
    static let margin: CGFloat = 160

    /// Tune here.
    enum Look {
        /// Beam's slices; the phone streams the same nine.
        static let beamSlices = 9
        /// Paper plane's folded plane, nose left.
        static let planeSize = CGSize(width: 120, height: 72)
        /// The landing: the card grows this much (a 240 pt card reads small on a whole screen) and springs back.
        static let pop: CGFloat = 1.14
        static let landSeconds: Double = 0.45
        /// Liquid's rounded copy of the photo.
        static let liquidRadius: CGFloat = 64
        /// Paper plane: the photo folds from this p, its halves hinging up to `degrees` at full drag.
        static let planeFold: (from: CGFloat, degrees: CGFloat) = (0.25, 34)
    }

    let effect: PortalEffect
    let calm: Bool
    private let host: CALayer
    private let card: CALayer
    private let cardFrame: CGRect
    private let cardRadius: CGFloat

    private let clip = CALayer()
    /// Portal light and Wormhole: the effect's light washed over the card, never above 18%.
    private var wash: CAGradientLayer?
    /// Liquid: the photo with round corners and a film of water, crossfaded with the card.
    private var rounded: CALayer?
    /// Beam: the card in nine registered slices, and the scanlines over them.
    private var slices: [CALayer] = []
    private var scan: CAReplicatorLayer?
    /// Paper plane: the photo's two halves hinged on the middle crease, their fold shading, and the plane.
    private var wings: [CALayer] = []
    private var folds: [CALayer] = []
    private var crease: CALayer?
    private var plane: CALayer?
    /// The card's shadow while it flies; the panel's own takes over once landed.
    private var shade: CALayer?
    private var hasSnapshot = false
    private var photoImage: CGImage?
    /// Where the drag left the card: p, lean and lift.
    private var held: (p: CGFloat, lean: CGFloat, lift: CGFloat) = (0, 0, 0)
    private(set) var committed = false
    private let palette: PortalPalette
    /// From the host's pivot to the card's centre, for `centred`.
    private var pivot: CGPoint {
        CGPoint(x: cardFrame.midX - host.anchorPoint.x * host.bounds.width,
                y: cardFrame.midY - host.anchorPoint.y * host.bounds.height)
    }
    /// Release to landing (the spec's L); a fade only under Reduce motion.
    var flight: Double { calm ? 0 : effect.flight }

    init(effect: PortalEffect, palette: PortalPalette, calm: Bool, host: CALayer, card: CALayer, cardFrame: CGRect, cardRadius: CGFloat = 18) {
        self.effect = effect
        self.palette = palette
        self.calm = calm
        self.host = host
        self.card = card
        self.cardFrame = cardFrame
        self.cardRadius = cardRadius
        clip.backgroundColor = NSColor.black.cgColor
        clip.frame = host.bounds
        host.mask = clip
        // Reduce motion: no shape and no light on the card, it only fades in.
        guard !calm else { return }
        let shade = CALayer()
        shade.frame = cardFrame
        shade.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: cardFrame.size),
                                  cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.55
        shade.shadowRadius = 22
        shade.shadowOffset = CGSize(width: 0, height: -16)
        shade.opacity = 0
        if card.superlayer === host { host.insertSublayer(shade, below: card) } else { host.insertSublayer(shade, at: 0) }
        self.shade = shade
        switch effect {
        case .portal, .wormhole: wash = edgeLight([palette.core, palette.glow.withAlphaComponent(0.6), palette.glow.withAlphaComponent(0)])
        case .liquid: buildRounded(palette)
        case .beam: buildSlices(palette)
        case .plane: buildWings(palette)
        }
    }

    private func edgeLight(_ colors: [NSColor]) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.frame = cardFrame
        layer.cornerRadius = cardRadius
        layer.cornerCurve = .continuous
        layer.startPoint = CGPoint(x: 1, y: 0.5)
        layer.endPoint = CGPoint(x: 0, y: 0.5)
        layer.colors = colors.map(\.cgColor)
        layer.locations = [0, 0.45, 1]
        layer.opacity = 0
        host.addSublayer(layer)
        return layer
    }

    private func buildRounded(_ p: PortalPalette) {
        let copy = CALayer()
        copy.frame = cardFrame
        copy.cornerRadius = Look.liquidRadius
        copy.cornerCurve = .continuous
        copy.masksToBounds = true
        copy.contentsGravity = .resize
        let film = CAGradientLayer()
        film.type = .radial
        film.frame = copy.bounds
        film.startPoint = CGPoint(x: 0.3, y: 0.75)
        film.endPoint = CGPoint(x: 1.2, y: -0.2)
        film.colors = [NSColor.white.withAlphaComponent(0.55), p.glow.withAlphaComponent(0.22), p.glow.withAlphaComponent(0.3)].map(\.cgColor)
        film.locations = [0, 0.3, 1]
        copy.addSublayer(film)
        copy.opacity = 0
        host.addSublayer(copy)
        rounded = copy
    }

    private func buildSlices(_ p: PortalPalette) {
        let n = Look.beamSlices
        let h = cardFrame.height / CGFloat(n)
        for i in 0..<n {
            let slice = CALayer()
            // Slice 0 is the top one (layer space has y up).
            let y = cardFrame.height - CGFloat(i + 1) * h
            slice.frame = CGRect(x: cardFrame.minX, y: cardFrame.minY + y, width: cardFrame.width, height: h)
            slice.contentsRect = CGRect(x: 0, y: y / cardFrame.height, width: 1, height: h / cardFrame.height)
            slice.contentsGravity = .resize
            slice.opacity = 0
            host.addSublayer(slice)
            slices.append(slice)
        }
        // Thin lines, 1 pt every 8 pt, over the slices.
        let lines = CAReplicatorLayer()
        lines.frame = cardFrame
        lines.cornerRadius = cardRadius
        lines.masksToBounds = true
        let line = CAGradientLayer()
        line.frame = CGRect(x: 0, y: 0, width: cardFrame.width, height: 1)
        line.startPoint = CGPoint(x: 1, y: 0.5)
        line.endPoint = CGPoint(x: 0, y: 0.5)
        line.colors = [p.core.cgColor, p.glow.withAlphaComponent(0.35).cgColor]
        lines.addSublayer(line)
        lines.instanceCount = Int(cardFrame.height / 8)
        lines.instanceTransform = CATransform3DMakeTranslation(0, 8, 0)
        lines.opacity = 0
        host.addSublayer(lines)
        scan = lines
    }

    private func buildWings(_ p: PortalPalette) {
        let half = cardFrame.width / 2
        for left in [true, false] {
            let wing = CALayer()
            wing.bounds = CGRect(x: 0, y: 0, width: half, height: cardFrame.height)
            // Hinged on the middle crease.
            wing.anchorPoint = CGPoint(x: left ? 1 : 0, y: 0.5)
            wing.position = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
            wing.contentsRect = CGRect(x: left ? 0 : 0.5, y: 0, width: 0.5, height: 1)
            wing.contentsGravity = .resize
            wing.cornerRadius = cardRadius
            wing.maskedCorners = left ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            wing.masksToBounds = true
            wing.opacity = 0
            // Fold light: the paper's light and shaded folds, stronger the more it is folded.
            let fold = CAGradientLayer()
            fold.frame = wing.bounds
            fold.startPoint = CGPoint(x: left ? 1 : 0, y: 0.5)
            fold.endPoint = CGPoint(x: left ? 0 : 1, y: 0.5)
            fold.colors = (left ? [paper(0xCDD6EC, 0.9, p), paper(0xF5F7FF, 0.5, p)] : [paper(0x98A5C4, 0.95, p), paper(0xCDD6EC, 0.55, p)]).map(\.cgColor)
            fold.opacity = 0
            wing.addSublayer(fold)
            folds.append(fold)
            host.addSublayer(wing)
            wings.append(wing)
        }
        let line = CAGradientLayer()
        line.frame = CGRect(x: cardFrame.midX - 1.5, y: cardFrame.minY, width: 3, height: cardFrame.height)
        line.colors = [NSColor.white.withAlphaComponent(0), NSColor.white, NSColor.white.withAlphaComponent(0)].map(\.cgColor)
        line.opacity = 0
        host.addSublayer(line)
        crease = line

        let size = Look.planeSize
        let group = CALayer()
        group.bounds = CGRect(origin: .zero, size: size)
        group.position = CGPoint(x: cardFrame.midX, y: cardFrame.midY)
        // Nose on the left, where it is heading. Layer space: y up.
        func shape(_ points: [CGPoint], _ color: NSColor) -> CAShapeLayer {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = color.cgColor
            layer.lineJoin = .round
            return layer
        }
        let w = size.width, h = size.height
        group.addSublayer(shape([CGPoint(x: 0, y: h * 0.5), CGPoint(x: w, y: h), CGPoint(x: w * 0.63, y: 0)], paper(0xF5F7FF, 1, p)))
        group.addSublayer(shape([CGPoint(x: 0, y: h * 0.5), CGPoint(x: w, y: h), CGPoint(x: w * 0.47, y: h * 0.35)], paper(0xCDD6EC, 1, p)))
        group.addSublayer(shape([CGPoint(x: w * 0.47, y: h * 0.35), CGPoint(x: w * 0.63, y: 0), CGPoint(x: w * 0.55, y: h * 0.38)], paper(0x98A5C4, 1, p)))
        // The plane glows in the effect's colour.
        group.shadowColor = p.glow.cgColor
        group.shadowOpacity = 0.9
        group.shadowRadius = 10
        group.shadowOffset = .zero
        group.opacity = 0
        host.addSublayer(group)
        plane = group
    }

    /// Beam's slices, Liquid's rounded copy and Paper plane's wings are pictures of the card.
    var wantsSnapshot: Bool { !calm && (effect == .beam || effect == .liquid || effect == .plane) }

    /// The card's picture. Taken again when the thumbnail arrives.
    func setSnapshot(_ image: CGImage?) {
        photoImage = image
        hasSnapshot = image != nil
        still {
            for layer in slices + wings { layer.contents = image }
            rounded?.contents = image
        }
    }

    /// Hides everything right of `maxX` (host coordinates): the card never shows on a screen to the right.
    func clip(toMaxX maxX: CGFloat) {
        still { clip.frame = CGRect(x: 0, y: 0, width: max(0, min(host.bounds.width, maxX)), height: host.bounds.height) }
    }

    /// The whole card's shape: scale, a turn in the screen's plane (degrees),
    /// then the lean and lift of depth, about the card's centre.
    private func pose(_ sx: CGFloat, _ sy: CGFloat, turn: CGFloat = 0, lean: CGFloat = 0, lift: CGFloat = 0) -> CATransform3D {
        centred(CATransform3DConcat(CATransform3DScale(turnZ(turn), sx, sy, 1), depth(lean, lift)), pivot)
    }

    /// Each effect's held shape at progress p: scale x, scale y, turn. The
    /// stage's halo takes the same shape.
    private func heldShape(_ p: CGFloat) -> (CGFloat, CGFloat, CGFloat) { Self.heldShape(effect, p) }

    static func heldShape(_ effect: PortalEffect, _ p: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        switch effect {
        case .wormhole: (0.78 + 0.22 * p, 0.78 + 0.22 * p, 18 * (1 - p))
        case .liquid: (0.9 + 0.26 * p, 1.08 - 0.2 * p, 0)
        default: (1, 1, 0)
        }
    }

    private func wingAngle(_ degrees: CGFloat, left: Bool) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = -1 / 800
        return CATransform3DRotate(t, (left ? degrees : -degrees) * .pi / 180, 0, 1, 0)
    }

    /// One frame of the drag: `progress` is the spec's p (0 at the edge, 1 at
    /// the landing spot), `velocity` points a second (negative while it comes in).
    func update(progress: CGFloat, velocity: CGFloat, leaving: Bool) {
        guard !calm, !committed else { return }
        let p = clamp01(progress)
        still {
            // Depth: the card leans into its speed and lifts a little toward you.
            let lean = max(-0.4, min(0.4, -velocity / 2600))
            let lift = min(0.07, abs(velocity) / 10000)
            held = (p, lean, lift)
            let (sx, sy, turn) = heldShape(p)
            switch effect {
            case .portal, .wormhole:
                wash?.opacity = Float(0.18 * pow(p, 0.7))
            case .liquid:
                let k = hasSnapshot ? seg(p, 0.35, 0.8) : 0
                rounded?.opacity = Float(k)
                card.opacity = Float(1 - k)
            case .beam:
                // Nine registered slices, each trailing a little more toward the seam.
                card.opacity = hasSnapshot ? 0 : 1
                for (i, slice) in slices.enumerated() {
                    slice.opacity = hasSnapshot ? 1 : 0
                    slice.setAffineTransform(CGAffineTransform(translationX: 90 * (1 - p) * CGFloat(i) / 8, y: 0))
                }
                scan?.opacity = Float(0.3 * seg(p, 0.4, 1))
            case .plane:
                // The photo folds as it comes: its two halves take over past p = 0.25 and hinge up with p.
                let k = hasSnapshot ? seg(p, Look.planeFold.from, 1) : 0
                card.opacity = Float(1 - seg(k, 0, 0.15))
                for (i, wing) in wings.enumerated() {
                    wing.opacity = Float(seg(k, 0, 0.15))
                    wing.transform = wingAngle(Look.planeFold.degrees * k, left: i == 0)
                    folds[i].opacity = Float(0.55 * k)
                }
                crease?.opacity = Float(0.7 * k)
            }
            host.sublayerTransform = pose(sx, sy, turn: turn, lean: lean, lift: lift)
            shade?.opacity = Float(0.45 + lift * 5)
        }
    }

    /// The release, `t` = 0: the card's material flies to its landing over
    /// `flight` on the spec's travel curve. `still` draws that instant.
    func commit(still t: Double? = nil) {
        guard !calm, !committed else { return }
        committed = true
        let L = CGFloat(effect.flight), h = held
        let (sx0, sy0, turn0) = heldShape(h.p)
        // Where each effect's material ends the flight.
        let (sx1, sy1): (CGFloat, CGFloat) = effect == .liquid ? (1.08, 0.94) : (1, 1)
        let (sxStart, syStart) = effect == .portal ? (1.04 * sx0, 0.98 * sy0) : (sx0, sy0)
        timeline(host, Double(L), still: t, key: "sublayerTransform", transform: { s in
            let u = seg(s, 0, L, .travel)
            return self.pose(lerp(sxStart, sx1, u), lerp(syStart, sy1, u), turn: lerp(turn0, 0, u),
                             lean: lerp(h.lean, 0, u), lift: lerp(h.lift, 0, u))
        })
        switch effect {
        case .portal, .wormhole:
            if let wash { let o = CGFloat(wash.opacity); timeline(wash, Double(L), still: t, opacity: { s in o * (1 - seg(s, 0, L, .retire)) }) }
        case .liquid:
            guard hasSnapshot, let rounded else { break }
            let o = CGFloat(rounded.opacity)
            timeline(rounded, 0.1, still: t, opacity: { s in lerp(o, 1, seg(s, 0, 0.1)) })
            timeline(card, 0.1, still: t, opacity: { s in lerp(1 - o, 0, seg(s, 0, 0.1)) })
        case .beam:
            guard hasSnapshot else { break }
            // The slices lock one after another, 12 ms apart, top first: the last at L.
            for (i, slice) in slices.enumerated() {
                let x0 = 90 * (1 - h.p) * CGFloat(i) / 8, start = 0.012 * CGFloat(i)
                timeline(slice, Double(L), still: t, transform: { s in
                    CATransform3DMakeTranslation(x0 * (1 - seg(s, start, start + 0.224, .travel)), 0, 0)
                })
            }
            if let scan { let o = CGFloat(scan.opacity); timeline(scan, 0.1, still: t, opacity: { s in lerp(o, 0.3, seg(s, 0, 0.1)) }) }
        case .plane:
            guard hasSnapshot else { break }
            still { card.opacity = 0 }
            let k0 = seg(h.p, Look.planeFold.from, 1), loopEnd = L - 0.1
            if let crease { timeline(crease, 0.09, still: t, opacity: { s in 0.7 * k0 * (1 - seg(s, 0, 0.09)) }) }
            // 0–90 ms: the halves fold to 68° and turn into the plane; it loops; 100 ms before L the wings open to 20°.
            for (i, wing) in wings.enumerated() {
                let left = i == 0
                timeline(wing, Double(L), still: t, opacity: { s in
                    s < loopEnd ? lerp(max(k0, 1), 0, seg(s, 0.06, 0.09, .retire)) : seg(s, loopEnd, loopEnd + 0.03)
                }, transform: { s in
                    s < loopEnd ? self.wingAngle(lerp(Look.planeFold.degrees * k0, 68, seg(s, 0, 0.09, .travel)), left: left)
                        : self.wingAngle(lerp(68, 20, seg(s, loopEnd, L, .travel)), left: left)
                })
                timeline(folds[i], Double(L), still: t, opacity: { s in s < loopEnd ? lerp(0.55 * k0, 0.8, seg(s, 0, 0.09)) : lerp(0.8, 0.3, seg(s, loopEnd, L)) })
            }
            if let plane {
                let base = plane.position, r: CGFloat = 56
                timeline(plane, Double(L), still: t, opacity: { s in
                    s < loopEnd ? seg(s, 0.06, 0.09) : 1 - seg(s, loopEnd, loopEnd + 0.04, .retire)
                }, transform: { s in
                    let phi = 2 * .pi * seg(s, 0.09, loopEnd, .inOut)
                    return spin(1 + 0.15 * sin(phi / 2), -phi)
                }, position: { s in
                    let phi = 2 * .pi * seg(s, 0.09, loopEnd, .inOut)
                    return CGPoint(x: base.x - r * sin(phi), y: base.y + r - r * cos(phi))
                })
            }
        }
    }

    /// The card is at its spot (the spec's L), `t` = 0: it grows and springs
    /// back with its effect's squash, and its material becomes the card.
    func land(still t: Double? = nil) {
        guard !calm else { return }
        let P = effect == .beam ? 1 + (Look.pop - 1) * 0.6 : Look.pop
        // Uniform pop: up to P at 70 ms, a small dip, settled at 0.45 s (beam: no bounce).
        let pop = effect == .beam ? keys([(0, 1), (0.07, P), (0.3, 1)]) : keys([(0, 1), (0.07, P), (0.2, 0.985), (0.3, 1.006), (0.45, 1)])
        let (qx, qy): ((CGFloat) -> CGFloat, (CGFloat) -> CGFloat) = switch effect {
        case .portal: (keys([(0, 1), (0.07, 1.025), (0.25, 1)]), keys([(0, 1), (0.07, 0.985), (0.25, 1)]))
        case .liquid: (keys([(0, 1.08), (0.032, 1.10), (0.16, 0.96), (0.28, 1.012), (0.42, 1)]),
                       keys([(0, 0.94), (0.032, 0.90), (0.16, 1.035), (0.28, 0.994), (0.42, 1)]))
        case .plane: (keys([(0, 1), (0.12, 1.035), (0.25, 0.992), (0.35, 1.003), (0.45, 1)]),
                      keys([(0, 1), (0.12, 0.98), (0.25, 1.006), (0.35, 0.998), (0.45, 1)]))
        case .wormhole, .beam: ({ _ in 1 }, { _ in 1 })
        }
        timeline(host, Look.landSeconds, still: t, key: "sublayerTransform", transform: { s in
            let k = pop(s)
            return self.pose(k * qx(s), k * qy(s))
        })

        switch effect {
        case .portal, .wormhole:
            // The card turns crisp: a sheen crosses it.
            let white = NSColor.white
            let sheen = CAGradientLayer()
            sheen.frame = cardFrame
            sheen.cornerRadius = cardRadius
            sheen.cornerCurve = .continuous
            sheen.masksToBounds = true
            sheen.colors = [white.withAlphaComponent(0.05), white.withAlphaComponent(0.85), white.withAlphaComponent(0.1)].map(\.cgColor)
            sheen.startPoint = CGPoint(x: 0, y: 1)
            sheen.endPoint = CGPoint(x: 1, y: 0)
            sheen.opacity = 0
            host.addSublayer(sheen)
            timeline(sheen, 0.36, still: t, opacity: { s in s < 0.04 ? 0.45 * seg(s, 0, 0.04) : 0.45 * (1 - seg(s, 0.04, 0.36, .retire)) })
        case .liquid:
            guard hasSnapshot, let rounded else { break }
            // The rounded copy and the photo crossfade: the drop becomes the file again.
            timeline(rounded, 0.12, still: t, opacity: { s in 1 - seg(s, 0, 0.12, .retire) })
            timeline(card, 0.12, still: t, opacity: { s in seg(s, 0, 0.12, .retire) })
        case .beam:
            guard hasSnapshot else { break }
            for slice in slices { timeline(slice, 0.08, still: t, opacity: { s in 1 - seg(s, 0, 0.08, .retire) }) }
            timeline(card, 0.08, still: t, opacity: { s in seg(s, 0, 0.08, .retire) })
            if let scan { timeline(scan, 0.1, still: t, opacity: { s in 0.3 * (1 - seg(s, 0, 0.1, .retire)) }) }
            blade(still: t)
        case .plane:
            guard hasSnapshot else { break }
            // Large triangular photo-bearing flaps sit inside the paper silhouette.
            // Their masks and pixels are fixed; only hinge transform/opacity animate.
            for top in [true, false] {
                let flap = CALayer()
                flap.bounds = CGRect(x: 0, y: 0, width: 340, height: 100)
                flap.position = CGPoint(x: cardFrame.midX, y: top ? cardFrame.maxY + 22 : cardFrame.minY - 22)
                flap.contents = photoImage
                flap.contentsGravity = .resizeAspectFill
                let mask = CAShapeLayer(), path = CGMutablePath()
                path.addLines(between: [CGPoint(x: 0, y: top ? 100 : 0), CGPoint(x: 240, y: top ? 65 : 35), CGPoint(x: 340, y: top ? 0 : 100)])
                path.closeSubpath(); mask.path = path; flap.mask = mask
                host.addSublayer(flap)
                timeline(flap, 0.30, still: t, opacity: { s in 1 - seg(s, 0.12, 0.30, .retire) },
                         transform: { s in CATransform3DMakeRotation((top ? -1 : 1) * 0.22 * seg(s, 0, 0.3), 1, 0, 0) })
            }
            // The wings open flat into the photograph, a crease of light down the middle.
            for (i, wing) in wings.enumerated() {
                let left = i == 0
                timeline(wing, 0.16, still: t, opacity: { s in 1 - seg(s, 0.12, 0.16) },
                         transform: { s in self.wingAngle(lerp(20, 0, seg(s, 0, 0.12, .travel)), left: left) })
                timeline(folds[i], 0.12, still: t, opacity: { s in 0.3 * (1 - seg(s, 0, 0.12)) })
            }
            if let crease { timeline(crease, 0.12, still: t, opacity: { s in 0.7 * (1 - seg(s, 0, 0.12, .retire)) }) }
            timeline(card, 0.12, still: t, opacity: { s in seg(s, 0.04, 0.12, .retire) })
        }
    }

    /// Beam: a 3 pt blade of light crosses the rebuilt card right to left in 96 ms.
    private func blade(still t: Double?) {
        let p = palette
        let blade = CALayer()
        blade.bounds = CGRect(x: 0, y: 0, width: 28, height: cardFrame.height * 1.3)
        let glow = CAGradientLayer()
        glow.frame = blade.bounds
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.colors = [p.glow.withAlphaComponent(0), p.glow.withAlphaComponent(0.55), p.glow.withAlphaComponent(0)].map(\.cgColor)
        blade.addSublayer(glow)
        let core = CAGradientLayer()
        core.frame = CGRect(x: 12.5, y: 0, width: 3, height: blade.bounds.height)
        core.colors = [NSColor.white.withAlphaComponent(0), NSColor.white, NSColor.white.withAlphaComponent(0)].map(\.cgColor)
        blade.addSublayer(core)
        blade.opacity = 0
        host.addSublayer(blade)
        let y = cardFrame.midY, x0 = cardFrame.maxX, x1 = cardFrame.minX
        timeline(blade, 0.16, still: t, opacity: { s in s < 0.096 ? 0.95 : 0.95 * (1 - seg(s, 0.096, 0.16, .retire)) },
                 position: { s in CGPoint(x: lerp(x0, x1, seg(s, 0, 0.096)), y: y) })
    }

    /// The card has landed mid-screen: nothing to hide any more.
    func unclip() {
        host.mask = nil
        var fade = Motion(0.2)
        fade.opacity = { _ in 0 }
        if let shade { fade.run(on: shade) }
    }

    func stop() {
        host.removeAllAnimations()
        host.sublayers?.forEach { $0.removeAllAnimations() }
        host.mask = nil
    }
}

// MARK: - The seam

/// The light on the screen's right edge where a card comes through, one look
/// per effect: Portal light's soft seam, Liquid's bulge of water, Wormhole's
/// edge line, Beam's scanlines and Paper plane's breeze. `setIntensity`
/// follows the drag; `retire` plays the send or the cancel.
final class SeamView: NSView {
    /// Look: the numbers to tweak for Portal light. `gain` multiplies the glow alphas, widths are points.
    enum Look {
        static let gain: CGFloat = 2
        static let coreWidth: CGFloat = 40
        static let haloWidth: CGFloat = 150
        static let rippleSeconds: Double = 0.4
        static let rippleScale: CGFloat = 2.1
        static let ringRadius: CGFloat = 140
    }
    /// The light itself: most of the screen's height, against the edge.
    static func lightSize(screenHeight: CGFloat) -> NSSize {
        NSSize(width: Look.haloWidth + 24, height: min(1000, max(480, screenHeight * 0.82)))
    }

    /// The panel: the edge's whole height and wide enough for the send's
    /// bloom (2.1 times the light) and the breeze blowing in, so no part of
    /// the light ever reaches the panel's edge.
    static func size(screenHeight: CGFloat) -> NSSize {
        NSSize(width: ((Look.haloWidth + 24) * (Look.rippleScale + 0.15)).rounded(), height: screenHeight)
    }

    private let effect: PortalEffect
    private let palette: PortalPalette
    private let calm: Bool
    private let root = CALayer()
    /// What a send animates: the bloom, the ring, the water, the lines or the wind.
    private let feature = CALayer()
    private var bulge: CAShapeLayer?

    /// `centerY`: where on the panel the light is centred (the card's height).
    init(frame: NSRect, effect: PortalEffect, palette: PortalPalette, calm: Bool, centerY: CGFloat? = nil) {
        self.effect = effect
        self.palette = palette
        self.calm = calm
        super.init(frame: frame)
        wantsLayer = true
        let light = Self.lightSize(screenHeight: frame.height)
        root.frame = CGRect(x: frame.width - light.width, y: (centerY ?? frame.height / 2) - light.height / 2,
                            width: light.width, height: light.height)
        layer?.addSublayer(root)
        feature.frame = root.bounds
        switch effect {
        case .portal: buildPortal()
        case .liquid: buildLiquid()
        case .wormhole: buildWormhole()
        case .beam: buildBeam()
        case .plane: buildPlane()
        }
    }

    required init?(coder: NSCoder) { nil }

    private var w: CGFloat { root.bounds.width }
    private var h: CGFloat { root.bounds.height }

    private func radial(_ colors: [NSColor], _ locations: [NSNumber], frame: CGRect) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = CGPoint(x: 1, y: 0.5)
        layer.endPoint = CGPoint(x: 0, y: 1)
        layer.colors = colors.map(\.cgColor)
        layer.locations = locations
        layer.frame = frame
        return layer
    }

    /// A band brightest on the edge, fading out at its ends, and a thin line on it.
    private func edgeLine(_ color: NSColor, glow: NSColor, alpha: CGFloat) {
        let band = CAGradientLayer()
        band.frame = CGRect(x: w - Look.coreWidth, y: h * 0.1, width: Look.coreWidth, height: h * 0.8)
        band.startPoint = CGPoint(x: 1, y: 0.5)
        band.endPoint = CGPoint(x: 0, y: 0.5)
        band.colors = [color.withAlphaComponent(min(1, 0.7 * alpha)).cgColor,
                       glow.withAlphaComponent(min(1, 0.35 * alpha)).cgColor, glow.withAlphaComponent(0).cgColor]
        band.locations = [0, 0.4, 1]
        let fadeMask = CAGradientLayer()
        fadeMask.frame = band.bounds
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.25, 0.75, 1]
        band.mask = fadeMask
        root.addSublayer(band)

        let core = CAGradientLayer()
        core.frame = CGRect(x: w - 3, y: h * 0.1, width: 3, height: h * 0.8)
        core.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        core.shadowColor = glow.cgColor
        core.shadowOffset = .zero
        core.shadowRadius = 14
        core.shadowOpacity = 1
        root.addSublayer(core)
    }

    private func buildPortal() {
        let g = Look.gain, white = palette.core, blue = palette.glow
        root.addSublayer(radial([white.withAlphaComponent(0.8 * g), blue.withAlphaComponent(0.38 * g),
                                 blue.withAlphaComponent(0.12 * g), blue.withAlphaComponent(0)],
                                [0, 0.3, 0.6, 1], frame: root.bounds))
        let bloom = radial([white, blue.withAlphaComponent(0.8), blue.withAlphaComponent(0)], [0, 0.45, 1], frame: root.bounds)
        bloom.opacity = 0
        // Scale toward the screen edge, not around the middle.
        bloom.anchorPoint = CGPoint(x: 1, y: 0.5)
        bloom.position = CGPoint(x: w, y: h / 2)
        feature.addSublayer(bloom)
        root.addSublayer(feature)
        edgeLine(white, glow: blue, alpha: g / 2)
    }

    private func buildLiquid() {
        let water = palette.glow
        root.addSublayer(radial([water.withAlphaComponent(0.7), palette.accent.withAlphaComponent(0.25), water.withAlphaComponent(0)],
                                [0, 0.5, 1], frame: root.bounds))
        // Water bulging out of the edge, lit from the left.
        let body = CAGradientLayer()
        body.frame = root.bounds
        body.startPoint = CGPoint(x: 1, y: 0.5)
        body.endPoint = CGPoint(x: 0.55, y: 0.5)
        body.colors = [water.cgColor, palette.accent.withAlphaComponent(0.95).cgColor, palette.core.withAlphaComponent(0.95).cgColor]
        body.locations = [0, 0.8, 1]
        let shape = CAShapeLayer()
        body.mask = shape
        feature.addSublayer(body)
        root.addSublayer(feature)
        bulge = shape
        setBulge(0)
    }

    private func setBulge(_ value: CGFloat) {
        let bw = 14 + 80 * value, bh = h * (0.25 + 0.5 * value)
        bulge?.path = CGPath(ellipseIn: CGRect(x: w - bw, y: h / 2 - bh / 2, width: bw * 2, height: bh), transform: nil)
    }

    private func buildWormhole() {
        // The stage draws the rims; the seam is only the edge they open from.
        root.addSublayer(feature)
        edgeLine(palette.core, glow: palette.glow, alpha: 1.3)
    }

    private func buildBeam() {
        let lines = CAReplicatorLayer()
        lines.frame = CGRect(x: 0, y: h * 0.12, width: w, height: h * 0.76)
        let line = CAGradientLayer()
        line.frame = CGRect(x: w - 130, y: 0, width: 130, height: 1.5)
        line.startPoint = CGPoint(x: 1, y: 0.5)
        line.endPoint = CGPoint(x: 0, y: 0.5)
        line.colors = [palette.glow.cgColor, palette.accent.withAlphaComponent(0).cgColor]
        lines.addSublayer(line)
        lines.instanceCount = Int(lines.frame.height / 7)
        lines.instanceTransform = CATransform3DMakeTranslation(0, 7, 0)
        let fadeMask = CAGradientLayer()
        fadeMask.frame = lines.bounds
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.2, 0.8, 1]
        lines.mask = fadeMask
        feature.addSublayer(lines)
        root.addSublayer(feature)
        edgeLine(palette.core, glow: palette.glow, alpha: 1.3)
    }

    private func buildPlane() {
        root.addSublayer(radial([palette.core.withAlphaComponent(0.6), palette.glow.withAlphaComponent(0.3),
                                 palette.glow.withAlphaComponent(0)], [0, 0.5, 1], frame: root.bounds))
        // A breeze: three dashed streaks blowing in from the edge.
        for (i, (y, length)) in [(0.56, 96.0), (0.47, 70.0), (0.4, 84.0)].enumerated() {
            let streak = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: w - 6, y: h * y))
            path.addLine(to: CGPoint(x: w - 6 - length, y: h * y))
            streak.path = path
            streak.strokeColor = palette.core.withAlphaComponent(0.85).cgColor
            streak.shadowColor = palette.glow.cgColor
            streak.shadowOpacity = 1
            streak.shadowRadius = 5
            streak.shadowOffset = .zero
            streak.lineWidth = 2
            streak.lineCap = .round
            // Still: the breeze grows with the drag, not with the clock.
            streak.lineDashPattern = [26, 12]
            streak.lineDashPhase = CGFloat(i) * 9
            feature.addSublayer(streak)
        }
        root.addSublayer(feature)
    }

    /// 0 dark, 1 full light; follows the drag.
    func setIntensity(_ value: CGFloat) {
        let value = clamp01(value)
        still {
            root.opacity = Float(pow(value, 0.7))
            // It grows with the light; Reduce motion keeps its size.
            switch effect {
            case .wormhole:
                let s = calm ? 1 : 0.35 + 0.65 * value
                feature.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
            case .liquid:
                setBulge(calm ? 0.5 : value)
            default:
                root.setAffineTransform(calm ? .identity : CGAffineTransform(scaleX: 1, y: 0.6 + 0.4 * value))
            }
        }
    }

    /// Starts the send or cancel animation; returns its length in seconds.
    func retire(bloom sending: Bool) -> Double {
        let start = (root.presentation() ?? root).opacity
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        let total: Double
        if sending {
            total = 0.65
            fade.values = [start, 1, 1, 0]
            fade.keyTimes = [0, 0.12, 0.45, 1]
        } else {
            let hold = max(start, 0.55)
            total = 0.6
            fade.values = [start, hold, hold, 0]
            fade.keyTimes = [0, 0.15, 0.45, 1]
        }
        fade.duration = total
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = 0
        if !calm, effect != .wormhole, effect != .liquid { root.setAffineTransform(.identity) }
        root.add(fade, forKey: "retire")
        if sending, !calm { sendAnimation() }
        CATransaction.commit()
        return total
    }

    private func sendAnimation() {
        switch effect {
        case .portal:
            // A ripple of light along the seam, ~0.4 s.
            guard let bloom = feature.sublayers?.first else { return }
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [0, 1, 0]
            flash.keyTimes = [0, 0.25, 1]
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = CATransform3DMakeScale(1, 0.6, 1)
            grow.toValue = CATransform3DMakeScale(Look.rippleScale, 1.15, 1)
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let group = CAAnimationGroup()
            group.animations = [flash, grow]
            group.duration = Look.rippleSeconds
            bloom.add(group, forKey: "bloom")
        case .wormhole:
            // The ring flares and closes.
            let close = CAKeyframeAnimation(keyPath: "transform.scale")
            close.values = [feature.affineTransform().a, 1.3, 0.05]
            close.keyTimes = [0, 0.35, 1]
            close.duration = 0.55
            close.timingFunction = CAMediaTimingFunction(name: .easeIn)
            feature.add(close, forKey: "close")
            feature.setAffineTransform(CGAffineTransform(scaleX: 0.05, y: 0.05))
        case .liquid:
            // The water drops back into the edge.
            let shrink = CABasicAnimation(keyPath: "transform.scale.x")
            shrink.fromValue = 1
            shrink.toValue = 0.1
            shrink.duration = 0.45
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            feature.anchorPoint = CGPoint(x: 1, y: 0.5)
            feature.position = CGPoint(x: w, y: h / 2)
            feature.add(shrink, forKey: "shrink")
        case .beam:
            // The lines sweep into the screen.
            let sweep = CABasicAnimation(keyPath: "transform.translation.x")
            sweep.fromValue = 0
            sweep.toValue = -60
            sweep.duration = 0.45
            sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)
            feature.add(sweep, forKey: "sweep")
        case .plane:
            // The breeze follows the plane in.
            let blow = CABasicAnimation(keyPath: "transform.translation.x")
            blow.fromValue = 0
            blow.toValue = -90
            blow.duration = 0.5
            blow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            feature.add(blow, forKey: "blow")
        }
    }

    func stop() {
        root.removeAllAnimations()
        feature.removeAllAnimations()
        feature.sublayers?.forEach { $0.removeAllAnimations() }
    }
}

private extension CAGradientLayer {
    /// A radial gradient centred in its frame (the default starts at the right edge).
    func centred() -> CAGradientLayer {
        startPoint = CGPoint(x: 0.5, y: 0.5)
        endPoint = CGPoint(x: 1, y: 1)
        return self
    }
}
