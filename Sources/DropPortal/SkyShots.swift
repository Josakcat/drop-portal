//
//  SkyShots.swift
//  DropPortal
//
//  The harness's look at Stardust and Lightning (debug builds): stills of a
//  1440 × 900 desktop while held and through the flight (the grains
//  mid-air, the leader, the stroke, a re-strike, the glint), on the GPU and
//  on the Core Animation fallback, in the default colour, Lime and Rainbow
//  and on a light wallpaper, plus one contact sheet per effect at half size.
//  `--metal-shots` calls in here for these two effects; `--metal-bench`
//  adds their GPU cost per frame.
//

#if DEBUG
import AppKit
import DropPortalCore
import Metal
import QuartzCore

@MainActor
public enum SkyShots {
    /// Seconds since the release worth a still, per effect.
    static func moments(_ effect: PortalEffect) -> [(name: String, t: Double)] {
        let L = effect.skyFlight
        switch effect {
        case .stardust:
            return [("t010", 0.10), ("t025", 0.25), ("t040", 0.40), ("t055", 0.55), ("t070", 0.70),
                    ("land", L + 0.004), ("glint", L + 0.05), ("settled", L + 0.2)]
        default:
            return [("leader1", 0.005), ("leader3", 0.04), ("stroke", 0.07), ("afterglow", 0.12),
                    ("restrike", 0.06 + 0.09 + 0.01), ("tail", 0.33)]
        }
    }

    /// Every shot for one effect; `metal` false renders the Core Animation fallback.
    static func writeShots(_ effect: PortalEffect, to folder: URL) throws -> [URL] {
        var urls: [URL] = []
        let photo = PortalPreview.samplePhoto
        var sheet: [(String, CGImage)] = []
        for (suffix, tint) in [("", PortalTint?.none), ("-lime", .lime), ("-rainbow", .rainbow), ("-red", .color(PortalRGB(hex: "#FF0000")!))] {
            let palette = PortalPalette(tint: tint ?? .defaultTint(for: effect), at: Date(timeIntervalSince1970: 0))
            for p: CGFloat in [0.25, 0.5, 0.85] where suffix.isEmpty || p == 0.5 {
                MetalFX.mode = .stills
                let image = try scene(effect, palette: palette, light: false, photo: photo, p: p, t: nil)
                let name = "sky-\(effect.rawValue)-p\(Int(p * 100))\(suffix)"
                urls.append(try write(image, folder, name))
                if suffix.isEmpty { sheet.append(("p\(Int(p * 100))", image)) }
            }
            for m in moments(effect) where suffix.isEmpty || ["t040", "glint", "stroke", "restrike"].contains(m.name) {
                MetalFX.mode = .stills
                let image = try scene(effect, palette: palette, light: false, photo: photo, p: 0.5, t: m.t)
                urls.append(try write(image, folder, "sky-\(effect.rawValue)-\(m.name)\(suffix)"))
                if suffix.isEmpty { sheet.append((m.name, image)) }
            }
        }
        // The Core Animation fallback, and a light wallpaper.
        for (name, t) in [("p50", nil as Double?)] + moments(effect).filter { ["t040", "stroke", "glint", "afterglow"].contains($0.name) }.map { ($0.name, Optional($0.t)) } {
            MetalFX.mode = .off
            let image = try scene(effect, palette: .of(effect), light: false, photo: photo, p: 0.5, t: t)
            urls.append(try write(image, folder, "sky-\(effect.rawValue)-\(name)-ca"))
        }
        for (name, t) in [("p60", nil as Double?), (effect == .stardust ? "t040" : "stroke", effect == .stardust ? 0.4 : 0.07)] {
            MetalFX.mode = .stills
            let image = try scene(effect, palette: .of(effect), light: true, photo: photo, p: 0.6, t: t)
            urls.append(try write(image, folder, "sky-\(effect.rawValue)-\(name)-light"))
        }
        MetalFX.mode = .off
        urls.append(try write(try contactSheet(sheet), folder, "sky-\(effect.rawValue)-sheet"))
        return urls
    }

    /// The desktop, the stage, the card and the edge light at drag `p` (held,
    /// `t` nil) or `t` seconds after a release at `p`.
    static func scene(_ effect: PortalEffect, palette: PortalPalette, light: Bool, photo: PeekInfo, p: CGFloat, t: Double?) throws -> CGImage {
        let size = CGSize(width: 1440, height: 900)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let desk = CAGradientLayer()
        desk.frame = root.bounds
        desk.colors = (light ? [NSColor(srgbRed: 0.86, green: 0.89, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.93, green: 0.9, blue: 0.86, alpha: 1)]
                             : [NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 1), NSColor(srgbRed: 0.043, green: 0.043, blue: 0.06, alpha: 1)]).map(\.cgColor)
        root.addSublayer(desk)
        let window = CALayer()
        window.frame = CGRect(x: 120, y: 200, width: 640, height: 440)
        window.backgroundColor = (light ? NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.15, alpha: 1)).cgColor
        window.cornerRadius = 12
        root.addSublayer(window)

        let thumb = PeekThumbnail.decode(photo.thumb).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        let peekView = PeekView(info: photo, image: thumb)
        let snapshot = peekView.snapshot()
        let m = CardLook.margin, card = LandingPresenter.fileCardSize
        let landing = CGPoint(x: size.width * 0.64, y: size.height / 2 + size.height * 0.04)
        let seamY = landing.y + 60
        let seam = CGPoint(x: size.width, y: seamY)
        let stage = StageView(frame: NSRect(origin: .zero, size: size), effect: effect, palette: palette, seam: seam, landing: landing)
        if let layer = stage.layer { layer.frame = root.bounds; root.addSublayer(layer) }

        let offX = size.width + 12, onX = landing.x - card.width / 2
        let heldX = offX - (offX - onX) * p
        let L = effect.skyFlight
        var x = heldX, y = seamY - card.height / 2 + (landing.y - seamY) * p * 0.5
        if let t {
            let u = CGFloat(min(1, t / L))
            x = heldX + (onX - heldX) * Ease.travel(u)
            y = y + (landing.y - card.height / 2 - y) * Ease.travel(u)
        }
        let host = CALayer()
        host.frame = CGRect(x: x - m, y: y - m, width: card.width + 2 * m, height: card.height + 2 * m)
        let cardLayer = CALayer()
        cardLayer.frame = CGRect(x: m, y: m, width: card.width, height: card.height)
        cardLayer.contents = snapshot
        cardLayer.cornerRadius = 18
        host.addSublayer(cardLayer)
        root.addSublayer(host)
        let look = CardLook(effect: effect, palette: palette, calm: false, host: host, card: cardLayer, cardFrame: cardLayer.frame)
        look.setSnapshot(snapshot)
        look.clip(toMaxX: size.width - host.frame.minX)
        stage.paintNow()
        stage.setIntensity(p)
        stage.follow(card: CGPoint(x: host.frame.midX, y: host.frame.midY))
        look.update(progress: p, velocity: -700, leaving: false)
        if let t {
            look.commit(still: t)
            stage.send(still: t)
            if t >= L {
                look.land(still: t - L)
                stage.impact(still: t - L)
            }
        } else {
            let seamSize = SeamView.size(screenHeight: size.height)
            let seamView = SeamView(frame: NSRect(x: size.width - seamSize.width, y: 0, width: seamSize.width, height: seamSize.height),
                                    effect: effect, palette: palette, calm: false, centerY: seam.y)
            seamView.setIntensity(p)
            if let l = seamView.layer { l.frame = seamView.frame; root.addSublayer(l) }
        }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        root.render(in: ctx)
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    private static func write(_ image: CGImage, _ folder: URL, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name + ".png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }

    /// Every still of the run at half size, four across, each labelled.
    private static func contactSheet(_ shots: [(String, CGImage)]) throws -> CGImage {
        let w = 720, h = 450, cols = 4, rows = (shots.count + cols - 1) / cols, gap = 6
        guard let ctx = CGContext(data: nil, width: cols * (w + gap), height: rows * (h + gap), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(gray: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.interpolationQuality = .high
        for (i, (name, image)) in shots.enumerated() {
            let x = (i % cols) * (w + gap), y = (rows - 1 - i / cols) * (h + gap)
            ctx.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
            let label = NSAttributedString(string: name, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
                                                                      .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(label)
            ctx.textPosition = CGPoint(x: x + 12, y: y + h - 28)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    // MARK: Bench

    /// GPU time a frame of each sky effect across a whole crossing, on a few screen sizes.
    static func bench() -> [String] {
        MetalFX.mode = .stills
        guard SkyEngine.forCrossing() != nil else { return ["sky: unavailable"] }
        var lines: [String] = []
        let snapshot = PeekView(info: PortalPreview.samplePhoto, image: nil).snapshot()
        for screen in [CGSize(width: 1440, height: 900), CGSize(width: 1728, height: 1117), CGSize(width: 2560, height: 1440)] {
            let k = StageView.scale(for: screen)
            let landing = CGPoint(x: screen.width * 0.64, y: screen.height * 0.54)
            let seam = CGPoint(x: screen.width, y: landing.y)
            for effect in [PortalEffect.stardust, .lightning] {
                guard let stage = SkyStage(frame: CGRect(origin: .zero, size: screen), effect: effect, palette: .of(effect),
                                           seam: seam, landing: landing, k: k, scale: 2) else { continue }
                let host = CALayer()
                let m = CardLook.margin, size = LandingPresenter.fileCardSize
                host.frame = CGRect(x: 0, y: 0, width: size.width + 2 * m, height: size.height + 2 * m)
                let card = SkyCard(effect: effect, host: host, cardFrame: CGRect(x: m, y: m, width: size.width, height: size.height), radius: 18)
                card?.setSnapshot(snapshot)
                stage.setIntensity(0.01)
                _ = SkyStats.shared.take()
                for i in 0..<30 { autoreleasepool { stage.setIntensity(CGFloat(i) / 29) } }
                let held = SkyStats.shared.take()
                let L = effect.skyFlight, end = effect == .stardust ? L + 0.1 : LightningStrike.end
                var worstAt = 0.0, worst = 0.0
                var all: [Double] = []
                for t in stride(from: 0.0, to: end, by: 1.0 / 120) {
                    autoreleasepool {
                        stage.send(still: t, flight: L)
                        let s = SkyStats.shared.take()
                        all.append(s.mean)
                        if s.worst > worst { worst = s.worst; worstAt = t }
                    }
                }
                for t in stride(from: 0.0, to: 0.2, by: 1.0 / 120) {
                    autoreleasepool {
                        card?.commit(card: CALayer(), still: t, flight: L)
                        if t >= L { card?.land(still: t - L) }
                    }
                }
                let c = SkyStats.shared.take()
                let mean = all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
                let grains = effect == .stardust ? " (\(SkyStage.grid.columns * SkyStage.grid.rows) grains + \(SkyStage.fillerCount) filler)" : ""
                lines.append(String(format: "sky %d×%d %@%@ (GPU ms): held %.2f/%.2f, crossing mean %.2f worst %.2f at t %.3f s; card %.2f/%.2f",
                                    Int(screen.width), Int(screen.height), effect.rawValue, grains, held.mean, held.worst, mean, worst, worstAt, c.mean, c.worst))
                stage.stop()
                card?.stop()
            }
        }
        MetalFX.mode = .off
        return lines
    }
}
#endif
