//
//  MetalProbe.swift
//  DropPortal
//
//  The harness's look at the GPU effects (debug builds only):
//  `--metal-shots <dir>` renders every effect at several p and at the
//  impact, in a few colours with Rainbow, through the GPU, and the Core
//  Animation path beside it at half size (`compare-*.png`).
//  `--metal-bench` prints the shaders' compile time, the GPU time per frame
//  on a few screen sizes, the memory the engine costs, and what each
//  effect's Core Animation tree costs per frame (main thread and render).
//

#if DEBUG
import AppKit
import DropPortalCore
import Metal
import QuartzCore

public enum MetalProbe {
    private struct State { let name: String; let impact: Bool; let at: Double?; let p: CGFloat }
    private static let states = [State(name: "p25", impact: false, at: nil, p: 0.25), State(name: "p50", impact: false, at: nil, p: 0.5),
                                 State(name: "p85", impact: false, at: nil, p: 0.85), State(name: "impact", impact: true, at: nil, p: 0.45),
                                 State(name: "impact-mid", impact: true, at: 0.2, p: 0.45)]

    @MainActor
    public static func writeShots(to folder: URL, only: String? = nil) throws -> [URL] {
        let effects = PortalEffect.allCases.filter { only == nil || $0.rawValue == only }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = PortalPreview.samplePhoto
        var urls: [URL] = []
        let tints: [(String, PortalTint?)] = [("", nil), ("-lime", .lime), ("-rainbow", .rainbow)]
        for effect in effects {
            for (suffix, tint) in tints {
                let palette = PortalPalette(tint: tint ?? .defaultTint(for: effect), at: Date(timeIntervalSince1970: 0))
                for state in states {
                    MetalFX.mode = .stills
                    let gpu = try PortalPreview.effectImage(effect, palette: palette, light: false, photo: photo,
                                                            impact: state.impact, impactAt: state.at, progress: state.p)
                    let name = "effect-\(effect.rawValue)-\(state.name)\(suffix)"
                    urls.append(try write(gpu, to: folder.appendingPathComponent("gpu-\(name).png")))
                    guard suffix.isEmpty || state.name == "p50" || state.name == "impact" else { continue }
                    MetalFX.mode = .off
                    let ca = try PortalPreview.effectImage(effect, palette: palette, light: false, photo: photo,
                                                           impact: state.impact, impactAt: state.at, progress: state.p)
                    urls.append(try write(sideBySide(ca, gpu), to: folder.appendingPathComponent("compare-\(name).png")))
                }
            }
            // On a light wallpaper too.
            MetalFX.mode = .stills
            let light = try PortalPreview.effectImage(effect, palette: .of(effect), light: true, photo: photo, impact: false, progress: 0.6)
            urls.append(try write(light, to: folder.appendingPathComponent("gpu-effect-\(effect.rawValue)-p60-light.png")))
            // Stardust and Lightning: through the flight too (SkyShots.swift).
            if effect.isSky { urls += try SkyShots.writeShots(effect, to: folder) }
        }
        // The landing celebration's sparks on the GPU (LandingCelebration.swift).
        MetalFX.mode = .stills
        urls += try LandingTouchesProbe.writeShots(to: folder, gpu: true)
        MetalFX.mode = .off
        return urls
    }

    private static func write(_ image: CGImage, to url: URL) throws -> URL {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }

    /// Before (Core Animation) left, after (GPU) right, each at half size.
    private static func sideBySide(_ a: CGImage, _ b: CGImage) throws -> CGImage {
        let w = a.width / 2, h = a.height / 2, gap = 8
        guard let ctx = CGContext(data: nil, width: w * 2 + gap, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w * 2 + gap, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(b, in: CGRect(x: w + gap, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    // MARK: Bench

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func ms(_ v: Double) -> String { String(format: "%.2f", v) }

    @MainActor
    public static func bench(caOnly: Bool = false) -> [String] {
        var lines: [String] = []
        if !caOnly { lines += gpuBench() + SkyShots.bench() }
        lines += caBench()
        lines += LandingTouchesProbe.bench(gpu: !caOnly)
        return lines
    }

    /// GPU time per frame of the stage (light + particles) and the card, across a whole crossing.
    @MainActor
    private static func gpuBench() -> [String] {
        var lines: [String] = []
        let before = footprintMB()
        let start = CFAbsoluteTimeGetCurrent()
        MetalFX.mode = .stills
        guard let engine = MetalFX.forCrossing() else { return ["metal: unavailable"] }
        lines.append("metal: \(engine.device.name), engine made (shaders compiled) in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms, footprint +\(ms(footprintMB() - before)) MB")
        _ = engine.takeStats()
        let snapshot = PeekView(info: PortalPreview.samplePhoto, image: nil).snapshot()
        for screen in [CGSize(width: 1440, height: 900), CGSize(width: 1728, height: 1117), CGSize(width: 2560, height: 1440)] {
            let k = StageView.scale(for: screen)
            let landing = CGPoint(x: screen.width * 0.64, y: screen.height * 0.54)
            let seam = CGPoint(x: screen.width, y: landing.y)
            for effect in PortalEffect.allCases {
                let palette = PortalPalette.of(effect)
                guard let stage = GPUStage(frame: CGRect(origin: .zero, size: screen), effect: effect, palette: palette,
                                           seam: seam, landing: landing, k: k, scale: 2) else { continue }
                // 30 held frames, the flight and the impact at 120 Hz; the first frame warms the pipelines.
                stage.setIntensity(0.01)
                _ = engine.takeStats()
                for i in 0..<30 {
                    let p = CGFloat(i) / 29
                    autoreleasepool {
                        stage.setIntensity(p)
                        stage.follow(card: CGPoint(x: seam.x - (seam.x - landing.x) * p, y: landing.y))
                    }
                }
                let held = engine.takeStats()
                let L = effect.flight
                for i in stride(from: 0.0, to: L, by: 1.0 / 120) { autoreleasepool { stage.send(still: i) } }
                let flight = engine.takeStats()
                for i in stride(from: L, through: L + 0.6, by: 1.0 / 120) {
                    autoreleasepool {
                        stage.send(still: i)
                        stage.impact(still: i - L)
                    }
                }
                let impact = engine.takeStats()
                let host = CALayer()
                let m = CardLook.margin, size = LandingPresenter.fileCardSize
                host.frame = CGRect(x: 0, y: 0, width: size.width + 2 * m, height: size.height + 2 * m)
                let cardFrame = CGRect(x: m, y: m, width: size.width, height: size.height)
                var c = (0, 0.0, 0.0)
                if let card = GPUCard(effect: effect, palette: palette, host: host, cardFrame: cardFrame, radius: 18) {
                    card.setSnapshot(snapshot)
                    card.update(progress: 0)
                    _ = engine.takeStats()
                    for i in 0..<30 { autoreleasepool { card.update(progress: CGFloat(i) / 29) } }
                    for i in stride(from: 0.0, through: L + 0.4, by: 1.0 / 120) {
                        autoreleasepool {
                            card.commit(still: i)
                            if i >= L { card.land(still: i - L) }
                        }
                    }
                    c = engine.takeStats()
                }
                func f(_ s: (frames: Int, mean: Double, worst: Double)) -> String { "\(ms(s.mean))/\(ms(s.worst))" }
                lines.append("gpu \(Int(screen.width))×\(Int(screen.height)) \(effect.rawValue) (mean/worst ms): stage held \(f(held)), flight \(f(flight)), impact \(f(impact)); card \(ms(c.1))/\(ms(c.2))")
            }
        }
        lines.append("footprint after the GPU bench: +\(ms(footprintMB() - before)) MB over the start")
        MetalFX.shutdown()
        return lines
    }

    /// Each effect's Core Animation tree: main-thread work per drag frame
    /// (the hooks the presenter calls, plus the commit) and the render cost
    /// of the whole screen at 2x (CARenderer on the GPU, an estimate of the
    /// render server's share).
    @MainActor
    private static func caBench() -> [String] {
        var lines: [String] = []
        MetalFX.mode = .off
        let screen = CGSize(width: 1728, height: 1117)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return ["ca: no Metal device"] }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(screen.width * 2), height: Int(screen.height * 2), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d) else { return ["ca: no texture"] }
        for effect in PortalEffect.allCases { lines.append(mainThread(effect, screen: screen)) }
        for effect in PortalEffect.allCases {
            for p in [0.5, 0.85] as [CGFloat] {
                let root = PortalPreview.effectScene(effect, palette: .of(effect), light: false, photo: PortalPreview.samplePhoto,
                                                     impact: false, progress: p, size: screen)
                lines.append("ca \(effect.rawValue) p\(Int(p * 100)): render \(ms(render(root, target: target, queue: queue))) ms" + breakdown(root, target: target, queue: queue))
            }
        }
        return lines
    }

    /// Main-thread work of one drag frame on the Core Animation path: the
    /// stage's and the card's hooks the presenter calls, then the commit.
    @MainActor
    private static func mainThread(_ effect: PortalEffect, screen: CGSize) -> String {
        let landing = CGPoint(x: screen.width * 0.64, y: screen.height * 0.54)
        let seam = CGPoint(x: screen.width, y: landing.y)
        let stage = StageView(frame: NSRect(origin: .zero, size: screen), effect: effect, palette: .of(effect), seam: seam, landing: landing)
        stage.paintNow()
        let m = CardLook.margin, card = LandingPresenter.fileCardSize
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: card.width + 2 * m, height: card.height + 2 * m)
        let cardLayer = CALayer()
        cardLayer.frame = CGRect(x: m, y: m, width: card.width, height: card.height)
        host.addSublayer(cardLayer)
        stage.layer?.addSublayer(host)
        let look = CardLook(effect: effect, palette: .of(effect), calm: false, host: host, card: cardLayer, cardFrame: cardLayer.frame)
        look.setSnapshot(PeekView(info: PortalPreview.samplePhoto, image: nil).snapshot())
        var times: [Double] = []
        for i in 0..<240 {
            let p = CGFloat(i % 120) / 119
            let t0 = CACurrentMediaTime()
            let x = seam.x - (seam.x - landing.x) * p
            host.position = CGPoint(x: x, y: landing.y)
            stage.setIntensity(p)
            stage.follow(card: CGPoint(x: x, y: landing.y))
            look.update(progress: p, velocity: -700, leaving: false)
            look.clip(toMaxX: seam.x - (x - host.bounds.width / 2))
            CATransaction.flush()
            times.append((CACurrentMediaTime() - t0) * 1000)
        }
        look.stop()
        stage.stop()
        let sorted = times.sorted()
        return "main thread \(effect.rawValue): mean \(ms(times.reduce(0, +) / Double(times.count))) ms, p95 \(ms(sorted[sorted.count * 95 / 100])) ms, max \(ms(sorted.last ?? 0)) ms"
    }

    /// Median GPU time of rendering `root` at 2x, ms.
    @MainActor
    static func render(_ root: CALayer, target: MTLTexture, queue: MTLCommandQueue, runs: Int = 9) -> Double {
        let renderer = CARenderer(mtlTexture: target, options: [kCARendererMetalCommandQueue as String: queue])
        let holder = CALayer()
        holder.frame = CGRect(x: 0, y: 0, width: target.width, height: target.height)
        root.anchorPoint = .zero
        root.position = .zero
        root.setAffineTransform(CGAffineTransform(scaleX: 2, y: 2))
        holder.addSublayer(root)
        renderer.layer = holder
        renderer.bounds = holder.frame
        CATransaction.flush()
        var times: [Double] = []
        for _ in 0..<runs {
            let t0 = CACurrentMediaTime()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            let b = queue.makeCommandBuffer()!
            b.commit()
            b.waitUntilCompleted()
            times.append((CACurrentMediaTime() - t0) * 1000)
        }
        root.removeFromSuperlayer()
        root.setAffineTransform(.identity)
        return times.sorted()[runs / 2]
    }

    /// What each of the stage's and the card's top layers adds, the costliest three.
    @MainActor
    private static func breakdown(_ root: CALayer, target: MTLTexture, queue: MTLCommandQueue) -> String {
        let base = render(root, target: target, queue: queue)
        var costs: [(String, Double)] = []
        func walk(_ layer: CALayer, _ path: String, depth: Int) {
            for (i, sub) in (layer.sublayers ?? []).enumerated() where !sub.isHidden {
                let name = "\(path)/\(i):\(String(describing: type(of: sub)).replacingOccurrences(of: "CA", with: ""))"
                sub.isHidden = true
                costs.append((name, base - render(root, target: target, queue: queue, runs: 5)))
                sub.isHidden = false
                if depth < 2 { walk(sub, name, depth: depth + 1) }
            }
        }
        walk(root, "", depth: 0)
        let top = costs.sorted { $0.1 > $1.1 }.prefix(4).map { "\($0.0) \(ms($0.1))" }
        return "; heaviest: " + top.joined(separator: ", ")
    }
}
#endif
