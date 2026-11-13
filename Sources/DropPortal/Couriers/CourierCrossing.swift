//
//  CourierCrossing.swift
//  DropPortal
//
//  The four couriers on the Mac, the ONE place the stage (PortalStage.swift)
//  and the card (PortalEffects.swift) call for any courier effect:
//
//  - the rig toolkit: a part tree of `CAShapeLayer`s in the drawing's units
//    (feet at 0,0, y down, facing left, about 100 tall: the approved mockup's
//    `.droppykit/design/fx-mockups-cute-v2/mockups.html`), springs and eased
//    tweens, volume-preserving squash and stretch, blinks from the shared
//    seed, a soft contact shadow and a drawn copy of the card it carries;
//  - the flow: the courier waits at the right edge from `peek-start`, follows
//    p, arrives from the bytes (T = 0, the send) to the landing L, hands the
//    card copy to the real card at L (CardLook shows it), has its moment and
//    leaves, all on `CourierPlan`'s clock (the short version, the gag); a
//    click on it skips to the landing; Reduce motion is a sticker on the card
//    (`CourierSticker`); everything stops in `stop()`, which `tearDown` reaches;
//  - `protocol CourierCharacter` and `CourierCast`, the registry by `Courier`.
//
//  One `FrameClock` per crossing, live only (the harness and the settings'
//  thumbnails draw one instant through `still:`). Every number of the
//  timeline is in Couriers.swift. Each character lives in its own file,
//  `<Name>Courier.swift` beside this one; see "How to add a courier" in
//  `.droppykit/docs/effects.md`.
//

import AppKit
import AVFoundation
import DropPortalCore

// MARK: - What a character gets

/// Where things are on the stage: points, y up, the screen's origin at 0,0.
struct CourierScene {
    var size: CGSize
    /// The right screen edge at the card's height.
    var edge: CGPoint
    /// The landed card's middle and size.
    var landing: CGPoint
    var card: CGSize
    /// Points per mockup unit: the mockup's Mac card (122 wide) is the landed card.
    var s: CGFloat { card.width / 122 }
    /// Points per drawing unit, the mockup's Mac scale (kM = 0.86).
    var unit: CGFloat { s * 0.86 }
    /// The ground the courier stands on (the mockup's GM).
    var ground: CGFloat { mock(0, 336).y }

    /// A point of the mockup's Mac screen (y down, landing at 660, 204) on this stage.
    func mock(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: landing.x + (x - 660) * s, y: landing.y - (y - 204) * s)
    }
}

/// The part of the flow a frame is in.
enum CourierMoment {
    /// The phone holds the card at p; `ms` since peek-start.
    case waiting(p: CGFloat, ms: Double)
    /// `T` on the plan's clock (ms after the bytes, the short version squeezed in).
    case arriving(T: Double)
    case leaving(T: Double)
    /// Reduce motion: `ms` since the sticker showed.
    case sticker(ms: Double)
}

/// Everything about one frame.
struct CourierFrame {
    let scene: CourierScene
    let plan: CourierPlan
    let moment: CourierMoment
    /// The eyes' lid now, from the plan's blinks (0 open, 1 shut).
    let blink: CGFloat
}

/// The drawn copy of the card: its middle in stage points, its scale (1 = the landed card) and turn.
struct CardCarry {
    var center: CGPoint
    var scale: CGFloat
    var rot: CGFloat = 0
    var alpha: CGFloat = 1
}

/// One frame of the courier's body. The crossing places `rig.body` from it;
/// the character moves its own parts in `draw`.
struct CourierPose {
    /// The feet, stage points (y up).
    var x: CGFloat
    var y: CGFloat
    /// On top of the scene's unit.
    var scale: CGFloat = 1
    /// Squash and stretch about the feet (`CourierKit.squash` keeps the volume).
    var sx: CGFloat = 1
    var sy: CGFloat = 1
    /// Radians about the feet, counter-clockwise.
    var rot: CGFloat = 0
    /// 1 faces left (into the screen), -1 right, in between while turning.
    var face: CGFloat = 1
    var alpha: CGFloat = 1
    /// The contact shadow; nil = from the height above the ground.
    var shadow: CGFloat? = nil
    /// The card it carries; nil = none (before it takes it, after L).
    var card: CardCarry? = nil
    /// The card copy behind the body instead of in front.
    var cardBehind = false
}

/// A sound at a beat of the character's own, `ms` on the plan's clock after the bytes.
struct CourierCue {
    var ms: Double
    var name: String
}

// MARK: - The contract

/// One courier. Everything has a default (the placeholder's), so a character
/// overrides only what it needs; all of it lives in `<Name>Courier.swift`.
@MainActor
protocol CourierCharacter: AnyObject {
    var courier: Courier { get }
    /// The parts, once: under `rig.body` in the drawing's units, plus layers of
    /// its own under `rig.behind` / `rig.front` (stage points) for puffs and gags.
    func build(_ rig: CourierRig)
    /// The phone holds the card at p.
    func waiting(_ f: CourierFrame, p: CGFloat, ms: Double) -> CourierPose
    /// From the bytes (T = 0) to the landing (T = L): it brings the card copy
    /// and must hand it over at L exactly at `scene.landing`, scale 1.
    func arrive(_ f: CourierFrame, T: Double) -> CourierPose
    /// L to gone, T on the plan's clock (its moment, then the exit); nil once gone.
    func leave(_ f: CourierFrame, T: Double) -> CourierPose?
    /// Reduce motion: a still pose; the sticker places, scales and fades it.
    func sticker(_ f: CourierFrame, ms: Double) -> CourierPose
    /// Moves its parts for this frame (eyes, cheeks, paws), after the body is placed.
    func draw(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame)
    /// The rare gag, only when `plan.gag`: its own layers under `rig.front`/`rig.behind`.
    func gag(_ rig: CourierRig, _ f: CourierFrame, T: Double)
    /// Sounds of its own (the landing sound is PortalSound's), and their samples at 44.1 kHz.
    func cues(_ plan: CourierPlan) -> [CourierCue]
    func sound(_ cue: String) -> [Double]?
}

extension CourierCharacter {
    func waiting(_ f: CourierFrame, p: CGFloat, ms: Double) -> CourierPose { CourierKit.placeholderWaiting(f, p: p) }
    func arrive(_ f: CourierFrame, T: Double) -> CourierPose { CourierKit.placeholderArrive(f, T: T) }
    func leave(_ f: CourierFrame, T: Double) -> CourierPose? { CourierKit.placeholderLeave(f, T: T) }
    func sticker(_ f: CourierFrame, ms: Double) -> CourierPose { CourierPose(x: 0, y: 0) }
    func draw(_ rig: CourierRig, _ pose: CourierPose, _ f: CourierFrame) {}
    func gag(_ rig: CourierRig, _ f: CourierFrame, T: Double) {}
    func cues(_ plan: CourierPlan) -> [CourierCue] { [] }
    func sound(_ cue: String) -> [Double]? { nil }
}

/// The registry: one character per courier.
@MainActor
enum CourierCast {
    static func make(_ courier: Courier) -> CourierCharacter {
        switch courier {
        case .cheek: return PipCourier()
        case .pounce: return TofuCourier()
        case .mole: return DigbyCourier()
        case .ducks: return MatchaCourier()
        }
    }
}

// MARK: - The rig toolkit

/// The layers of one courier: the shadow, the character's own layers behind,
/// the body (the part tree), the card copy, the character's own in front.
@MainActor
final class CourierRig {
    /// Stage-sized, y up.
    let root = CALayer()
    let shadow = CAGradientLayer()
    let behind = CALayer()
    /// Its position is the feet; its sublayers are in the drawing's units (y down).
    let body = CALayer()
    let cardCopy = CALayer()
    let front = CALayer()
    private(set) var parts: [String: CAShapeLayer] = [:]

    init(size: CGSize) {
        for layer in [root, behind, front] {
            layer.frame = CGRect(origin: .zero, size: size)
            layer.actions = CourierKit.noActions
        }
        shadow.type = .radial
        shadow.colors = [NSColor(white: 0, alpha: 0.28), NSColor(white: 0, alpha: 0.16), NSColor(white: 0, alpha: 0)].map(\.cgColor)
        shadow.locations = [0, 0.55, 1]
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 1)
        cardCopy.cornerRadius = 18
        cardCopy.cornerCurve = .continuous
        cardCopy.masksToBounds = true
        cardCopy.backgroundColor = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor
        cardCopy.contentsGravity = .resizeAspectFill
        cardCopy.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        cardCopy.borderWidth = 1
        for layer in [shadow, body, cardCopy] as [CALayer] { layer.actions = CourierKit.noActions }
        body.bounds = .zero
        root.addSublayer(shadow)
        root.addSublayer(behind)
        root.addSublayer(body)
        root.addSublayer(cardCopy)
        root.addSublayer(front)
    }

    /// A part: `path` in the drawing's units (as in the mockup), turned and
    /// scaled by `set` about `pivot`. A child part (`in:` another part) draws
    /// in the same units and moves with its parent. Filled, outlined in `ink`
    /// (`width` 0 = none). Named parts can be looked up.
    @discardableResult
    func part(_ name: String, _ path: CGPath, fill: NSColor, ink: NSColor? = CourierKit.ink, width: CGFloat = 2,
              pivot: CGPoint = .zero, in parent: CALayer? = nil) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.actions = CourierKit.noActions
        var move = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
        shape.path = path.copy(using: &move)
        shape.fillColor = fill.cgColor
        shape.strokeColor = width > 0 ? ink?.cgColor : nil
        shape.lineWidth = width
        shape.lineJoin = .round
        // A child's pivot is in the drawing's units too: relative to its parent's pivot.
        let base = (parent?.value(forKey: "dp.pivot") as? NSValue)?.pointValue ?? .zero
        shape.setValue(NSValue(point: pivot), forKey: "dp.pivot")
        shape.position = CGPoint(x: pivot.x - base.x, y: pivot.y - base.y)
        shape.bounds = .zero
        (parent ?? body).addSublayer(shape)
        parts[name] = shape
        return shape
    }

    subscript(name: String) -> CAShapeLayer? { parts[name] }

    /// Turns (radians, the drawing's sense: clockwise on screen) and scales a part about its pivot.
    func set(_ name: String, turn: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, dx: CGFloat = 0, dy: CGFloat = 0) {
        parts[name]?.setAffineTransform(CGAffineTransform(translationX: dx, y: dy).rotated(by: turn).scaledBy(x: sx, y: sy))
    }

    /// The body, the shadow and the card copy for one pose.
    func place(_ pose: CourierPose, scene: CourierScene) {
        let u = scene.unit * pose.scale
        body.position = CGPoint(x: pose.x, y: pose.y)
        // Turn about the feet, squash, face, then flip y: the parts are drawn y down.
        var m = CATransform3DMakeRotation(pose.rot, 0, 0, 1)
        m = CATransform3DScale(m, pose.sx * pose.face * u, -pose.sy * u, 1)
        body.transform = m
        body.opacity = Float(pose.alpha)
        // The contact shadow: smaller and fainter as it lifts.
        let lift = max(0, pose.y - scene.ground)
        let w = 44 * u * (1 - min(0.8, lift / (120 * u)))
        shadow.bounds = CGRect(x: 0, y: 0, width: 2 * w, height: 0.48 * w)
        shadow.position = CGPoint(x: pose.x, y: scene.ground - 1)
        shadow.opacity = Float((pose.shadow ?? (1 - min(1, lift / (160 * u)))) * pose.alpha)
        if let carry = pose.card {
            cardCopy.isHidden = false
            cardCopy.bounds = CGRect(origin: .zero, size: scene.card)
            cardCopy.position = carry.center
            cardCopy.transform = CATransform3DScale(CATransform3DMakeRotation(carry.rot, 0, 0, 1), carry.scale, carry.scale, 1)
            cardCopy.opacity = Float(carry.alpha * pose.alpha)
            cardCopy.zPosition = pose.cardBehind ? -1 : 1
        } else {
            cardCopy.isHidden = true
        }
    }
}

/// The rig's maths, the mockup's: eases, springs, squash, the placeholder's flow.
enum CourierKit {
    nonisolated(unsafe) static let ink = NSColor(srgbRed: 0.17, green: 0.10, blue: 0.06, alpha: 1)
    nonisolated(unsafe) static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                "opacity": NSNull(), "path": NSNull(), "hidden": NSNull(),
                                                "contents": NSNull(), "zPosition": NSNull(), "sublayerTransform": NSNull()]

    static func clamp(_ v: CGFloat, _ a: CGFloat = 0, _ b: CGFloat = 1) -> CGFloat { min(b, max(a, v)) }
    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    /// How far `t` is through a...b, 0...1, no ease.
    static func part(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { clamp(CGFloat((t - a) / (b - a))) }
    static func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - clamp(x), 3) }
    static func easeIn(_ x: CGFloat) -> CGFloat { pow(clamp(x), 3) }
    static func easeInOut(_ x: CGFloat) -> CGFloat { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func backOut(_ x: CGFloat, _ s: CGFloat = 1.70158) -> CGFloat { let x = clamp(x) - 1; return 1 + (s + 1) * x * x * x + s * x * x }
    /// The mockup's curves: A (into an edge), decel (arriving), travel.
    static let curveA = Ease(x1: 0.3, y1: 0, x2: 0.8, y2: 0.15)
    static let decel = Ease(x1: 0.05, y1: 0.7, x2: 0.1, y2: 1)
    static let travel = Ease(x1: 0.2, y1: 0.7, x2: 0.3, y2: 1)

    /// A damped spring's offset from 1 to 0 with no start velocity: `a` ms, `f` Hz, damping `z`.
    static func settle(_ a: Double, f: Double = 3, z: Double = 0.5) -> CGFloat {
        guard a > 0 else { return 1 }
        let w = 2 * .pi * f / 1000, q = (1 - z * z).squareRoot(), wd = w * q
        return CGFloat(exp(-z * w * a) * (cos(wd * a) + z / q * sin(wd * a)))
    }

    /// A damped spring pushed at 0: starts at 0, swings, dies out.
    static func kick(_ a: Double, f: Double = 3, z: Double = 0.4) -> CGFloat {
        guard a > 0 else { return 0 }
        let w = 2 * .pi * f / 1000, wd = w * (1 - z * z).squareRoot()
        return CGFloat(exp(-z * w * a) * sin(wd * a))
    }

    /// Volume-preserving squash and stretch: `s` along y, 1/s across.
    static func squash(_ s: CGFloat) -> (sx: CGFloat, sy: CGFloat) { (1 / s, s) }

    /// The landing squash across (sy = 1/sx): to `peak` for `hold` ms, a rebound, then a spring.
    static func landSquash(_ a: Double, peak: CGFloat = 1.25, rebound: CGFloat = 0.95, hold: Double = 50) -> CGFloat {
        if a < 0 { return 1 }
        if a < 16 { return mix(1, peak, easeOut(CGFloat(a / 16))) }
        if a < hold { return peak }
        if a < hold + 50 { return mix(peak, rebound, 0.5 - 0.5 * cos(.pi * CGFloat((a - hold) / 50))) }
        return 1 + (rebound - 1) * settle(a - hold - 50, f: 3.2, z: 0.55)
    }

    /// A quadratic Bézier point.
    static func qbez(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: CGFloat) -> CGPoint {
        let s = 1 - t
        return CGPoint(x: s * s * a.x + 2 * s * t * b.x + t * t * c.x, y: s * s * a.y + 2 * s * t * b.y + t * t * c.y)
    }

    static func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
    }

    /// The eyes' lid `ms` on the hold's clock (0 = peek-start, the bytes 600 ms later), from the plan's blinks.
    static func blink(_ plan: CourierPlan, at ms: Double) -> CGFloat {
        let last = plan.blinkTimes(until: ms + 1).last { $0 <= ms }
        return CGFloat(last.map { CourierPlan.lid(ms - $0) } ?? 0)
    }

    // MARK: The placeholder flow (what a stub plays)

    /// Where the placeholder waits: at the right edge on the ground.
    static func home(_ s: CourierScene) -> CGPoint { CGPoint(x: s.size.width - 48 * s.unit, y: s.ground) }
    /// Beside the landed card.
    static func spot(_ s: CourierScene) -> CGPoint { CGPoint(x: s.landing.x + s.card.width / 2 + 46 * s.unit, y: s.ground) }
    /// The card on its head, the drawing's (0, -86).
    static func onHead(_ pose: CourierPose, _ s: CourierScene, scale: CGFloat = 0.3) -> CardCarry {
        CardCarry(center: CGPoint(x: pose.x, y: pose.y + (86 * pose.sy * pose.scale) * s.unit + s.card.height * scale / 2), scale: scale)
    }

    static func placeholderWaiting(_ f: CourierFrame, p: CGFloat) -> CourierPose {
        let s = f.scene, h = home(s), a = backOut(clamp(p / 0.4), 2.2)
        let q = squash(mix(1, 0.88, easeInOut(clamp((p - 0.5) / 0.5))))
        return CourierPose(x: h.x + 60 * s.unit * (1 - a), y: h.y, sx: q.sx, sy: q.sy, alpha: clamp(a * 4))
    }

    static func placeholderArrive(_ f: CourierFrame, T: Double) -> CourierPose {
        let s = f.scene, L = f.plan.landingMS, from = home(s), to = spot(s)
        let u = part(T, 0, L * 0.8), e = decel(u)
        var pose = CourierPose(x: mix(from.x, to.x, e), y: s.ground + 60 * s.unit * sin(.pi * u) * CGFloat(f.plan.jitter))
        let q = squash(T < 40 ? 0.85 : 1 + 0.12 * (1 - u))
        pose.sx = q.sx
        pose.sy = q.sy
        pose.rot = 0.15 * sin(.pi * u)
        // On its head, then over to the landing: exactly the landed card at L.
        let head = onHead(pose, s), g = easeInOut(part(T, L * 0.6, L))
        pose.card = CardCarry(center: CGPoint(x: mix(head.center.x, s.landing.x, g), y: mix(head.center.y, s.landing.y, g) + 40 * s.unit * sin(.pi * g)),
                              scale: mix(head.scale, 1, g))
        return pose
    }

    static func placeholderLeave(_ f: CourierFrame, T: Double) -> CourierPose? {
        let s = f.scene, c = f.plan.courier, to = spot(s)
        guard T <= c.goneMS else { return nil }
        // A happy little squash at L, a hop on the spot, then back to the right edge.
        let q = landSquash(T - c.landingMS)
        var pose = CourierPose(x: to.x, y: s.ground, sx: q, sy: 1 / q)
        if T > c.exitMS {
            let u = part(T, c.exitMS, c.goneMS)
            pose.face = -1
            pose.x = mix(to.x, s.size.width + 60 * s.unit, curveA(u))
            pose.y = s.ground + 18 * s.unit * abs(sin(.pi * 3 * u))
        }
        return pose
    }
}

// MARK: - The crossing

/// One courier crossing on the stage, from `peek-start` to gone.
@MainActor
final class CourierCrossing {
    let rig: CourierRig
    var layer: CALayer { rig.root }
    private let character: CourierCharacter
    private(set) var scene: CourierScene
    var plan: CourierPlan
    /// A click on the courier: the presenter lands the card now.
    var onSkip: (() -> Void)?
    /// The pointer in the stage's points and whether the left button is down (live only).
    var pointer: (() -> (CGPoint, Bool)?)?
    /// Plays a cue's samples (the droplet sets it while sounds are on).
    static var playCue: (([Double]) -> Void)?

    private var clock: FrameClock?
    private var heldAt = CACurrentMediaTime()
    private var p: CGFloat = 0
    private var sentAt: CFTimeInterval?
    private var skippedAt: Double?
    private var cancelledAt: CFTimeInterval?
    private var played = Set<Int>()
    private var wasDown = true

    init?(effect: PortalEffect, scene: CourierScene, plan: CourierPlan? = nil) {
        guard let courier = effect.courier else { return nil }
        self.scene = scene
        self.plan = plan ?? CourierPlan(courier: courier, seed: 7)
        rig = CourierRig(size: scene.size)
        character = CourierCast.make(courier)
        character.build(rig)
        render(.waiting(p: 0, ms: 0))
    }

    /// The picture on the card copy (the peek's snapshot).
    func setCardImage(_ image: CGImage?) { rig.cardCopy.contents = image }

    /// Seconds from L until the courier is gone.
    var afterLanding: Double { (plan.goneMS - plan.landingMS) / 1000 }

    /// Live from here: one frame clock until the courier is gone or stopped.
    func start(screen: NSScreen?) {
        guard clock == nil else { return }
        heldAt = CACurrentMediaTime()
        clock = FrameClock(screen: screen) { [weak self] _ in self?.tick() }
    }

    func hold(_ p: CGFloat) {
        self.p = p
        if sentAt == nil { render(.waiting(p: p, ms: (CACurrentMediaTime() - heldAt) * 1000)) }
    }

    /// The bytes are coming (T = 0). `t` seconds after it draws that instant, for the harness.
    func send(still t: Double? = nil) {
        if let t { render(moment(at: t * 1000)) } else { sentAt = CACurrentMediaTime() }
    }

    /// A cancel: the courier fades where it is.
    func cancel() { cancelledAt = CACurrentMediaTime() }

    func stop() {
        clock?.invalidate()
        clock = nil
        rig.root.isHidden = true
    }

    private func moment(at ms: Double) -> CourierMoment {
        let T = plan.clock(ms)
        return ms < plan.landingMS ? .arriving(T: T) : .leaving(T: T)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if let cancelledAt {
            let fade = 1 - (now - cancelledAt) * 1000 / Courier.cancelFadeMS
            guard fade > 0 else { return stop() }
            rig.root.opacity = Float(fade)
            return
        }
        guard let sentAt else { render(.waiting(p: p, ms: (now - heldAt) * 1000)); return }
        let ms = (now - sentAt) * 1000
        if let skippedAt {
            let fade = 1 - (ms - skippedAt) / Courier.skipMS
            guard fade > 0 else { return stop() }
            rig.root.opacity = Float(fade)
            return
        }
        guard ms <= plan.goneMS, render(moment(at: ms)) else { return stop() }
        // Its own sounds, once each.
        for (i, cue) in character.cues(plan).enumerated() where !played.contains(i) && plan.clock(ms) >= cue.ms {
            played.insert(i)
            if let samples = character.sound(cue.name) { Self.playCue?(samples) }
        }
        // A click on the courier skips to the landing.
        if let hit = pointer?() {
            let (point, down) = hit
            if down, !wasDown, hitsBody(point) { skip(at: ms) }
            wasDown = down
        }
    }

    private func hitsBody(_ point: CGPoint) -> Bool {
        let u = scene.unit, b = rig.body.position
        return CGRect(x: b.x - 50 * u, y: b.y, width: 100 * u, height: 100 * u).contains(point)
    }

    private func skip(at ms: Double) {
        guard skippedAt == nil else { return }
        skippedAt = ms
        rig.cardCopy.isHidden = true
        onSkip?()
    }

    /// Draws one frame; false once the courier is gone.
    @discardableResult
    private func render(_ moment: CourierMoment) -> Bool {
        let clockMS: Double
        switch moment {
        case .waiting(let p, _): clockMS = Double(p) * 600
        case .arriving(let T), .leaving(let T): clockMS = 600 + T
        case .sticker(let ms): clockMS = ms
        }
        let frame = CourierFrame(scene: scene, plan: plan, moment: moment, blink: CourierKit.blink(plan, at: clockMS))
        let pose: CourierPose?
        switch moment {
        case .waiting(let p, let ms): pose = character.waiting(frame, p: p, ms: ms)
        case .arriving(let T): pose = character.arrive(frame, T: T)
        case .leaving(let T): pose = character.leave(frame, T: T)
        case .sticker(let ms): pose = character.sticker(frame, ms: ms)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let pose else { rig.root.isHidden = true; return false }
        rig.root.isHidden = false
        rig.place(pose, scene: scene)
        character.draw(rig, pose, frame)
        if plan.gag, case .leaving(let T) = moment { character.gag(rig, frame, T: T) }
        return true
    }

    // MARK: Reduce motion

    /// The sticker on the landed card: `host` is the card's host layer.
    static func sticker(_ courier: Courier, host: CALayer, cardFrame: CGRect, still t: Double? = nil) -> CourierSticker {
        CourierSticker(courier: courier, host: host, cardFrame: cardFrame, still: t)
    }
}

/// Reduce motion: the courier sits on the landed card's lower left corner,
/// fades in, blinks once and fades out (Couriers.swift's sticker timings).
@MainActor
final class CourierSticker {
    private let rig: CourierRig
    private let character: CourierCharacter
    private let scene: CourierScene
    private let plan: CourierPlan
    private var clock: FrameClock?
    private let shownAt = CACurrentMediaTime()

    init(courier: Courier, host: CALayer, cardFrame: CGRect, still t: Double?) {
        // A scene the size of the card's host, the courier about a third of the card tall.
        var scene = CourierScene(size: host.bounds.size, edge: CGPoint(x: host.bounds.maxX, y: cardFrame.midY),
                                 landing: CGPoint(x: cardFrame.midX, y: cardFrame.midY), card: cardFrame.size)
        scene.card.width = cardFrame.width * 0.45
        self.scene = scene
        plan = CourierPlan(courier: courier, seed: 7)
        rig = CourierRig(size: host.bounds.size)
        character = CourierCast.make(courier)
        character.build(rig)
        rig.root.zPosition = 10
        host.addSublayer(rig.root)
        if let t { render(t * 1000) } else {
            render(0)
            clock = FrameClock(screen: nil) { [weak self] _ in
                guard let self else { return }
                if !self.render((CACurrentMediaTime() - self.shownAt) * 1000) { self.stop() }
            }
        }
    }

    func stop() {
        clock?.invalidate()
        clock = nil
        rig.root.removeFromSuperlayer()
    }

    @discardableResult
    private func render(_ ms: Double) -> Bool {
        let fade = Courier.stickerFadeMS, end = Courier.stickerHoldMS + fade
        guard ms <= end else { return false }
        let frame = CourierFrame(scene: scene, plan: plan, moment: .sticker(ms: ms),
                                 blink: CGFloat(CourierPlan.lid(ms - Courier.stickerBlinkMS)))
        var pose = character.sticker(frame, ms: ms)
        // Placed here, whatever the character says: on the card's lower left corner.
        pose.x = scene.landing.x - scene.card.width * 0.62
        pose.y = scene.landing.y - scene.card.height / 2 - 4
        pose.alpha *= min(CourierKit.part(ms, 0, fade), 1 - CourierKit.part(ms, Courier.stickerHoldMS, end))
        pose.shadow = 0
        pose.card = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rig.place(pose, scene: scene)
        character.draw(rig, pose, frame)
        CATransaction.commit()
        return true
    }
}

// MARK: - Cue sounds

/// A character's own cue, at half volume, like PortalSound.
@MainActor
enum CourierSound {
    private static var players: [AVAudioPlayer] = []

    static func play(_ samples: [Double]) {
        players.removeAll { !$0.isPlaying }
        guard players.count < 4, let player = try? AVAudioPlayer(data: PortalSound.wav(samples)) else { return }
        player.volume = 0.5
        player.play()
        players.append(player)
    }

    static func stopAll() {
        players.forEach { $0.stop() }
        players = []
    }
}
