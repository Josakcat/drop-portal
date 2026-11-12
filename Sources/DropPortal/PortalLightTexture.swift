import AppKit
import DropPortalCore

/// One painted light. Most colours are a finished bitmap; Rainbow is two
/// alpha-only masks instead, the light's coverage (filled by a wheel of hues
/// that sweeps across it) and its white core, so the hue can move without a
/// second bitmap.
final class LightBitmap: @unchecked Sendable {
    let image: CGImage
    /// Rainbow only: the white core and the paper, alpha only.
    let core: CGImage?
    var sweeps: Bool { core != nil }
    init(image: CGImage, core: CGImage? = nil) {
        self.image = image
        self.core = core
    }
}

/// The impact's light, painted once per effect, colour and screen, off the
/// main thread, and cached. Only this bitmap's transform and opacity change
/// during playback (Rainbow: and the position of the hues it is filled with).
///
/// The light is three layers, each a greyscale mask filled with colour: a wide
/// soft halo in the effect's two tones (a gradient across the effect), a
/// saturated band on every line, added on top (plus-lighter, so overlaps run
/// hot), and a white core added last. The bitmap is premultiplied, so it reads
/// as additive light on any wallpaper.
///
/// `layout` sizes the bitmap to the light's full reach plus its halo, and
/// shrinks the drawing until it fits the screen above, below and to the left,
/// so nothing is cut but the right edge, where the light comes in.
@MainActor
enum PortalLightTexture {
    /// Where the bitmap goes on the screen and how the drawing is scaled.
    struct Layout: Hashable {
        /// In the screen's (the stage's) coordinates.
        var frame: CGRect
        /// The landing spot inside `frame`.
        var landing: CGPoint
        /// Spec units to points.
        var unit: CGFloat
        /// From the landing spot to the screen's right edge, in spec units.
        var gap: CGFloat
    }

    private static var cache: [String: LightBitmap] = [:]
    private static var order: [String] = []
    /// Each bitmap is a few MB; a handful covers the effects and colours a session switches between.
    private static let cacheLimit = 6

    private static let painter = DispatchQueue(label: "app.dropportal.light-paint", qos: .userInitiated)
    private static var pending: [String: [(LightBitmap?) -> Void]] = [:]
    private static var tickets: [String: PaintTicket] = [:]

    private final class PaintTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
    }

    /// Spec units of room kept round the drawing for the halo.
    nonisolated static let haloPad: CGFloat = 96

    /// The bitmap's frame for a landing spot on a screen. Cheap: it builds the paths, it paints nothing.
    nonisolated static func layout(effect: PortalEffect, screen: CGSize, landing: CGPoint, k: CGFloat) -> Layout {
        var unit = k
        var box = CGRect.zero
        for _ in 0..<3 {
            let gap = (screen.width - landing.x) / unit
            box = bounds(of: shapes(effect, gap: gap)).insetBy(dx: -haloPad, dy: -haloPad)
            // Room above, below and to the left of the landing spot, 2 pt short of the screen's edges.
            var fit = unit
            if box.maxY > 0 { fit = min(fit, (screen.height - landing.y - 2) / box.maxY) }
            if box.minY < 0 { fit = min(fit, (landing.y - 2) / -box.minY) }
            if box.minX < 0 { fit = min(fit, (landing.x - 2) / -box.minX) }
            if abs(fit - unit) < 0.002 { break }
            unit = max(0.3, fit)
        }
        let gap = (screen.width - landing.x) / unit
        box = bounds(of: shapes(effect, gap: gap)).insetBy(dx: -haloPad, dy: -haloPad)
        var frame = CGRect(x: landing.x + box.minX * unit, y: landing.y + box.minY * unit,
                           width: box.width * unit, height: box.height * unit)
        frame = frame.intersection(CGRect(origin: .zero, size: screen)).integral
        return Layout(frame: frame, landing: CGPoint(x: landing.x - frame.minX, y: landing.y - frame.minY), unit: unit, gap: gap)
    }

    nonisolated private static func key(_ effect: PortalEffect, _ palette: PortalPalette, _ layout: Layout, _ scale: CGFloat) -> String {
        "\(effect.rawValue)-\(palette.key)-\(layout.frame)-\(layout.unit)-\(scale)"
    }

    private static func store(_ key: String, _ image: LightBitmap?) {
        guard let image else { return }
        cache[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > cacheLimit { cache.removeValue(forKey: order.removeFirst()) }
    }

    /// Live callers never paint on the main thread, even on a cold cache.
    static func prepare(effect: PortalEffect, palette: PortalPalette, layout: Layout, scale: CGFloat,
                        completion: @escaping (LightBitmap?) -> Void = { _ in }) {
        let key = key(effect, palette, layout, scale)
        if let image = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            completion(image); return
        }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        let ticket = PaintTicket(); tickets[key] = ticket
        painter.async {
            let image = paint(effect: effect, palette: palette, layout: layout, scale: scale, cancelled: { ticket.cancelled })
            DispatchQueue.main.async {
                guard !ticket.cancelled else { return }
                store(key, image)
                let callbacks = pending.removeValue(forKey: key) ?? []
                tickets.removeValue(forKey: key)
                callbacks.forEach { $0(image) }
            }
        }
    }

    static func clear() {
        tickets.values.forEach { $0.cancel() }
        tickets.removeAll(); pending.removeAll(); cache.removeAll(); order.removeAll()
    }

    /// Synchronous only for the offscreen capture tools.
    static func image(effect: PortalEffect, palette: PortalPalette, layout: Layout, scale: CGFloat) -> LightBitmap? {
        let key = key(effect, palette, layout, scale)
        if let image = cache[key] { return image }
        let image = paint(effect: effect, palette: palette, layout: layout, scale: scale)
        store(key, image)
        return image
    }

    // MARK: Geometry

    /// One piece of the drawing, in spec units with the landing spot at the
    /// origin, x toward the right edge, y up.
    enum Shape {
        /// A line of light; `gain` 0...1 is how bright.
        case line(CGPath, width: CGFloat, gain: CGFloat)
        /// A filled shape of light (Liquid's drops).
        case blob(CGPath, gain: CGFloat)
        /// Paper (the plane): `shade` 0 lit, 1 in shadow. Edged with light.
        case paper(CGPath, shade: CGFloat)
        /// A wide soft glow, an ellipse fading to nothing at its edge.
        case bloom(CGRect, strength: CGFloat)

        var path: CGPath {
            switch self {
            case .line(let p, _, _), .blob(let p, _), .paper(let p, _): p
            case .bloom(let r, _): CGPath(ellipseIn: r, transform: nil)
            }
        }
        var reach: CGFloat {
            if case .line(_, let width, _) = self { return width / 2 }
            return 0
        }
    }

    nonisolated private static func bounds(of shapes: [Shape]) -> CGRect {
        shapes.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath.insetBy(dx: -$1.reach, dy: -$1.reach)) }
    }

    nonisolated static func shapes(_ effect: PortalEffect, gap: CGFloat) -> [Shape] {
        var out: [Shape] = []
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ t: CGAffineTransform = .identity) -> CGPath {
            var t = t
            return CGPath(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: &t)
        }
        func curve(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
            let p = CGMutablePath(); p.move(to: a); p.addQuadCurve(to: b, control: c); return p
        }
        func poly(_ points: [CGPoint]) -> CGPath {
            let p = CGMutablePath(); p.addLines(between: points); p.closeSubpath(); return p
        }
        func bloom(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ strength: CGFloat) {
            out.append(.bloom(CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), strength: strength))
        }
        switch effect {
        case .portal:
            bloom(-40, 0, gap + 60, 250, 0.42)
            bloom(gap, 0, 150, 400, 0.9)
            // A wide lens of light round the card, the rift on the edge, and rays into the card.
            out.append(.line(ellipse(-100, 0, gap + 95, 220), width: 3, gain: 1))
            out.append(.line(ellipse(-60, 0, gap + 40, 150), width: 1.4, gain: 0.45))
            out.append(.line(curve(CGPoint(x: gap - 3, y: -330), CGPoint(x: gap - 3, y: 330), CGPoint(x: gap - 26, y: 0)), width: 7, gain: 1))
            for i in 0..<7 {
                let y = CGFloat(i - 3) * 48
                out.append(.line(curve(CGPoint(x: 105, y: y), CGPoint(x: gap, y: 0), CGPoint(x: gap * 0.65, y: y * 0.65)), width: 1.4, gain: 0.55))
            }
            for i in 0..<24 {
                let x = 150 + CGFloat((i * 73) % 390) * max(0.4, (gap - 145) / 390)
                let y = CGFloat((i * 47) % 185) - 92
                out.append(.blob(poly([CGPoint(x: x - 5, y: y), CGPoint(x: x + 2, y: y + 2.4), CGPoint(x: x + 8, y: y), CGPoint(x: x + 2, y: y - 2.4)]), gain: 0.9))
            }
        case .liquid:
            bloom(-30, 0, 470, 220, 0.4)
            bloom(gap, 0, 170, 360, 0.75)
            // A scalloped splash crown, the stream from the edge, and drops thrown out.
            let crown = CGMutablePath()
            for i in 0...160 {
                let a = CGFloat(i) / 160 * 2 * .pi
                let r = 1 + 0.035 * sin(a * 11) + 0.025 * sin(a * 17)
                let v = CGPoint(x: -30 + cos(a) * 410 * r, y: sin(a) * 155 * r)
                if i == 0 { crown.move(to: v) } else { crown.addLine(to: v) }
            }
            out.append(.line(crown, width: 3.2, gain: 1))
            for side: CGFloat in [-1, 1] {
                out.append(.line(curve(CGPoint(x: 40, y: side * 150), CGPoint(x: gap + 10, y: side * 330), CGPoint(x: gap - 45, y: side * 95)), width: 4.5, gain: 1))
                for i in 0..<4 {
                    out.append(.line(curve(CGPoint(x: 110, y: side * (40 + CGFloat(i) * 25)), CGPoint(x: gap, y: side * (30 + CGFloat(i) * 55)), CGPoint(x: gap * 0.7, y: side * 30)), width: 1.8, gain: 0.7))
                }
            }
            for i in 0..<14 {
                let a = CGFloat(i) / 14 * 2 * .pi + 0.1
                let drop = CGMutablePath()
                drop.move(to: CGPoint(x: -28, y: 0))
                drop.addCurve(to: CGPoint(x: 14, y: 7), control1: CGPoint(x: -3, y: 1), control2: CGPoint(x: 0, y: 16))
                drop.addCurve(to: CGPoint(x: 14, y: -7), control1: CGPoint(x: 32, y: 8), control2: CGPoint(x: 32, y: -8))
                drop.addCurve(to: CGPoint(x: -28, y: 0), control1: CGPoint(x: 0, y: -16), control2: CGPoint(x: -3, y: -1))
                var t = CGAffineTransform(translationX: -30 + cos(a) * 470, y: sin(a) * 215).rotated(by: a)
                out.append(.blob(drop.copy(using: &t)!, gain: 0.85))
            }
        case .wormhole:
            bloom(gap + 40, 0, 330, 420, 0.7)
            bloom(0, 0, 280, 220, 0.4)
            // Three tilted rims opening from the edge, a ring round the card, and streams into it.
            for i in 0..<3 {
                let rx = CGFloat(380 - i * 100), ry = CGFloat(410 - i * 95)
                let t = CGAffineTransform(translationX: gap + 55, y: 0).rotated(by: -.pi / 7)
                out.append(.line(ellipse(0, 0, rx, ry, t), width: CGFloat(7 - i), gain: 1))
                // The near lip as a thick crescent.
                let arc = CGMutablePath()
                arc.addArc(center: .zero, radius: rx, startAngle: .pi * 0.55, endAngle: .pi * 1.45, clockwise: false,
                           transform: CGAffineTransform(scaleX: 1, y: ry / rx).concatenating(t))
                out.append(.line(arc, width: CGFloat(10 - i * 2), gain: 1))
            }
            out.append(.line(ellipse(0, 0, 245, 170, CGAffineTransform(rotationAngle: .pi / 5)), width: 1.6, gain: 0.85))
            for y: CGFloat in [-80, 0, 80] {
                out.append(.line(curve(CGPoint(x: 110, y: y), CGPoint(x: gap, y: y * 0.6), CGPoint(x: gap * 0.6, y: y - 30)), width: 2, gain: 0.9))
            }
        case .beam:
            bloom(0, 0, 380, 270, 0.5)
            bloom(gap, 0, 110, 300, 0.7)
            out.append(.line(ellipse(0, 0, 350, 245), width: 1.2, gain: 0.35))
            for i in 0..<9 {
                let y = CGFloat(i - 4) * 29.8
                out.append(.line(curve(CGPoint(x: -120, y: y), CGPoint(x: gap, y: y), CGPoint(x: 240, y: y)), width: 2, gain: 1))
            }
            out.append(.line(curve(CGPoint(x: 0, y: -205), CGPoint(x: 0, y: 205), .zero), width: 4, gain: 1))
        case .plane:
            bloom(0, -150, 420, 110, 0.6)
            bloom(60, 0, 380, 280, 0.35)
            out.append(.line(ellipse(0, -158, 380, 57), width: 2.2, gain: 0.9))
            for side: CGFloat in [-1, 1] {
                out.append(.line(curve(CGPoint(x: 20, y: side * 195), CGPoint(x: gap, y: side * 28), CGPoint(x: gap * 0.48, y: side * 38)), width: 2.8, gain: 1))
                out.append(.paper(poly([CGPoint(x: -240, y: side * 245), CGPoint(x: 50, y: side * 195), CGPoint(x: 235, y: 0)]), shade: 0))
                out.append(.paper(poly([CGPoint(x: -240, y: side * 245), CGPoint(x: 90, y: side * 140), CGPoint(x: 235, y: 0)]), shade: 0.5))
                out.append(.paper(poly([CGPoint(x: 145, y: 0), CGPoint(x: 235, y: 0), CGPoint(x: 345, y: side * 5), CGPoint(x: 185, y: side * 30)]), shade: 0.5))
            }
        }
        // The card's own light is the stage's halo and rim (they follow its pop); none here.
        return out
    }

    // MARK: Painting

    /// A greyscale mask, the bitmap's size times `factor`.
    nonisolated private static func mask(_ pixels: CGSize, _ factor: CGFloat) -> CGContext? {
        CGContext(data: nil, width: max(1, Int(pixels.width * factor)), height: max(1, Int(pixels.height * factor)),
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    nonisolated private static func paint(effect: PortalEffect, palette: PortalPalette, layout: Layout, scale: CGFloat,
                                           cancelled: () -> Bool = { false }) -> LightBitmap? {
        guard !cancelled() else { return nil }
        let pixels = CGSize(width: layout.frame.width * scale, height: layout.frame.height * scale)
        guard let c = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let shapes = shapes(effect, gap: layout.gap)
        let u = layout.unit
        // Points to mask pixels: the halo at a quarter of the bitmap's pixels (it is all blur), the band and core at full.
        let haloFactor: CGFloat = 0.25
        guard let halo = mask(pixels, haloFactor), let band = mask(pixels, 1), let core = mask(pixels, 1) else { return nil }
        for (ctx, f) in [(halo, haloFactor), (band, 1), (core, 1)] as [(CGContext, CGFloat)] {
            ctx.scaleBy(x: scale * f, y: scale * f)
            ctx.translateBy(x: layout.landing.x, y: layout.landing.y)
            ctx.scaleBy(x: u, y: u)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
        }
        let haloPx = scale * haloFactor * u
        func gray(_ ctx: CGContext, _ v: CGFloat) -> CGColor { CGColor(gray: min(1, v), alpha: 1) }

        for shape in shapes {
            guard !cancelled() else { return nil }
            switch shape {
            case .line(let path, let width, let gain):
                // Halo: a wide haze, as strong as the hero mockups', and a tighter bloom, painted as shadows (baked in).
                for (extra, blur, level) in [(30.0, 84.0, 0.72), (7.0, 16.0, 1.0)] as [(CGFloat, CGFloat, CGFloat)] {
                    halo.saveGState()
                    halo.setShadow(offset: .zero, blur: blur * haloPx, color: gray(halo, gain * level))
                    halo.setStrokeColor(gray(halo, gain * level * 0.5))
                    halo.setLineWidth(width + extra); halo.addPath(path); halo.strokePath()
                    halo.restoreGState()
                }
                band.setShadow(offset: .zero, blur: 3 * scale * u, color: gray(band, gain))
                band.setStrokeColor(gray(band, gain)); band.setLineWidth(width + 3.5); band.addPath(path); band.strokePath()
                core.setStrokeColor(gray(core, gain)); core.setLineWidth(max(1, width * 0.55)); core.addPath(path); core.strokePath()
            case .blob(let path, let gain):
                halo.saveGState()
                halo.setShadow(offset: .zero, blur: 18 * haloPx, color: gray(halo, gain))
                halo.setFillColor(gray(halo, gain * 0.6)); halo.addPath(path); halo.fillPath()
                halo.restoreGState()
                band.setFillColor(gray(band, gain)); band.addPath(path); band.fillPath()
                core.setStrokeColor(gray(core, gain * 0.9)); core.setLineWidth(1.1); core.addPath(path); core.strokePath()
            case .bloom:
                continue
            case .paper(let path, _):
                halo.saveGState()
                halo.setShadow(offset: .zero, blur: 30 * haloPx, color: gray(halo, 0.9))
                halo.setFillColor(gray(halo, 0.4)); halo.addPath(path); halo.fillPath()
                halo.restoreGState()
                band.setStrokeColor(gray(band, 0.8)); band.setLineWidth(3); band.addPath(path); band.strokePath()
            }
        }
        guard !cancelled(), let haloMask = halo.makeImage(), let bandMask = band.makeImage(), let coreMask = core.makeImage() else { return nil }

        let full = CGRect(origin: .zero, size: pixels)
        if palette.rainbow {
            return rainbowMasks(shapes: shapes, layout: layout, scale: scale, pixels: pixels,
                                halo: haloMask, band: bandMask, core: coreMask)
        }
        // Two tones across the effect: the second tone where the light lands, the glow at the edge it comes from.
        let stops = palette.gradientStops
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func fill(_ maskImage: CGImage, _ colors: [CGColor], alpha: CGFloat, blend: CGBlendMode) {
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) else { return }
            c.saveGState()
            c.setBlendMode(blend)
            c.setAlpha(alpha)
            c.clip(to: full, mask: maskImage)
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: full.midY), end: CGPoint(x: full.maxX, y: full.midY),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
        }
        // Blooms: a hot middle, the colour, then nothing at the rim.
        c.saveGState()
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: layout.landing.x, y: layout.landing.y)
        c.scaleBy(x: u, y: u)
        for shape in shapes {
            guard case .bloom(let rect, let strength) = shape else { continue }
            let mid = rect.midX
            // The tone the gradient has at the bloom's middle (Rainbow: that hue of the wheel).
            let across = min(1, max(0, (layout.landing.x + mid * u) / layout.frame.width))
            let tone = palette.rainbow ? NSColor(hue: across * 0.92, saturation: 1, brightness: 1, alpha: 1)
                : across > 0.55 ? palette.glow : palette.accent
            let core = palette.rainbow ? NSColor.white : palette.core
            let colors = [core.withAlphaComponent(0.55 * strength), tone.withAlphaComponent(0.5 * strength),
                          tone.withAlphaComponent(0.18 * strength), tone.withAlphaComponent(0)].map(\.cgColor)
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.22, 0.6, 1]) else { continue }
            c.saveGState()
            c.translateBy(x: mid, y: rect.midY)
            c.scaleBy(x: rect.width / 2, y: rect.height / 2)
            c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            c.restoreGState()
        }
        c.restoreGState()
        fill(haloMask, palette.gradient(saturated: true), alpha: 0.95, blend: .plusLighter)
        // Paper sits between the halo and the light on its edges.
        c.saveGState()
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: layout.landing.x, y: layout.landing.y)
        c.scaleBy(x: u, y: u)
        for shape in shapes {
            guard case .paper(let path, let shade) = shape else { continue }
            let lit = NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1).blended(withFraction: 0.08, of: palette.glow) ?? .white
            let dark = NSColor(srgbRed: 0.6, green: 0.61, blue: 0.64, alpha: 1).blended(withFraction: 0.38, of: palette.glow) ?? .gray
            c.setFillColor((lit.blended(withFraction: shade, of: dark) ?? lit).cgColor)
            c.addPath(path); c.fillPath()
        }
        c.restoreGState()
        fill(bandMask, palette.gradient(saturated: false), alpha: 1, blend: .plusLighter)
        c.saveGState()
        c.setBlendMode(.plusLighter)
        c.clip(to: full, mask: coreMask)
        c.setFillColor(NSColor.white.cgColor)
        c.fill(full)
        c.restoreGState()
        guard !cancelled(), let image = c.makeImage() else { return nil }
        return LightBitmap(image: image)
    }

    /// Rainbow: the light's coverage (blooms, halo and bands, added) and its
    /// white core with the paper, as two alpha-only masks the stage fills
    /// with a moving wheel of hues and with white.
    nonisolated private static func rainbowMasks(shapes: [Shape], layout: Layout, scale: CGFloat, pixels: CGSize,
                                                 halo: CGImage, band: CGImage, core: CGImage) -> LightBitmap? {
        let full = CGRect(origin: .zero, size: pixels)
        func alphaContext() -> CGContext? {
            CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        }
        func inSpecUnits(_ c: CGContext) {
            c.scaleBy(x: scale, y: scale)
            c.translateBy(x: layout.landing.x, y: layout.landing.y)
            c.scaleBy(x: layout.unit, y: layout.unit)
        }
        func cover(_ c: CGContext, _ mask: CGImage, _ alpha: CGFloat, _ blend: CGBlendMode = .plusLighter) {
            c.saveGState()
            c.setBlendMode(blend)
            c.clip(to: full, mask: mask)
            c.setFillColor(CGColor(gray: 1, alpha: alpha))
            c.fill(full)
            c.restoreGState()
        }
        guard let colour = alphaContext(), let white = alphaContext() else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        colour.saveGState()
        inSpecUnits(colour)
        for shape in shapes {
            guard case .bloom(let rect, let strength) = shape else { continue }
            let colors = [0.8, 0.5, 0.18, 0].map { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: $0 * strength) }
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.22, 0.6, 1]) else { continue }
            colour.saveGState()
            colour.translateBy(x: rect.midX, y: rect.midY)
            colour.scaleBy(x: rect.width / 2, y: rect.height / 2)
            colour.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            colour.restoreGState()
        }
        colour.restoreGState()
        cover(colour, halo, 0.95)
        cover(colour, band, 1)
        // Paper is white, lit or in shade, under the core's light.
        white.saveGState()
        inSpecUnits(white)
        for shape in shapes {
            guard case .paper(let path, let shade) = shape else { continue }
            white.setBlendMode(.copy)
            white.setFillColor(CGColor(gray: 1, alpha: 0.95 - 0.4 * shade))
            white.addPath(path); white.fillPath()
        }
        white.restoreGState()
        cover(white, core, 1)
        guard let coverage = colour.makeImage(), let coreImage = white.makeImage() else { return nil }
        return LightBitmap(image: coverage, core: coreImage)
    }
}
