//
//  LandingCelebration.swift
//  DropPortal
//
//  The two landing touches every crossing effect shares, on the Mac. Each
//  has its own switch under Look & sound, both on by default.
//
//  Landing celebration: at the impact a ring of about 20 sparks in the
//  photo's own colours leaves the card's perimeter (GPU particles when the
//  Metal path is up, sprite layers otherwise), a soft glow under the card
//  fades, the pop settles on a critically damped spring (0.35 s, bounce 0.1)
//  and, after that, the landed card tilts like glass toward the pointer
//  (LandingDepth's glass mode in PortalFeel.swift: 6°, m34 −1/900, a 0.25 s
//  spring, a sheen). The trackpad's land tap and the contact shadow are the
//  ones PortalFeel already plays; nothing here duplicates them.
//
//  Kinetic filename: the landed card's name comes in letter by letter, blur
//  to sharp and rising a few points, staggered min(25 ms, 300 ms / n), all
//  in within 0.65 s; the name is cut in the middle (keeping its extension)
//  before it is split into letters. VoiceOver keeps reading the label itself,
//  the full name, once: the letters are layers, never accessibility elements.
//
//  Reduce motion: no sparks, no settle spring, no tilt; the name fades.
//  The numbers are in DropPortalCore/LandingTouches.swift (shared with the
//  tests); the phone's mirror of the name is in WebPage.swift (`kineticName`).
//

import AppKit
import Metal
import QuartzCore
import DropPortalCore

// MARK: - Settle

enum LandingCelebration {
    /// The landing pop for `CardLook.land` with the celebration on: up to the
    /// peak in 70 ms, then home on the land spring, no dip and rebound.
    static func settle(peak: CGFloat) -> (CGFloat) -> CGFloat {
        { s in
            guard s > 0.07 else { return 1 + (peak - 1) * max(0, s) / 0.07 }
            return 1 + (peak - 1) * CGFloat(LandSpring.settle.remaining(at: Double(s - 0.07)))
        }
    }

    /// The tilt starts after the settle's perceptual end (it began at the
    /// impact, the landed card shows 0.16 s later).
    static let tiltArm = LandSpring.settle.duration - 0.16
}

// MARK: - Photo colours

/// The sparks' two colours: the picture's two strongest hues, pushed toward white.
enum PhotoTones {
    /// Sampled off the main thread; `done` runs on main with nil for a picture without colour.
    @MainActor
    static func sample(_ image: NSImage?, done: @escaping @MainActor ([NSColor]?) -> Void) {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return done(nil) }
        let picture = cg
        DispatchQueue.global(qos: .utility).async {
            let tones = tones(of: picture)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(tones) } }
        }
    }

    /// 16 × 16 pixels, hues in twelve bins weighted by saturation and brightness.
    nonisolated static func tones(of image: CGImage) -> [NSColor]? {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var weight = [Double](repeating: 0, count: 12)
        var sum = [SIMD3<Double>](repeating: .zero, count: 12)
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            let c = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2])) / 255
            let mx = c.max(), mn = c.min(), s = mx > 0 ? (mx - mn) / mx : 0
            guard s > 0.18, mx > 0.2 else { continue }
            var h: Double
            if mx == c.x { h = (c.y - c.z) / (mx - mn) } else if mx == c.y { h = 2 + (c.z - c.x) / (mx - mn) } else { h = 4 + (c.x - c.y) / (mx - mn) }
            h = (h / 6).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
            let bin = min(11, Int(h * 12)), w = s * mx
            weight[bin] += w
            sum[bin] += c * w
        }
        let order = weight.indices.sorted { weight[$0] > weight[$1] }
        guard let first = order.first, weight[first] > 0.6 else { return nil }
        // The second: a different hue that still counts, else a lighter first.
        let second = order.dropFirst().first { b in
            let gap = abs(b - first)
            return min(gap, 12 - gap) >= 2 && weight[b] > weight[first] * 0.2
        }
        func tone(_ bin: Int, white: Double) -> NSColor {
            var c = sum[bin] / weight[bin]
            // Bright as a light, then toward white.
            c /= max(0.001, c.max())
            c = c + (SIMD3(repeating: 1) - c) * white
            return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
        }
        return [tone(first, white: 0.3), second.map { tone($0, white: 0.35) } ?? tone(first, white: 0.6)]
    }

    /// No picture (a document) or no colour in it: the effect's own, so every tint and Rainbow works.
    static func fallback(_ palette: PortalPalette) -> [NSColor] { [palette.glow, palette.core] }
}

// MARK: - Sparks

/// The ring of sparks and the glow under the card, in the card's panel,
/// behind the card; takes no clicks and removes itself when the burst is over.
@MainActor
final class SparkView: NSView {
    private var gpu: SparkGPU?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Plays the burst around `card` (in `parent`'s coordinates). `still` draws that instant (the harness).
    @discardableResult
    static func play(in parent: NSView, below sibling: NSView?, card: CGRect, tones: [NSColor],
                     still: Double? = nil) -> SparkView {
        let view = SparkView(frame: parent.bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        parent.addSubview(view, positioned: .below, relativeTo: sibling)
        let ring = SparkRing(count: SparkRing.count(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled), size: card.size)
        view.glow(card: card, color: tones.first ?? .white, still: still)
        if let engine = MetalFX.forCrossing(), let pipeline = SparkGPU.pipeline(for: engine) {
            view.gpu = SparkGPU(engine: engine, pipeline: pipeline, in: view, card: card, tones: tones,
                                count: ring.sparks.count, still: still)
        } else {
            view.sprites(ring, card: card, tones: tones, still: still)
        }
        if still == nil {
            // Gone with its last spark; the GPU canvas stops on its own.
            Task { @MainActor [weak view] in
                try? await Task.sleep(nanoseconds: UInt64((SparkRing.seconds + 0.08) * 1_000_000_000))
                view?.gpu?.stop()
                view?.removeFromSuperview()
            }
        }
        return view
    }

    /// One soft radial glow about 1.3× the card, 0.25 at the impact, gone in 0.35 s.
    private func glow(card: CGRect, color: NSColor, still: Double?) {
        guard let layer else { return }
        let g = CAGradientLayer()
        g.type = .radial
        let w = card.width * 1.3, h = card.height * 1.3
        g.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        g.position = CGPoint(x: card.midX, y: card.midY)
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        g.colors = [color.withAlphaComponent(1), color.withAlphaComponent(0.4), color.withAlphaComponent(0)].map(\.cgColor)
        g.locations = [0, 0.55, 1]
        g.opacity = 0
        layer.addSublayer(g)
        timeline(g, 0.35, still: still, opacity: { s in 0.25 * (1 - s / 0.35) })
    }

    /// The Core Animation path: one glow sprite per spark, each a pure function of its time.
    private func sprites(_ ring: SparkRing, card: CGRect, tones: [NSColor], still: Double?) {
        guard let layer else { return }
        let c = SIMD2(Double(card.midX), Double(card.midY))
        for spark in ring.sparks {
            let color = tones[spark.tone % max(1, tones.count)]
            // `size` is the spark's radius, as in the mockup; the sprite's white core is about a third of it.
            let sprite = Sprite.layer(.glow, color, size: CGFloat(spark.size * 5.5), at: CGPoint(x: c.x + spark.start.x, y: c.y + spark.start.y))
            sprite.compositingFilter = "plusL"
            layer.addSublayer(sprite)
            timeline(sprite, spark.life, still: still,
                     opacity: { s in CGFloat(SparkRing.state(spark, at: Double(s))?.alpha ?? 0) },
                     transform: { s in
                         let st = SparkRing.state(spark, at: Double(s))
                         return CATransform3DMakeScale(CGFloat((st?.size ?? 0) / spark.size), CGFloat((st?.size ?? 0) / spark.size), 1)
                     },
                     position: { s in
                         let p = SparkRing.state(spark, at: Double(s))?.position ?? spark.start
                         return CGPoint(x: c.x + p.x, y: c.y + p.y)
                     })
        }
    }
}

// MARK: - GPU sparks

/// The same ring on the GPU: one instanced quad per spark, its place a pure
/// function of (index, time, seed) like `SparkRing`, drawn on an `FXCanvas`
/// by the shared `FXDriver`. Its own two shaders, compiled once off main the
/// first time the Metal path is up, so MetalFX's pipelines stay as they are.
@MainActor
final class SparkGPU: FXClient {
    private let canvas: FXCanvas
    private let pipeline: MTLRenderPipelineState
    private var uniforms = FXUniforms()
    private let start: CFTimeInterval
    private var stopped = false

    init(engine: MetalFX, pipeline: MTLRenderPipelineState, in view: NSView, card: CGRect, tones: [NSColor],
         count: Int, still: Double?) {
        // Only the card and the sparks' reach: a small canvas.
        let reach = CGFloat(SparkRing.reach) + 8
        let frame = card.insetBy(dx: -reach - card.width * 0.05, dy: -reach - card.height * 0.05)
        canvas = FXCanvas(engine: engine, frame: frame, scale: view.window?.backingScaleFactor ?? 2, maxPixels: 600_000)
        self.pipeline = pipeline
        start = CACurrentMediaTime()
        func rgb(_ c: NSColor) -> SIMD3<Float> {
            let s = c.usingColorSpace(.sRGB) ?? c
            return SIMD3(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent))
        }
        let a = rgb(tones.first ?? .white), b = rgb(tones.count > 1 ? tones[1] : tones.first ?? .white)
        uniforms.a = SIMD4(0, Float(count), 7, 0)
        uniforms.b = SIMD4(Float(frame.width), Float(frame.height), 0, 0)
        uniforms.c = SIMD4(Float(card.midX - frame.minX), Float(card.midY - frame.minY), Float(card.width), Float(card.height))
        uniforms.d = SIMD4(18, 0, 0, 0)
        uniforms.e = SIMD4(a.x, a.y, a.z, 0)
        uniforms.f = SIMD4(b.x, b.y, b.z, 0)
        uniforms.i = SIMD4(Float(canvas.pxScale), 0, 0, 0)
        view.layer?.addSublayer(canvas.layer)
        if let still {
            draw(at: still)
        } else {
            FXDriver.shared.wake(self)
        }
    }

    private func draw(at t: Double) {
        uniforms.a.x = Float(t)
        canvas.draw([FXDraw(pipeline: pipeline, uniforms: uniforms, texture: nil, instances: Int(uniforms.a.y))])
    }

    func tick(now: CFTimeInterval) -> Bool {
        let t = now - start
        guard !stopped, t <= SparkRing.seconds else {
            canvas.clear()
            return false
        }
        draw(at: t)
        return true
    }

    func stop() {
        stopped = true
        FXDriver.shared.remove(self)
        canvas.layer.removeFromSuperlayer()
    }

    // MARK: Pipeline

    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: (device: ObjectIdentifier, state: MTLRenderPipelineState)?
    nonisolated(unsafe) private static var compiling = false

    /// The spark pipeline for this engine, or nil while it compiles (that
    /// crossing takes the Core Animation path). The harness compiles at once.
    static func pipeline(for engine: MetalFX) -> MTLRenderPipelineState? {
        let id = ObjectIdentifier(engine.device)
        lock.lock()
        if let compiled, compiled.device == id { lock.unlock(); return compiled.state }
        let start = !compiling
        compiling = true
        lock.unlock()
        if MetalFX.mode == .stills {
            let state = make(device: engine.device)
            lock.lock(); compiled = state.map { (id, $0) }; compiling = false; lock.unlock()
            return state
        }
        if start {
            let device = engine.device
            DispatchQueue.global(qos: .utility).async {
                let state = make(device: device)
                lock.lock(); compiled = state.map { (id, $0) }; compiling = false; lock.unlock()
            }
        }
        return nil
    }

    /// Warm the pipeline before the first landing (a crossing starts it).
    static func warm() {
        guard let engine = MetalFX.forCrossing() else { return }
        _ = pipeline(for: engine)
    }

    /// deactivate(): the pipeline goes with the engine.
    static func reset() {
        lock.lock(); compiled = nil; lock.unlock()
    }

    nonisolated private static func make(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let v = library.makeFunction(name: "spark_vs"), let f = library.makeFunction(name: "spark_fs") else {
            PortalLog.write("metal: spark shaders did not compile")
            return nil
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = f
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one
        c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .one
        c.destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    // a: t, count, seed   b: canvas w, h (pt)   c: card cx, cy, w, h   d: corner radius
    // e: first tone rgb   f: second tone rgb    i: pixels per point
    nonisolated static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4 a, b, c, d, e, f, g, h, i, j; };
    struct SOut { float4 pos [[position]]; float2 local; float4 color; };
    static float h11(float n) { return fract(sin(n * 127.1) * 43758.5453); }

    vertex SOut spark_vs(uint vid [[vertex_id]], uint iid [[instance_id]], constant U& u [[buffer(0)]]) {
        SOut o;
        float n = u.a.y, fi = float(iid), seed = u.a.z, t = u.a.x;
        // Evenly round the ring with a little jitter, as SparkRing.
        float ang = (fi + .5 + (h11(fi * 1.31 + seed) - .5) * .7) / n * 6.2831853;
        float2 d = float2(cos(ang), sin(ang));
        float2 hs = u.c.zw * .5;
        float r = min(u.d.x, min(hs.x, hs.y));
        float tx = abs(d.x) > 1e-5 ? hs.x / abs(d.x) : 1e9, ty = abs(d.y) > 1e-5 ? hs.y / abs(d.y) : 1e9;
        float2 p = d * min(tx, ty), cc = hs - r;
        if (abs(p.x) > cc.x && abs(p.y) > cc.y) {
            float2 c = cc * sign(p); float b = dot(d, c), k = dot(c, c) - r * r;
            p = d * (b + sqrt(max(0., b * b - k)));
        }
        float speed = mix(180., 320., h11(fi * 2.17 + seed + 5));
        float life = mix(.45, .7, h11(fi * 3.71 + seed + 9));
        float size = mix(2., 5., h11(fi * 5.03 + seed + 13));
        float uu = clamp(t / life, 0., 1.);
        bool alive = t >= 0 && t < life;
        float2 at = u.c.xy + p + d * speed * (1 - exp(-4 * t)) / 4;
        float rad = size * (1 - uu);
        float2 corner = float2(float(vid & 1), float(vid >> 1)) * 2 - 1;
        float2 pt = at + corner * rad * 3;
        float2 ndc = pt / u.b.xy * 2 - 1;
        o.pos = float4(alive ? ndc : float2(-9, -9), 0, 1);
        o.local = corner * 3;
        o.color = float4((iid & 1) == 0 ? u.e.rgb : u.f.rgb, (1 - uu) * min(1., uu / .04));
        return o;
    }

    fragment float4 spark_fs(SOut in [[stage_in]]) {
        float r = length(in.local);
        float core = smoothstep(1., .55, r);
        float halo = exp(-r * r * .7) * .5;
        float a = in.color.a * min(1., core + halo);
        float3 c = mix(in.color.rgb, float3(1), core * .55);
        return float4(c * a, a * .7);
    }
    """#
}

// MARK: - Kinetic filename

/// The landed card's name, letter by letter, over its own label: the label
/// stays (VoiceOver reads it, the full name) but draws nothing while the
/// letters are up; each letter is a sharp and a blurred bitmap layer, cut,
/// laid out and drawn off the main thread, then started on main.
@MainActor
final class KineticTitleView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// One letter, ready to show: its two bitmaps, its box and its place.
    struct Letter: @unchecked Sendable {
        var index: Int
        var sharp: CGImage
        var soft: CGImage
        var size: CGSize
        var home: CGPoint
        /// The extension's letters are a little dimmer.
        var dim = 1.0
    }

    private static let queue = DispatchQueue(label: "drop-portal.kinetic-name", qos: .userInitiated)

    /// Plays `name` into `label`. `still` draws that instant at once (the harness).
    @discardableResult
    static func play(on label: NSTextField, name: String, calm: Bool, still: Double? = nil) -> KineticTitleView? {
        guard let parent = label.superview else { return nil }
        if calm {
            // Reduce motion: the whole label fades, no blur, no rise.
            if let still {
                label.alphaValue = CGFloat(KineticName.calmOpacity(at: still))
            } else {
                label.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = KineticName.calmFade
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    label.animator().alphaValue = 1
                }
            }
            return nil
        }
        let font = (label.font ?? .systemFont(ofSize: 12, weight: .medium)) as CTFont
        let color = (label.textColor ?? .white).cgColor
        let view = KineticTitleView(frame: label.frame)
        view.autoresizingMask = label.autoresizingMask
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        parent.addSubview(view, positioned: .above, relativeTo: label)
        label.alphaValue = 0
        // NSTextField draws 2 pt in from each side.
        let width = Double(label.bounds.width - 4), height = label.bounds.height
        let scale = parent.window?.backingScaleFactor ?? 2
        if let still {
            let (text, letters) = layout(name, font: font, color: color, width: width, height: height, scale: scale)
            view.start(letters, count: text.count, font: font, still: still)
            return view
        }
        queue.async {
            let (text, letters) = layout(name, font: font, color: color, width: width, height: height, scale: scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Taken away (a batch title, the card gone) while the letters were drawn.
                    guard view.superview != nil else { return }
                    view.start(letters, count: text.count, font: font, still: nil)
                }
            }
        }
        return view
    }

    /// Back to the plain label (a batch's "1 of 3 received" replaces the name).
    static func stop(on label: NSTextField) {
        label.superview?.subviews.filter { $0 is KineticTitleView }.forEach { $0.removeFromSuperview() }
        label.alphaValue = 1
    }

    fileprivate func start(_ letters: [Letter], count n: Int, font: CTFont, still: Double?) {
        guard let root = layer else { return }
        let total = KineticName.total(count: n), em = Double(CTFontGetSize(font))
        for letter in letters {
            let i = letter.index, home = letter.home
            let box = CALayer()
            box.anchorPoint = .zero
            box.bounds = CGRect(origin: .zero, size: letter.size)
            box.position = home
            let sharpLayer = CALayer(), softLayer = CALayer()
            for (l, image) in [(softLayer, letter.soft), (sharpLayer, letter.sharp)] {
                l.frame = box.bounds
                l.contents = image
                box.addSublayer(l)
            }
            box.opacity = 0
            root.addSublayer(box)
            let dim = CGFloat(letter.dim)
            timeline(box, total, still: still,
                     opacity: { t in dim * CGFloat(KineticName.glyph(i, of: n, at: Double(t)).opacity) },
                     position: { t in
                         let g = KineticName.glyph(i, of: n, at: Double(t))
                         // The tracking closes underneath: each letter drifts in from a little right.
                         return CGPoint(x: home.x + CGFloat(g.spread * em * 2), y: home.y - CGFloat(g.drop))
                     })
            timeline(softLayer, total, still: still, opacity: { t in
                CGFloat(KineticName.glyph(i, of: n, at: Double(t)).blur / KineticName.blur)
            })
            timeline(sharpLayer, total, still: still, opacity: { t in
                1 - CGFloat(KineticName.glyph(i, of: n, at: Double(t)).blur / KineticName.blur)
            })
        }
    }

    /// Cut, laid out and drawn: the label's text and its letters (spaces have none).
    nonisolated static func layout(_ name: String, font: CTFont, color: CGColor, width: Double, height: CGFloat,
                                   scale: CGFloat) -> (String, [Letter]) {
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                    .init(kCTForegroundColorAttributeName as String): color]
        func measure(_ s: String) -> Double {
            Double(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), nil, nil, nil))
        }
        let text = KineticName.truncate(name, maxWidth: width, width: measure)
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let baseline = ((height - (ascent + descent)) / 2 + descent).rounded()
        let chars = Array(text)
        let extStart = KineticName.extensionStart(in: text) ?? chars.count
        let pad: CGFloat = 5
        var out: [Letter] = []
        var utf16 = 0
        for (i, ch) in chars.enumerated() {
            let unit = String(ch).utf16.count
            defer { utf16 += unit }
            guard !ch.isWhitespace else { continue }
            let x0 = 2 + CTLineGetOffsetForStringIndex(line, utf16, nil)
            let x1 = 2 + CTLineGetOffsetForStringIndex(line, utf16 + unit, nil)
            let size = CGSize(width: max(1, x1 - x0) + 2 * pad, height: ascent + descent + 2 * pad)
            let one = attributed.attributedSubstring(from: NSRange(location: utf16, length: unit))
            let origin = CGPoint(x: pad + x0 - floor(x0), y: pad + descent)
            guard let sharp = render(one, size: size, origin: origin, blur: 0, color: color, scale: scale),
                  let soft = render(one, size: size, origin: origin, blur: CGFloat(KineticName.blur), color: color, scale: scale)
            else { continue }
            var letter = Letter(index: i, sharp: sharp, soft: soft, size: size,
                                home: CGPoint(x: floor(x0) - pad, y: baseline - descent - pad))
            letter.dim = i >= extStart ? KineticName.extensionAlpha : 1
            out.append(letter)
        }
        return (text, out)
    }

    /// One letter as a bitmap at the screen's scale; blurred through its own
    /// shadow (the letter drawn far outside, only its shadow lands): no Core Image.
    nonisolated private static func render(_ letter: NSAttributedString, size: CGSize, origin: CGPoint, blur: CGFloat,
                                           color: CGColor, scale: CGFloat) -> CGImage? {
        let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let one = CTLineCreateWithAttributedString(letter)
        if blur > 0 {
            let far: CGFloat = 4000
            ctx.setShadow(offset: CGSize(width: far * scale, height: 0), blur: blur * scale, color: color)
            ctx.textPosition = CGPoint(x: origin.x - far, y: origin.y)
        } else {
            ctx.textPosition = origin
        }
        CTLineDraw(one, ctx)
        return ctx.makeImage()
    }
}

#if DEBUG

// MARK: - Harness

/// Stills of the landing touches, drawn by CARenderer (FeelProbe.render):
/// `land-sparks-<ms>[-gpu][-light]` the ring around the landed card,
/// `land-sparks-doc-rainbow-<ms>` a document in Rainbow, `land-tilt-<pose>`
/// the glass with its sheen, `kinetic-<ms>` the name coming in,
/// `kinetic-calm-<ms>` its Reduce motion fade. Written by `--peek-shots`
/// (Core Animation) and `--metal-shots` (GPU sparks, `-gpu`).
public enum LandingTouchesProbe {
    @MainActor
    public static func writeShots(to folder: URL, gpu: Bool) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [URL] = []
        let photo = PortalPreview.samplePhoto
        let picture = PeekThumbnail.decode(photo.thumb)
        let tones = picture.flatMap(PhotoTones.tones(of:)) ?? PhotoTones.fallback(.of(.portal))
        let suffix = gpu ? "-gpu" : ""
        for ms in [30, 120, 250, 450] {
            for light in [false, true] where !(light && ms != 120) {
                let url = folder.appendingPathComponent("land-sparks-\(ms)\(suffix)\(light ? "-light" : "").png")
                try FeelProbe.write(sparks(at: Double(ms) / 1000, tones: tones, light: light, picture: picture), to: url)
                out.append(url)
            }
        }
        guard !gpu else { return out }
        // A document has no colours: the effect's own, here Rainbow's.
        let rainbow = PortalPalette(tint: .rainbow, at: Date(timeIntervalSince1970: 0))
        let doc = folder.appendingPathComponent("land-sparks-doc-rainbow-120.png")
        try FeelProbe.write(sparks(at: 0.12, tones: PhotoTones.fallback(rainbow), light: false, picture: nil), to: doc)
        out.append(doc)
        for (name, aim) in [("flat", CGPoint.zero), ("right", CGPoint(x: 0.9, y: 0.55)), ("left", CGPoint(x: -0.8, y: -0.6))] {
            let url = folder.appendingPathComponent("land-tilt-\(name).png")
            try FeelProbe.write(tilt(aim: aim, picture: picture), to: url)
            out.append(url)
        }
        for ms in [0, 60, 140, 250, 400, 650] {
            let url = folder.appendingPathComponent("kinetic-\(ms).png")
            try FeelProbe.write(kinetic(at: Double(ms) / 1000, calm: false, picture: picture, name: photo.name), to: url)
            out.append(url)
        }
        let short = folder.appendingPathComponent("kinetic-short-200.png")
        try FeelProbe.write(kinetic(at: 0.2, calm: false, picture: picture, name: "Notes.txt"), to: short)
        let calm = folder.appendingPathComponent("kinetic-calm-100.png")
        try FeelProbe.write(kinetic(at: 0.1, calm: true, picture: picture, name: photo.name), to: calm)
        out += [short, calm]
        return out
    }

    /// The landing touches' costs: the main thread's work to start each (it
    /// runs once, at the landing), the GPU sparks' frame time, and the CA
    /// sparks' per-frame render cost.
    @MainActor
    public static func bench(gpu: Bool) -> [String] {
        func ms(_ body: () -> Void, runs: Int = 20) -> String {
            var times: [Double] = []
            for _ in 0..<runs { let t = CACurrentMediaTime(); body(); times.append(CACurrentMediaTime() - t) }
            times.sort()
            return String(format: "median %.2f ms, worst %.2f ms", times[times.count / 2] * 1000, times.last! * 1000)
        }
        var lines: [String] = []
        let picture = PeekThumbnail.decode(PortalPreview.samplePhoto.thumb)!
        lines.append("landing tones (off main): " + ms({ _ = PhotoTones.tones(of: picture) }))
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 588))
        parent.wantsLayer = true
        let slot = NSView(frame: NSRect(x: 160, y: 160, width: 240, height: 268))
        parent.addSubview(slot)
        let tones = PhotoTones.tones(of: picture) ?? [.white]
        let saved = MetalFX.mode
        MetalFX.mode = .off
        lines.append("landing sparks CA start (main): " + ms({ SparkView.play(in: parent, below: slot, card: slot.frame, tones: tones).removeFromSuperview() }))
        // One CA frame mid-burst, drawn by CARenderer: what the render server does per frame.
        let burst = SparkView.play(in: parent, below: slot, card: slot.frame, tones: tones, still: 0.15)
        if let layer = burst.layer, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            layer.removeFromSuperlayer()
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1120, height: 1176, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            if let target = device.makeTexture(descriptor: d) {
                lines.append(String(format: "landing sparks CA frame (render, 2x): %.2f ms", MetalProbe.render(layer, target: target, queue: queue)))
            }
        }
        if gpu {
            MetalFX.mode = .stills
            if let engine = MetalFX.forCrossing(), let pipeline = SparkGPU.pipeline(for: engine) {
                var u = FXUniforms()
                u.a = SIMD4(0.15, 20, 7, 0); u.b = SIMD4(424, 452, 0, 0); u.c = SIMD4(212, 226, 240, 268)
                u.d = SIMD4(18, 0, 0, 0); u.e = SIMD4(1, 1, 1, 0); u.f = SIMD4(1, 1, 1, 0); u.i = SIMD4(2, 0, 0, 0)
                _ = engine.takeStats()
                for _ in 0..<60 { _ = engine.image([FXDraw(pipeline: pipeline, uniforms: u, texture: nil, instances: 20)], width: 848, height: 904) }
                let s = engine.takeStats()
                lines.append(String(format: "landing sparks GPU: %d frames, mean %.3f ms, worst %.3f ms (848×904 px)", s.frames, s.mean, s.worst))
            }
        }
        MetalFX.mode = saved
        let font = NSFont.systemFont(ofSize: 12, weight: .medium) as CTFont, white = NSColor.white.cgColor
        for (label, name) in [("12 letters", "IMG_2041.JPG"), ("40 letters", "IMG_4821 holiday at the beach with friends.HEIC")] {
            lines.append("kinetic name \(label) letters (off main): " + ms({
                _ = KineticTitleView.layout(name, font: font, color: white, width: 212, height: 18, scale: 2)
            }, runs: 10))
            let (text, letters) = KineticTitleView.layout(name, font: font, color: white, width: 212, height: 18, scale: 2)
            lines.append("kinetic name \(label) start (main): " + ms({
                let view = KineticTitleView(frame: NSRect(x: 0, y: 0, width: 216, height: 18))
                view.wantsLayer = true
                view.start(letters, count: text.count, font: font, still: nil)
            }, runs: 10))
        }
        return lines
    }

    @MainActor
    private static func card(_ picture: CGImage?, name: String) -> LandingView {
        let image = picture.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } ?? NSWorkspace.shared.icon(for: .pdf)
        return LandingView(image: image, title: name, url: nil)
    }

    @MainActor
    private static func face(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    @MainActor
    private static func backdrop(_ size: CGSize, light: Bool) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        root.backgroundColor = (light ? NSColor(srgbRed: 0.88, green: 0.9, blue: 0.94, alpha: 1)
                                      : NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 1)).cgColor
        return root
    }

    @MainActor
    private static func sparks(at t: Double, tones: [NSColor], light: Bool, picture: CGImage?) throws -> CGImage {
        let landed = card(picture, name: "IMG_4821.HEIC")
        let m: CGFloat = 110, size = CGSize(width: landed.bounds.width + 2 * m, height: landed.bounds.height + 2 * m)
        let root = backdrop(size, light: light)
        let parent = NSView(frame: NSRect(origin: .zero, size: size))
        parent.wantsLayer = true
        let slot = NSView(frame: NSRect(x: m, y: m, width: landed.bounds.width, height: landed.bounds.height))
        parent.addSubview(slot)
        let burst = SparkView.play(in: parent, below: slot, card: slot.frame, tones: tones, still: t)
        // Off a window AppKit does not attach the view's layer: draw it directly.
        if let layer = burst.layer {
            layer.removeFromSuperlayer()
            layer.frame = burst.frame
            root.addSublayer(layer)
        }
        let f = CALayer()
        f.frame = slot.frame
        f.contents = face(of: landed)
        f.cornerRadius = 18
        f.masksToBounds = true
        // The pop settling on the land spring.
        let k = LandingCelebration.settle(peak: CardLook.Look.pop)(CGFloat(t))
        f.transform = CATransform3DMakeScale(k, k, 1)
        root.addSublayer(f)
        return try FeelProbe.render(root)
    }

    @MainActor
    private static func tilt(aim: CGPoint, picture: CGImage?) throws -> CGImage {
        let landed = card(picture, name: "IMG_4821.HEIC")
        let m: CGFloat = 80, size = CGSize(width: landed.bounds.width + 2 * m, height: landed.bounds.height + 2 * m)
        let root = backdrop(size, light: false)
        let rect = CGRect(x: m, y: m, width: landed.bounds.width, height: landed.bounds.height)
        let ambient = CALayer(), contact = CALayer()
        for layer in [ambient, contact] { layer.frame = root.bounds; root.addSublayer(layer) }
        LandingDepth.style(ambient: ambient, contact: contact)
        LandingDepth.shape(ambient: ambient, contact: contact, card: rect)
        let (c, a) = LandingDepth.offsets(aim: aim)
        contact.shadowOffset = c
        ambient.shadowOffset = a
        let f = CALayer()
        f.anchorPoint = .zero
        f.frame = rect
        f.contents = face(of: landed)
        f.cornerRadius = 18
        f.masksToBounds = true
        let sheen = LandingDepth.makeSheen(size: rect.size, radius: 18)
        LandingDepth.place(sheen: sheen, aim: aim)
        f.addSublayer(sheen)
        f.transform = LandingDepth.glassLean(aim: aim, size: rect.size)
        root.addSublayer(f)
        return try FeelProbe.render(root)
    }

    @MainActor
    private static func kinetic(at t: Double, calm: Bool, picture: CGImage?, name: String) throws -> CGImage {
        let landed = card(picture, name: name)
        guard let label = landed.titleField else { throw CocoaError(.fileWriteUnknown) }
        let m: CGFloat = 24, size = CGSize(width: landed.bounds.width + 2 * m, height: landed.bounds.height + 2 * m)
        let root = backdrop(size, light: false)
        let view = KineticTitleView.play(on: label, name: name, calm: calm, still: t)
        // The card without its label, then the letters (or the fading label) over it.
        let alpha = label.alphaValue
        label.isHidden = true
        let plain = face(of: landed)
        label.isHidden = false
        let f = CALayer()
        f.frame = CGRect(x: m, y: m, width: landed.bounds.width, height: landed.bounds.height)
        f.contents = plain
        root.addSublayer(f)
        if let letters = view?.layer {
            letters.removeFromSuperlayer()
            letters.frame = label.frame.offsetBy(dx: m, dy: m)
            root.addSublayer(letters)
        } else {
            let text = CALayer()
            text.frame = label.frame.offsetBy(dx: m, dy: m)
            label.alphaValue = 1
            text.contents = face(of: label)
            text.opacity = Float(alpha)
            root.addSublayer(text)
        }
        return try FeelProbe.render(root)
    }
}
#endif
