//
//  PromoReel.swift
//
//  Frames for the promo video, for the harness only (`--promo-mac`,
//  `--promo-edge`); compiled in debug builds only, so the droplet that
//  `droppykit build` makes (release) never carries it.
//
//  Every frame is built from the app's own pieces, exactly as a crossing
//  draws them on screen: `PeekView` and `LandingView` for the card,
//  `CardLook` for its shape and material, `StageView` behind it and
//  `SeamView` on the edge, each sampled at that instant through the `still:`
//  paths the effects already have. The card's position comes from the same
//  critically damped spring and travel curve as `LandingPresenter.tick()`,
//  fed by the peek messages the real phone page sent. The seam's send is a
//  set of plain CAAnimations; its subtree is frozen (`speed` 0) and each
//  animation is moved back by the frame's time, so the renderer shows it at
//  that instant.
//

#if DEBUG
import AppKit
import DropPortalCore
import QuartzCore

/// One phone-to-Mac crossing, rendered at any instant.
@MainActor
public final class PromoCrossing {
    /// A peek message as the page sent it, `t` seconds on the reel's clock.
    public struct Event: Sendable {
        public var t: Double
        public var type: String
        public var progress: Double
        public init(t: Double, type: String, progress: Double) {
            self.t = t
            self.type = type
            self.progress = progress
        }
    }

    public let size: CGSize
    public let startT: Double
    public let commitT: Double
    public var landT: Double { commitT + effect.flight }
    /// The file is here (the upload's end) and the card turns into the landed card.
    public let settleT: Double

    private let effect: PortalEffect
    private let palette: PortalPalette
    private let desktop: CGImage?
    private let landing: CGRect
    private let offX: CGFloat
    private let onX: CGFloat
    private var track: [(t: Double, x: CGFloat, v: CGFloat)] = []
    private let pC: CGFloat, vC: CGFloat, xC: CGFloat
    private let dragSnap: CGImage?
    private var receivingSnaps: [Int: CGImage] = [:]
    private let info: PeekInfo
    private let thumb: NSImage?
    private let landedSnap: CGImage?
    private let uploadSeconds: Double

    /// `screen` in points with a menu bar `menuBar` tall; `events` the page's
    /// peek-start, peek-move and peek-commit; `uploadSeconds` how long the
    /// file takes to arrive after the flick.
    public init(effect: String, tint: String?, rainbowAt: Date, screen: CGSize, menuBar: CGFloat, desktop: CGImage?,
                name: String, bytes: Int64, thumb: Data, landed: NSImage, events: [Event],
                uploadSeconds: Double = 0.5, latency: Double = 0.012) {
        let effect = PortalEffect(stored: effect)
        self.effect = effect
        palette = PortalPalette(tint: PortalTint(stored: tint) ?? .defaultTint(for: effect), at: rainbowAt)
        size = screen
        self.desktop = desktop
        self.uploadSeconds = uploadSeconds
        let card = LandingPresenter.fileCardSize
        // `LandingPresenter.landingRect` on a screen whose visible frame ends under the menu bar.
        let visible = CGRect(x: 0, y: 0, width: screen.width, height: screen.height - menuBar)
        landing = CGRect(x: visible.minX + visible.width * 0.64 - card.width / 2,
                         y: visible.midY - card.height / 2 + visible.height * 0.08,
                         width: card.width, height: card.height).integral
        offX = screen.width + 12
        onX = landing.minX
        startT = events.first { $0.type == "peek-start" }?.t ?? 0
        commitT = events.first { $0.type == "peek-commit" }?.t ?? (startT + 1)
        settleT = max(commitT + effect.flight + 0.16, commitT + uploadSeconds)

        // The finger's p as the Mac hears it, through the spring of `tick()`.
        let moves = events.filter { $0.type == "peek-move" }
        var x = offX, v: CGFloat = 0, t = startT
        let dt = 1.0 / 240
        track.append((t, x, v))
        while t < commitT {
            t += dt
            let p = moves.last { $0.t + latency <= t }?.progress ?? 0
            let target = offX + (onX - offX) * CGFloat(p)
            let stiffness: CGFloat = 420, damping = 2 * stiffness.squareRoot()
            let accel = stiffness * (target - x) - damping * v
            v += accel * CGFloat(dt)
            x += v * CGFloat(dt)
            track.append((t, x, v))
        }
        xC = x
        vC = v
        pC = min(1, max(0, (offX - x) / max(1, offX - onX)))

        info = PeekInfo(id: "promo", name: name, kind: .image, size: bytes, thumb: thumb)
        self.thumb = PeekThumbnail.decode(thumb).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        dragSnap = Self.snapshot(PeekView(info: info, image: self.thumb))
        let landedView = LandingView(image: landed, title: name, url: nil)
        landedView.frame = NSRect(origin: .zero, size: card)
        landedSnap = Self.snapshot(landedView)
    }

    /// A little past the moment the card turns into the landed card.
    public var endT: Double { settleT + 0.5 }

    /// The landed card's picture, made the way the app makes it (QuickLook, 220 pt).
    public static func landedImage(for url: URL) async -> NSImage {
        await LandingPresenter.thumbnail(for: url)
    }

    private func receivingSnap(_ progress: Double) -> CGImage? {
        let step = Int((min(1, max(0, progress)) * 20).rounded())
        if let image = receivingSnaps[step] { return image }
        let view = PeekView(info: info, image: thumb)
        view.showReceiving(progress: Double(step) / 20)
        let image = Self.snapshot(view)
        receivingSnaps[step] = image
        return image
    }

    private func state(at t: Double) -> (x: CGFloat, v: CGFloat) {
        if t >= commitT {
            let L = effect.flight
            let u = CGFloat((t - commitT) / max(0.01, L))
            if u >= 1 { return (onX, 0) }
            let x = xC + (onX - xC) * Ease.travel(u)
            let before = xC + (onX - xC) * Ease.travel(max(0, u - CGFloat(1.0 / 120 / L)))
            return (x, (x - before) * 120)
        }
        let i = track.lastIndex { $0.t <= t } ?? 0
        return (track[i].x, track[i].v)
    }

    /// The whole screen at `t`, y up, in points.
    public func layer(at t: Double) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = PromoScene.desk(size: size, desktop: desktop)
        guard t >= startT else { return root }
        let committed = t >= commitT
        let impacted = committed && t >= landT
        let (x, v) = state(at: t)
        let p = min(1, max(0, (offX - x) / max(1, offX - onX)))
        let intensity = committed ? pC : p
        let card = LandingPresenter.fileCardSize, m = CardLook.margin
        let center = CGPoint(x: x + card.width / 2, y: landing.minY + card.height / 2)

        // The stage, under the card; gone 0.9 s after the impact.
        if !(impacted && t > landT + StageView.Look.impactSeconds + 0.05) {
            let stage = StageView(frame: NSRect(origin: .zero, size: size), effect: effect, palette: palette,
                                  seam: CGPoint(x: size.width, y: landing.midY),
                                  landing: CGPoint(x: landing.midX, y: landing.midY), backingScale: 2)
            if let layer = stage.layer {
                layer.frame = root.bounds
                root.addSublayer(layer)
            }
            stage.paintNow()
            stage.setIntensity(intensity)
            stage.follow(card: impacted ? CGPoint(x: landing.midX, y: landing.midY) : center)
            if committed { stage.send(still: t - commitT) }
            if impacted { stage.impact(still: t - landT) }
        }

        // The card, as `PeekCard.place()` puts it.
        let host = CALayer()
        let originX = x.rounded() - m
        host.frame = CGRect(x: originX, y: landing.minY - m, width: card.width + 2 * m, height: card.height + 2 * m)
        let cardLayer = CALayer()
        cardLayer.frame = CGRect(x: m, y: m, width: card.width, height: card.height)
        cardLayer.cornerRadius = 18
        cardLayer.cornerCurve = .continuous
        cardLayer.masksToBounds = true
        cardLayer.contents = committed ? receivingSnap(min(1, (t - commitT) / uploadSeconds)) : dragSnap
        host.addSublayer(cardLayer)
        root.addSublayer(host)
        host.opacity = Float(min(1, max(0, (offX - x) / 40)))
        let look = CardLook(effect: effect, palette: palette, calm: false, host: host, card: cardLayer, cardFrame: cardLayer.frame)
        if look.wantsSnapshot { look.setSnapshot(dragSnap) }
        look.clip(toMaxX: size.width - originX)
        if committed {
            look.update(progress: pC, velocity: vC, leaving: false)
            look.commit(still: t - commitT)
            if impacted { look.land(still: t - landT) }
        } else {
            look.update(progress: p, velocity: v, leaving: false)
        }
        // Received: the landed card fades in over the peek card in place, with the window's shadow.
        if t >= settleT {
            let e = Float(Ease(x1: 0, y1: 0, x2: 0.58, y2: 1)(CGFloat(min(1, (t - settleT) / 0.22))))
            host.mask = nil
            host.opacity = 1
            let landed = CALayer()
            landed.frame = cardLayer.frame
            landed.contents = landedSnap
            landed.opacity = e
            landed.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: card), cornerWidth: 18, cornerHeight: 18, transform: nil)
            landed.shadowColor = NSColor.black.cgColor
            landed.shadowOpacity = 0.45
            landed.shadowRadius = 18
            landed.shadowOffset = CGSize(width: 0, height: -10)
            host.addSublayer(landed)
            cardLayer.opacity *= 1 - e
        }

        // The edge light, in front of the card; its send lasts 0.65 s.
        if !committed || t < commitT + 0.65 {
            let seamSize = SeamView.size(screenHeight: size.height)
            let seam = SeamView(frame: NSRect(x: size.width - seamSize.width, y: 0, width: seamSize.width, height: seamSize.height),
                                effect: effect, palette: palette, calm: false, centerY: landing.midY)
            seam.setIntensity(intensity)
            PromoScene.add(seam, to: root, sentFor: committed ? t - commitT : nil)
        }
        return root
    }

    static func snapshot(_ view: NSView) -> CGImage? {
        PromoScene.snapshot(view)
    }
}

/// The right-edge send, Mac to phone: a file dragged from the desktop to
/// the screen's right edge, as `EdgePortal.dragMoved` and `fallThrough` draw it.
@MainActor
public final class PromoEdgeSend {
    public let size: CGSize
    public let dropT: Double
    private let effect: PortalEffect
    private let palette: PortalPalette
    private let desktop: CGImage?
    private let icon: CGImage?
    private let label: String
    private let home: CGPoint
    private let path: [(t: Double, p: CGPoint)]
    private let pressT: Double
    private let cursor: CGImage?
    private let hotSpot: CGPoint

    /// `path`: the pointer, in points, y up; it presses on the icon at `pressT` and drops at `dropT`.
    public init(effect: String, tint: String?, rainbowAt: Date, screen: CGSize, desktop: CGImage?,
                icon: NSImage, label: String, home: CGPoint, path: [(Double, CGPoint)], pressT: Double, dropT: Double) {
        let effect = PortalEffect(stored: effect)
        self.effect = effect
        palette = PortalPalette(tint: PortalTint(stored: tint) ?? .defaultTint(for: effect), at: rainbowAt)
        size = screen
        self.desktop = desktop
        var rect = NSRect(x: 0, y: 0, width: 144, height: 144)
        self.icon = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        self.label = label
        self.home = home
        self.path = path.map { (t: $0.0, p: $0.1) }
        self.pressT = pressT
        self.dropT = dropT
        let arrow = NSCursor.arrow
        var crect = NSRect(origin: .zero, size: arrow.image.size)
        cursor = arrow.image.cgImage(forProposedRect: &crect, context: nil, hints: nil)
        hotSpot = arrow.hotSpot
    }

    private func pointer(at t: Double) -> CGPoint {
        guard let next = path.firstIndex(where: { $0.t >= t }) else { return path.last?.p ?? .zero }
        guard next > 0 else { return path[0].p }
        let a = path[next - 1], b = path[next]
        let u = CGFloat((t - a.t) / max(0.0001, b.t - a.t))
        let s = u * u * (3 - 2 * u)
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * s, y: a.p.y + (b.p.y - a.p.y) * s)
    }

    public func layer(at t: Double) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let root = PromoScene.desk(size: size, desktop: desktop)
        let point = pointer(at: min(t, dropT))
        let dropped = t >= dropT
        let dropPoint = pointer(at: dropT)
        let y = dropped ? dropPoint.y : point.y
        let p = min(1, max(0, 1 - (size.width - point.x) / EdgePortal.reach))
        let opened = path.contains { $0.t <= min(t, dropT) && $0.p.x > size.width - EdgePortal.reach } || dropped

        // The file on the desktop: an icon and its name, selected once pressed.
        let selected = t >= pressT
        let iconLayer = CALayer()
        iconLayer.frame = CGRect(x: home.x - 32, y: home.y - 32, width: 64, height: 64)
        iconLayer.contents = icon
        if selected {
            let pad = CALayer()
            pad.frame = iconLayer.frame.insetBy(dx: -4, dy: -4)
            pad.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
            pad.cornerRadius = 6
            root.addSublayer(pad)
        }
        root.addSublayer(iconLayer)
        let text = CATextLayer()
        text.string = label
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.fontSize = 12
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.contentsScale = 2
        let width = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 12
        text.frame = CGRect(x: home.x - width / 2, y: home.y - 32 - 20, width: width, height: 17)
        if selected {
            // macOS's default (blue) accent, not this Mac's.
            text.backgroundColor = NSColor(srgbRed: 0.04, green: 0.39, blue: 0.86, alpha: 1).cgColor
            text.cornerRadius = 4
        } else {
            text.shadowColor = NSColor.black.cgColor
            text.shadowOpacity = 0.8
            text.shadowRadius = 2
            text.shadowOffset = CGSize(width: 0, height: -1)
        }
        root.addSublayer(text)

        if opened {
            let stageAlive = !dropped || t < dropT + 0.2 + StageView.Look.impactSeconds + 0.1
            if stageAlive {
                let stage = StageView(frame: NSRect(origin: .zero, size: size), effect: effect, palette: palette,
                                      seam: CGPoint(x: size.width, y: y), landing: CGPoint(x: size.width - 70, y: y), backingScale: 2)
                if let layer = stage.layer {
                    layer.frame = root.bounds
                    root.insertSublayer(layer, at: 1)
                }
                stage.paintNow()
                if dropped {
                    stage.setIntensity(1)
                    stage.follow(card: dropPoint)
                    stage.send(still: t - dropT)
                    if t >= dropT + 0.2 { stage.impact(still: t - dropT - 0.2) }
                } else {
                    stage.setIntensity(p * 0.8)
                    stage.follow(card: point)
                }
            }
            if !dropped || t < dropT + 0.65 {
                let seamSize = SeamView.size(screenHeight: size.height)
                let seam = SeamView(frame: NSRect(x: size.width - seamSize.width, y: 0, width: seamSize.width, height: seamSize.height),
                                    effect: effect, palette: palette, calm: false, centerY: y)
                seam.setIntensity(dropped ? min(1, max(0, 1 - (size.width - dropPoint.x) / EdgePortal.reach)) : p)
                PromoScene.add(seam, to: root, sentFor: dropped ? t - dropT : nil)
            }
        }

        // The drag image under the pointer; after the drop, `FallingIcon` through the edge.
        if selected && !dropped && point.distance(to: home) > 3 {
            let drag = CALayer()
            drag.frame = CGRect(x: point.x - 36, y: point.y - 36, width: 72, height: 72)
            drag.contents = icon
            drag.opacity = 0.9
            root.addSublayer(drag)
        } else if dropped && t < dropT + 0.3 {
            let side: CGFloat = 72
            let x0 = min(dropPoint.x, size.width - 30) - side / 2 - 40
            let start = CGRect(x: x0, y: dropPoint.y - side / 2, width: side, height: side)
            let end = CGRect(x: size.width - 6, y: dropPoint.y - 8, width: 16, height: 16)
            let u = CGFloat((t - dropT) / 0.3)
            let k = Ease(x1: 0.5, y1: 0, x2: 0.9, y2: 0.6)(u)
            let falling = CALayer()
            falling.frame = CGRect(x: start.minX + (end.minX - start.minX) * k, y: start.minY + (end.minY - start.minY) * k,
                                   width: start.width + (end.width - start.width) * k, height: start.height + (end.height - start.height) * k)
            falling.contents = icon
            falling.opacity = Float(1 + (0.15 - 1) * k)
            root.addSublayer(falling)
        }

        // The pointer, on top of everything.
        let after = dropped ? CGPoint(x: dropPoint.x - CGFloat(min(0.5, t - dropT)) * 90, y: dropPoint.y - CGFloat(min(0.5, t - dropT)) * 20) : point
        let arrow = CALayer()
        let csize = NSCursor.arrow.image.size
        arrow.frame = CGRect(x: after.x - hotSpot.x, y: after.y - (csize.height - hotSpot.y), width: csize.width, height: csize.height)
        arrow.contents = cursor
        root.addSublayer(arrow)
        return root
    }
}

/// What both scenes share.
@MainActor
enum PromoScene {
    static func desk(size: CGSize, desktop: CGImage?) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor.black.cgColor
        let desk = CALayer()
        desk.frame = root.bounds
        desk.contents = desktop
        desk.contentsGravity = .resizeAspectFill
        root.addSublayer(desk)
        return root
    }

    /// The seam's layer on the screen; `sentFor`: seconds since its send, played by its own animations.
    static func add(_ seam: SeamView, to root: CALayer, sentFor: Double?) {
        guard let layer = seam.layer else { return }
        layer.frame = seam.frame
        let holder = CALayer()
        holder.frame = root.bounds
        holder.addSublayer(layer)
        root.addSublayer(holder)
        guard let dt = sentFor else { return }
        _ = seam.retire(bloom: true)
        // Frozen time: every animation of the send, `dt` seconds in.
        holder.speed = 0
        holder.timeOffset = 0
        func rewind(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key)?.copy() as? CAAnimation else { continue }
                animation.beginTime = -dt - 1e-6
                layer.removeAnimation(forKey: key)
                layer.add(animation, forKey: key)
            }
            layer.sublayers?.forEach(rewind)
        }
        rewind(layer)
    }

    /// A view drawn at twice its size, the way a Retina screen shows it.
    static func snapshot(_ view: NSView) -> CGImage? {
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
#endif
