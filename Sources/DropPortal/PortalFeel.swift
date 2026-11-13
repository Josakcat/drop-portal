//
//  PortalFeel.swift
//  DropPortal
//
//  How a crossing feels on the Mac, apart from how it looks: the frame clock
//  that moves the peek card and its flight at the display's own rate (120 Hz
//  on ProMotion), the trackpad's taps, and the landed card's contact shadow
//  and its small lean toward the pointer. Kept in its own file so the effect
//  files stay as they are; LandingPanel.swift calls in at a few points.
//

import AppKit
import IOKit
import QuartzCore
import os
import DropPortalCore
#if DEBUG
import Metal
#endif

// MARK: - Frame rate

enum FrameRate {
    /// The fastest the screen can show, never under 60.
    static func fastest(on screen: NSScreen?) -> Float {
        Float(max(60, (screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60))
    }

    /// Ask for the screen's top rate, and let the system go no lower than 60.
    static func range(on screen: NSScreen? = nil) -> CAFrameRateRange {
        let top = screen.map(fastest(on:)) ?? NSScreen.screens.map(fastest(on:)).max() ?? 60
        return CAFrameRateRange(minimum: min(60, top), maximum: top, preferred: top)
    }

    /// Keyframes per second for a sampled `Motion`: one per frame of the fastest screen.
    @MainActor static var samples: Double { Double(NSScreen.screens.map(fastest(on:)).max() ?? 60) }

    /// The screen whose frame is `rect`, for a card that knows only its screen's frame.
    @MainActor static func screen(for rect: CGRect?) -> NSScreen? {
        guard let rect else { return NSScreen.main }
        return NSScreen.screens.first { $0.frame == rect } ?? NSScreen.main
    }
}

/// Calls `tick` once per frame of `screen`'s display, at its top rate: a
/// `CADisplayLink` from the screen (macOS 14, the droplet's floor), so a
/// ProMotion display gets 120 steps a second and a 60 Hz one exactly 60, in
/// step with the frames instead of beating against them like a timer.
/// Runs on the main run loop in `.common` modes; `invalidate()` releases it
/// (the link holds its target until then). A 20 Hz backup steps in only
/// when the link has been silent for 50 ms, such as while the display sleeps.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private var lastFire = CACurrentMediaTime()
    private let tick: @MainActor (FrameClock) -> Void
    /// A number of its own, so the bench never mixes two clocks (an ObjectIdentifier is reused once freed).
    private let serial: Int
    private static var made = 0
    /// Frame timing for `FeelProbe.bench`; off in the droplet.
    static var stats: FrameStats?

    init(screen: NSScreen?, tick: @escaping @MainActor (FrameClock) -> Void) {
        self.tick = tick
        Self.made += 1
        serial = Self.made
        super.init()
        if let screen = screen ?? NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = FrameRate.range(on: screen)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        // A display link stops while its display sleeps (or there is none): a slow
        // clock keeps the crossing going then, so a card still lands, plays its
        // sound and turns into the landed card. It does nothing while the link runs.
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, CACurrentMediaTime() - self.lastFire > 0.05 else { return }
                self.fire()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func step(_ link: CADisplayLink) { fire() }

    private func fire() {
        lastFire = CACurrentMediaTime()
        guard let stats = Self.stats else { return tick(self) }
        let start = CACurrentMediaTime()
        tick(self)
        stats.record(serial, at: start, work: CACurrentMediaTime() - start)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }
}

/// Frame intervals and per-frame work, for the bench: per clock, and the
/// busiest clock (the spring, which runs from the first move to the landing) is reported.
@MainActor
final class FrameStats {
    private var intervals: [Int: [Double]] = [:]
    private var work: [Int: [Double]] = [:]
    private var last: [Int: CFTimeInterval] = [:]

    func record(_ clock: Int, at time: CFTimeInterval, work seconds: Double) {
        if let last = last[clock] { intervals[clock, default: []].append(time - last) }
        last[clock] = time
        work[clock, default: []].append(seconds)
    }

    func reset() { intervals = [:]; work = [:]; last = [:] }

    var summary: String {
        func ms(_ v: Double) -> String { String(format: "%.2f", v * 1000) }
        guard let (clock, gaps) = intervals.max(by: { $0.value.count < $1.value.count }), !gaps.isEmpty else { return "no frames" }
        let sorted = (work[clock] ?? [0]).sorted()
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let late = gaps.filter { $0 > mean * 1.5 }.count
        return "\(gaps.count + 1) frames, \(String(format: "%.0f", 1 / mean)) fps, interval mean \(ms(mean)) ms, "
            + "max \(ms(gaps.max() ?? 0)) ms, late \(late); tick mean \(ms(sorted.reduce(0, +) / Double(sorted.count))) ms, "
            + "p99 \(ms(p99)) ms, max \(ms(sorted.last ?? 0)) ms"
    }
}

// MARK: - Haptics

/// The trackpad's side of a crossing: a light tap as the peek card comes out
/// of the edge and a firmer one as it lands. Only played when a Force Touch
/// trackpad is there (the built-in one or a Magic Trackpad 2); macOS also
/// skips it when the user turned haptic feedback off, and the user feels it
/// only with a finger on the trackpad.
enum PortalHaptics {
    enum Beat { case appear, land }

    /// Whether a trackpad that can tap is attached, read off the main thread.
    private static let supported = OSAllocatedUnfairLock(initialState: false)
    private static let queue = DispatchQueue(label: "drop-portal.haptics", qos: .utility)

    /// Reads the attached trackpads again (cheap: one registry walk), off main.
    static func refresh() {
        queue.async {
            let found = actuatorPresent()
            supported.withLock { $0 = found }
        }
    }

    static var isSupported: Bool { supported.withLock { $0 } }

    @MainActor
    static func play(_ beat: Beat) {
        guard isSupported else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = beat == .appear ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// A multitouch device that reports it can actuate (taptic engine).
    private static func actuatorPresent() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let value = IORegistryEntryCreateCFProperty(entry, "ActuationSupported" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool, value {
                found = true
            }
        }
        return found
    }
}

// MARK: - Landed card depth

/// Under the landed card: a soft contact shadow on the desktop, and the
/// card's lean toward the pointer while it is hovered. Plain: at most 4°,
/// eased. Glass (the landing celebration, LandingCelebration.swift): at most
/// 6° in a −1/900 perspective, on a critically damped 0.25 s spring that
/// retargets with every pointer move, with a soft specular sheen that moves
/// the other way, as if lit from a fixed light; it starts once the land
/// settle is over (`arm`).
/// The card itself keeps every click and drag: this view takes no hits, it
/// only watches the pointer through a tracking area, and the lean is a layer
/// transform, which leaves the card's frame (its hit area) where it was.
/// Under Reduce motion the shadow stays and the card does not lean.
@MainActor
final class LandingDepth: NSView {
    nonisolated static let maxDegrees: CGFloat = 4
    /// The celebration's glass: the spec's θmax and perspective.
    nonisolated static let glassDegrees: CGFloat = 6
    nonisolated static let glassEye: CGFloat = 900
    /// The sheen's strongest, at a full tilt (the spec's 0.12–0.18).
    nonisolated static let sheenAlpha: Float = 0.15

    private weak var card: NSView?
    private let calm: Bool
    private let glass: Bool
    private let contact = CALayer()
    private let ambient = CALayer()
    private var area: NSTrackingArea?
    /// Where the pointer asks the lean to go (-1...1 each way), and the lean now.
    private var aim = CGPoint.zero
    private var shown = CGPoint.zero
    private var velocity = CGPoint.zero
    private var springClock: FrameClock?
    private var lastStep: CFTimeInterval = 0
    private var sheen: CAGradientLayer?
    /// Glass: the pointer is followed from this time (the land settle first).
    private var armedAt: CFTimeInterval = 0
    private var armTask: Task<Void, Never>?

    /// Puts the depth under `card`, in its superview, and returns it.
    /// `glass` waits `arm` seconds before it follows the pointer.
    @discardableResult
    static func attach(under card: NSView, calm: Bool, glass: Bool = false, arm: Double = 0) -> LandingDepth? {
        guard let parent = card.superview else { return nil }
        let depth = LandingDepth(card: card, calm: calm, glass: glass && !calm, frame: parent.bounds)
        depth.autoresizingMask = [.width, .height]
        parent.addSubview(depth, positioned: .below, relativeTo: card)
        if depth.glass { depth.arm(after: arm) }
        return depth
    }

    private init(card: NSView, calm: Bool, glass: Bool, frame: NSRect) {
        self.card = card
        self.calm = calm
        self.glass = glass
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        Self.style(ambient: ambient, contact: contact)
        layer?.addSublayer(ambient)
        layer?.addSublayer(contact)
        card.wantsLayer = true
        if glass, let face = card.layer {
            let sheen = Self.makeSheen(size: card.bounds.size, radius: face.cornerRadius)
            face.addSublayer(sheen)
            self.sheen = sheen
        }
        // The card moves and scales with its panel (the dismiss): the shadow follows its frame.
        card.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(cardMoved), name: NSView.frameDidChangeNotification, object: card)
        arrange()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Off screen (the card dismissed and closed): nothing keeps ticking.
        if window == nil { stopSpring(); armTask?.cancel() }
    }

    private func arm(after seconds: Double) {
        armedAt = CACurrentMediaTime() + seconds
        armTask?.cancel()
        armTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self, let window = self.window else { return }
            // Already under the pointer when it lands: the tilt starts without a move.
            let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.follow(point: p)
        }
    }

    @objc private func cardMoved() {
        arrange()
        updateTrackingAreas()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    private func arrange() {
        guard let card else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ambient.frame = bounds
        contact.frame = bounds
        Self.shape(ambient: ambient, contact: contact, card: card.frame)
        sheen?.frame = card.bounds
        CATransaction.commit()
        if !calm { glass ? applyGlass() : applyLean(animated: false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = nil
        guard !calm, let card else { return }
        let new = NSTrackingArea(rect: card.frame, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { rest() }

    private func rest() {
        guard aim != .zero else { return }
        aim = .zero
        glass ? runSpring() : applyLean(animated: true)
    }

    private func follow(_ event: NSEvent) {
        follow(point: convert(event.locationInWindow, from: nil))
    }

    private func follow(point p: CGPoint) {
        guard let card else { return }
        let r = card.frame
        // Outside, or a button held (a click or the card's own drag): the card lies flat.
        guard r.contains(p), NSEvent.pressedMouseButtons == 0 else { return rest() }
        // Glass waits for the land settle.
        if glass, CACurrentMediaTime() < armedAt { return }
        aim = CGPoint(x: max(-1, min(1, (p.x - r.midX) / (r.width / 2))),
                      y: max(-1, min(1, (p.y - r.midY) / (r.height / 2))))
        glass ? runSpring() : applyLean(animated: true)
    }

    /// The card's lean for the pointer at `aim`: its face turns toward the
    /// pointer, the side under it goes back a little, in perspective.
    static func lean(aim: CGPoint, size: CGSize, degrees: CGFloat = maxDegrees, eye: CGFloat = 700) -> CATransform3D {
        guard aim != .zero else { return CATransform3DIdentity }
        let rad = degrees * .pi / 180
        let lift: CGFloat = 24
        var t = CATransform3DIdentity
        t.m34 = -1 / eye
        // Lifted toward the viewer so no corner goes behind the shadows' plane
        // (Core Animation would cut the card where it crosses them), and
        // scaled back by the same amount, so it does not look bigger.
        t = CATransform3DTranslate(t, 0, 0, lift)
        t = CATransform3DScale(t, (eye - lift) / eye, (eye - lift) / eye, 1)
        t = CATransform3DRotate(t, -aim.x * rad, 0, 1, 0)
        t = CATransform3DRotate(t, aim.y * rad, 1, 0, 0)
        return centred(t, CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// The glass's lean: 6° in a −1/900 perspective.
    static func glassLean(aim: CGPoint, size: CGSize) -> CATransform3D {
        lean(aim: aim, size: size, degrees: glassDegrees, eye: glassEye)
    }

    /// A soft white highlight, screen-blended, clipped to the card's corners.
    static func makeSheen(size: CGSize, radius: CGFloat) -> CAGradientLayer {
        let sheen = CAGradientLayer()
        sheen.type = .radial
        sheen.frame = CGRect(origin: .zero, size: size)
        sheen.cornerRadius = radius
        sheen.cornerCurve = .continuous
        sheen.masksToBounds = true
        sheen.compositingFilter = "screenBlendMode"
        sheen.colors = [NSColor(srgbRed: 0.85, green: 0.96, blue: 1, alpha: 1), NSColor(srgbRed: 0.85, green: 0.96, blue: 1, alpha: 0)].map(\.cgColor)
        sheen.opacity = 0
        sheen.actions = ["opacity": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "bounds": NSNull(), "position": NSNull()]
        place(sheen: sheen, aim: .zero)
        return sheen
    }

    /// The highlight sits opposite the lean (a fixed light), as strong as the lean is deep.
    static func place(sheen: CAGradientLayer, aim: CGPoint) {
        let c = CGPoint(x: 0.5 - 0.3 * aim.x, y: 0.5 - 0.3 * aim.y)
        sheen.startPoint = c
        sheen.endPoint = CGPoint(x: c.x + 0.7, y: c.y + 0.7)
        sheen.opacity = sheenAlpha * Float(min(1, hypot(aim.x, aim.y)))
    }

    // MARK: Glass spring

    private func runSpring() {
        guard springClock == nil else { return }
        lastStep = CACurrentMediaTime()
        springClock = FrameClock(screen: window?.screen) { [weak self] clock in
            // The card closed and let go of this view: the clock stops too.
            guard let self else { return clock.invalidate() }
            self.stepSpring()
        }
    }

    private func stopSpring() {
        springClock?.invalidate()
        springClock = nil
    }

    private func stepSpring() {
        let now = CACurrentMediaTime()
        // Small fixed steps, so a slow frame never makes the spring blow up.
        var left = min(0.05, now - lastStep)
        lastStep = now
        let spring = LandSpring.tilt
        var x = Double(shown.x), y = Double(shown.y), vx = Double(velocity.x), vy = Double(velocity.y)
        while left > 0 {
            let h = min(left, 1.0 / 240)
            spring.step(value: &x, velocity: &vx, target: Double(aim.x), dt: h)
            spring.step(value: &y, velocity: &vy, target: Double(aim.y), dt: h)
            left -= h
        }
        shown = CGPoint(x: x, y: y)
        velocity = CGPoint(x: vx, y: vy)
        if abs(x - Double(aim.x)) < 0.001, abs(y - Double(aim.y)) < 0.001, abs(vx) < 0.01, abs(vy) < 0.01 {
            shown = aim
            velocity = .zero
            stopSpring()
        }
        applyGlass()
    }

    private func applyGlass() {
        guard let card, let layer = card.layer else { return }
        let (contactOffset, ambientOffset) = Self.offsets(aim: shown)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = Self.glassLean(aim: shown, size: card.bounds.size)
        contact.shadowOffset = contactOffset
        ambient.shadowOffset = ambientOffset
        if let sheen { Self.place(sheen: sheen, aim: shown) }
        CATransaction.commit()
    }

    /// Two shadows: a wide soft one and a tight dark one at the card's foot.
    static func style(ambient: CALayer, contact: CALayer) {
        for (shadow, radius, opacity) in [(ambient, 26.0, 0.30), (contact, 7.0, 0.38)] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowRadius = radius
            shadow.shadowOpacity = Float(opacity)
        }
        let (c, a) = offsets(aim: .zero)
        contact.shadowOffset = c
        ambient.shadowOffset = a
    }

    /// The contact sits a little inside the card's footprint, so the card reads as resting on the desktop.
    static func shape(ambient: CALayer, contact: CALayer, card r: CGRect) {
        ambient.shadowPath = CGPath(roundedRect: r.insetBy(dx: 10, dy: 6), cornerWidth: 18, cornerHeight: 18, transform: nil)
        contact.shadowPath = CGPath(roundedRect: r.insetBy(dx: 4, dy: 2), cornerWidth: 18, cornerHeight: 18, transform: nil)
    }

    /// The shadows slide away from the side that lifts, a few points (4–6 at a full lean), and drop a little further while leaning.
    static func offsets(aim: CGPoint) -> (contact: CGSize, ambient: CGSize) {
        let lift = min(1, hypot(aim.x, aim.y))
        let shift = CGSize(width: -aim.x * 5, height: -aim.y * 4)
        return (CGSize(width: shift.width, height: -4 - 2 * lift + shift.height),
                CGSize(width: shift.width * 1.6, height: -16 - 4 * lift + shift.height * 1.6))
    }

    private func applyLean(animated: Bool) {
        guard let layer = card?.layer, let card else { return }
        let to = Self.lean(aim: aim, size: card.bounds.size)
        let lifted = aim != .zero
        let (contactOffset, ambientOffset) = Self.offsets(aim: aim)
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = to
            contact.shadowOffset = contactOffset
            ambient.shadowOffset = ambientOffset
            CATransaction.commit()
            return
        }
        let seconds = lifted ? 0.22 : 0.4
        func ease<T>(_ target: CALayer, _ key: String, from: T, to: T) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = seconds
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            a.preferredFrameRateRange = FrameRate.range(on: card.window?.screen)
            target.add(a, forKey: key)
        }
        let nowTransform = layer.presentation()?.transform ?? layer.transform
        let nowContact = contact.presentation()?.shadowOffset ?? contact.shadowOffset
        let nowAmbient = ambient.presentation()?.shadowOffset ?? ambient.shadowOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to
        contact.shadowOffset = contactOffset
        ambient.shadowOffset = ambientOffset
        CATransaction.commit()
        ease(layer, "transform", from: NSValue(caTransform3D: nowTransform), to: NSValue(caTransform3D: to))
        ease(contact, "shadowOffset", from: NSValue(size: nowContact), to: NSValue(size: contactOffset))
        ease(ambient, "shadowOffset", from: NSValue(size: nowAmbient), to: NSValue(size: ambientOffset))
    }
}

#if DEBUG

// MARK: - Harness

/// `--feel-shots <dir>`: the landed card flat and leaning, rendered with
/// CARenderer so the perspective and shadows are the real thing.
/// `--feel-bench`: plays each effect's Preview on screen and prints the
/// frame clock's rate and the work per frame.
public enum FeelProbe {
    @MainActor
    public static func writeShots(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [URL] = []
        for (name, aim) in [("landed-flat", CGPoint.zero), ("landed-lean-right", CGPoint(x: 0.85, y: 0.6)),
                            ("landed-lean-left", CGPoint(x: -0.85, y: -0.5))] {
            let url = folder.appendingPathComponent("\(name).png")
            try shot(aim: aim, to: url)
            out.append(url)
        }
        return out
    }

    @MainActor
    private static func shot(aim: CGPoint, to url: URL) throws {
        let photo = PeekThumbnail.decode(PortalPreview.samplePhoto.thumb).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        let card = LandingView(image: photo ?? NSImage(), title: "IMG_2041.HEIC", url: nil)
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { throw CocoaError(.fileWriteUnknown) }
        card.cacheDisplay(in: card.bounds, to: rep)
        let m: CGFloat = 80, size = CGSize(width: card.bounds.width + 2 * m, height: card.bounds.height + 2 * m)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.42, alpha: 1).cgColor
        let rect = CGRect(x: m, y: m, width: card.bounds.width, height: card.bounds.height)
        let ambient = CALayer(), contact = CALayer()
        for layer in [ambient, contact] { layer.frame = root.bounds; root.addSublayer(layer) }
        LandingDepth.style(ambient: ambient, contact: contact)
        LandingDepth.shape(ambient: ambient, contact: contact, card: rect)
        let (c, a) = LandingDepth.offsets(aim: aim)
        contact.shadowOffset = c
        ambient.shadowOffset = a
        let face = CALayer()
        face.anchorPoint = .zero
        face.frame = rect
        face.contents = rep.cgImage
        face.cornerRadius = 18
        face.masksToBounds = true
        face.transform = LandingDepth.lean(aim: aim, size: rect.size)
        root.addSublayer(face)
        try write(render(root), to: url)
    }

    /// A layer tree drawn by CARenderer, so perspective, shadows and blend modes are the real thing.
    static func render(_ root: CALayer) throws -> CGImage {
        let size = root.bounds.size
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CocoaError(.featureUnsupported)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width),
                                                            height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else { throw CocoaError(.fileWriteUnknown) }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue])
        renderer.layer = root
        renderer.bounds = root.frame
        // CARenderer draws only a committed tree.
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { throw CocoaError(.fileWriteUnknown) }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let w = texture.width, h = texture.height, row = w * 4
        var bytes = [UInt8](repeating: 0, count: row * h)
        texture.getBytes(&bytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // CARenderer draws y-up; a CGImage's first row is its top.
        bytes = stride(from: h - 1, through: 0, by: -1).flatMap { bytes[($0 * row)..<($0 * row + row)] }
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let out = NSBitmapImageRep(cgImage: image)
        guard let png = out.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// Plays every effect's Preview through the real presenter and prints the frame clock's numbers.
    @MainActor
    public static func bench(seconds: Double = 2.4) -> [String] {
        let presenter = LandingPresenter()
        presenter.holdSeconds = 0.3
        let stats = FrameStats()
        FrameClock.stats = stats
        defer { FrameClock.stats = nil; presenter.tearDown() }
        PortalHaptics.refresh()
        var lines = NSScreen.screens.map { "screen \(Int($0.frame.width))×\(Int($0.frame.height)): up to \($0.maximumFramesPerSecond) fps" }
        for effect in PortalEffect.allCases {
            for _ in 0..<2 {
                stats.reset()
                presenter.preview(effect: effect)
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
            }
            lines.append("\(effect.rawValue): \(stats.summary)")
        }
        lines.append("haptics: force touch trackpad \(PortalHaptics.isSupported ? "found" : "not found")")
        return lines
    }
}
#endif
