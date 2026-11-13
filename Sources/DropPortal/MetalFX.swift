//
//  MetalFX.swift
//  DropPortal
//
//  The GPU layer of the crossing effects: one device, one command queue and
//  four pipelines compiled from source (MetalFXShaders.swift) off the main
//  thread, a canvas that is a CAMetalLayer on screen and a plain CALayer in
//  the harness, and one display link that drives every live canvas only while
//  something on it moves. Everything here is additive to the Core Animation
//  path: when Metal is missing, still compiling, under Reduce motion or Low
//  Power Mode, no canvas is made and the CA effects play exactly as before.
//
//  Nothing here reads the screen: the shaders draw only the card's own
//  picture (the snapshot the card look already takes) and light.
//

import AppKit
import DropPortalCore
import Metal
import QuartzCore

/// Where Metal effects may run. The droplet's main process sets `.live` in
/// `activate`; the harness sets `.stills` (shaders compiled at once, every
/// frame rendered synchronously into a bitmap); everything else is `.off`.
public enum MetalFXMode: Sendable { case off, live, stills }

/// What the shaders read, ten float4s (see `struct U` in the shader source).
struct FXUniforms {
    var a = SIMD4<Float>()  // effect, p, seconds since send (−1), seconds since impact (−1)
    var b = SIMD4<Float>()  // layer width, height (pt), origin x, y in the effect's space
    var c = SIMD4<Float>()  // card centre x, y, width, height
    var d = SIMD4<Float>()  // seam x, y, landing x, y
    var e = SIMD4<Float>()  // core rgb, rainbow
    var f = SIMD4<Float>()  // glow rgb, rainbow turn
    var g = SIMD4<Float>()  // accent rgb, k (the spec's scale)
    var h = SIMD4<Float>()  // flight, shape sx, sy, turn (radians)
    var i = SIMD4<Float>()  // pixels per point, extra values per pass
    var j = SIMD4<Float>()  // extra values per pass
}

/// One draw in a frame: a full-layer triangle (`instances == 0`) or that many particle quads.
struct FXDraw {
    var pipeline: MTLRenderPipelineState
    var uniforms: FXUniforms
    var texture: MTLTexture?
    var instances = 0
}

public final class MetalFX: @unchecked Sendable {
    nonisolated(unsafe) public static var mode: MetalFXMode = .off
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: MetalFX?
    nonisolated(unsafe) private static var compiling = false
    nonisolated(unsafe) private static var failed = false

    let device: MTLDevice
    let queue: MTLCommandQueue
    let stage: MTLRenderPipelineState
    let particles: MTLRenderPipelineState
    let card: MTLRenderPipelineState
    let wing: MTLRenderPipelineState
    /// A 1 × 1 clear texture for passes without the card's picture.
    let blank: MTLTexture
    /// Where live frames are encoded and presented, never the main thread.
    let renderQueue = DispatchQueue(label: "drop-portal.metal-fx", qos: .userInteractive)
    /// The last frames' GPU times, for the log and the harness.
    private let statsLock = NSLock()
    private var gpuTimes: [Double] = []

    private init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MetalFXShaders.source, options: Self.compileOptions)
        else { return nil }
        func pipeline(_ vertex: String, _ fragment: String, additive: Bool) -> MTLRenderPipelineState? {
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else { return nil }
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
            c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let stage = pipeline("fx_tri", "stage_fs", additive: false),
              let particles = pipeline("particle_vs", "particle_fs", additive: true),
              let card = pipeline("fx_tri", "card_fs", additive: false),
              let wing = pipeline("fx_tri", "wing_fs", additive: false)
        else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let blank = device.makeTexture(descriptor: td) else { return nil }
        var zero: UInt32 = 0
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.device = device
        self.queue = queue
        self.stage = stage
        self.particles = particles
        self.card = card
        self.wing = wing
        self.blank = blank
    }

    private static var compileOptions: MTLCompileOptions {
        let o = MTLCompileOptions()
        if #available(macOS 15.0, *) { o.mathMode = .fast } else { o.fastMathEnabled = true }
        return o
    }

    /// The main process, in activate(): Metal effects may play, the shaders compile in the background.
    @MainActor public static func enableLive() {
        lock.lock()
        mode = .live
        lock.unlock()
        warm()
    }

    /// Compiles the shaders on a background queue (about 0.1 s, once). A
    /// crossing that starts before it is done plays the Core Animation path.
    static func warm() {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .live, shared == nil, !compiling, !failed else { return }
        compiling = true
        DispatchQueue.global(qos: .utility).async {
            let start = CFAbsoluteTimeGetCurrent()
            let made = MTLCreateSystemDefaultDevice().flatMap { MetalFX(device: $0) }
            lock.lock()
            compiling = false
            if mode == .live { shared = made }
            if let made { SkyEngine.prepare(device: made.device) }
            failed = made == nil
            lock.unlock()
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            PortalLog.write(made.map { "metal: ready in \(ms) ms (\($0.device.name))" } ?? "metal: unavailable, Core Animation effects")
        }
    }

    /// The engine for a crossing that starts now, or nil for the Core Animation path.
    @MainActor static func forCrossing() -> MetalFX? {
        switch mode {
        case .off: return nil
        case .stills:
            lock.lock()
            defer { lock.unlock() }
            if shared == nil, !failed {
                shared = MTLCreateSystemDefaultDevice().flatMap { MetalFX(device: $0) }
                failed = shared == nil
            }
            return shared
        case .live:
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled { return nil }
            lock.lock()
            let ready = shared
            lock.unlock()
            if ready == nil { warm() }
            return ready
        }
    }

    /// deactivate(): no more frames, the engine and its memory let go.
    @MainActor public static func shutdown() {
        FXDriver.shared.stopAll()
        SkyEngine.shutdown()
        SkyBoard.reset()
        lock.lock()
        mode = .off
        shared = nil
        failed = false
        lock.unlock()
    }

    // MARK: Textures

    /// The card's picture as a texture (premultiplied RGBA, sRGB values), or nil.
    func texture(from image: CGImage?) -> MTLTexture? {
        guard let image, image.width > 0, image.height > 0 else { return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        // Row 0 of the bitmap (and of the texture) is the picture's top row.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return texture
    }

    // MARK: Encoding

    func encode(_ draws: [FXDraw], into target: MTLTexture, buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        for draw in draws {
            var u = draw.uniforms
            enc.setRenderPipelineState(draw.pipeline)
            enc.setVertexBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<FXUniforms>.stride, index: 0)
            enc.setFragmentTexture(draw.texture ?? blank, index: 0)
            if draw.instances > 0 {
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: draw.instances)
            } else {
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        enc.endEncoding()
    }

    func record(gpu seconds: Double) {
        guard seconds > 0 else { return }
        statsLock.lock()
        gpuTimes.append(seconds)
        if gpuTimes.count > 240 { gpuTimes.removeFirst(gpuTimes.count - 240) }
        statsLock.unlock()
    }

    /// Mean and worst GPU time of the last frames, milliseconds; then forgets them.
    func takeStats() -> (frames: Int, mean: Double, worst: Double) {
        statsLock.lock()
        defer { gpuTimes.removeAll(); statsLock.unlock() }
        guard !gpuTimes.isEmpty else { return (0, 0, 0) }
        return (gpuTimes.count, gpuTimes.reduce(0, +) / Double(gpuTimes.count) * 1000, (gpuTimes.max() ?? 0) * 1000)
    }

    /// Renders `draws` into a new bitmap at once (the harness; never live).
    func image(_ draws: [FXDraw], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let buffer = queue.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        encode(draws, into: target, buffer: buffer)
        if target.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { PortalLog.write("metal: frame failed: \(error)") }
        record(gpu: buffer.gpuEndTime - buffer.gpuStartTime)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Canvas

/// One surface the GPU draws on: a CAMetalLayer live, a plain layer with a
/// bitmap in the harness. Its pixels per point are capped so a big stage
/// never costs more than about 1.4 million pixels a frame.
@MainActor
final class FXCanvas {
    let layer: CALayer
    private let metalLayer: CAMetalLayer?
    let engine: MetalFX
    let pxScale: CGFloat
    private let gate = InFlight()
    private(set) var framesDrawn = 0

    /// Frames on the GPU; a third is dropped instead of waiting for a drawable.
    private final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func enter() -> Bool { lock.lock(); defer { lock.unlock() }; guard count < 2 else { return false }; count += 1; return true }
        func leave() { lock.lock(); count = max(0, count - 1); lock.unlock() }
    }

    init(engine: MetalFX, frame: CGRect, scale: CGFloat, maxPixels: CGFloat = 1_400_000) {
        self.engine = engine
        let area = max(1, frame.width * frame.height)
        pxScale = max(0.5, min(scale, (maxPixels / area).squareRoot()))
        if MetalFX.mode == .stills {
            let plain = CALayer()
            plain.contentsGravity = .resize
            metalLayer = nil
            layer = plain
        } else {
            let m = CAMetalLayer()
            m.device = engine.device
            m.pixelFormat = .bgra8Unorm
            m.framebufferOnly = true
            m.isOpaque = false
            m.maximumDrawableCount = 3
            m.allowsNextDrawableTimeout = true
            m.presentsWithTransaction = false
            m.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            m.contentsScale = pxScale
            m.drawableSize = CGSize(width: (frame.width * pxScale).rounded(), height: (frame.height * pxScale).rounded())
            metalLayer = m
            layer = m
        }
        layer.frame = frame
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
    }

    var pixelSize: (Int, Int) {
        (Int((layer.bounds.width * pxScale).rounded()), Int((layer.bounds.height * pxScale).rounded()))
    }

    /// Draws one frame. Live: encoded and presented on the render queue; a
    /// frame is dropped while two are still on the GPU, so the main thread
    /// never waits for a drawable. `done` runs on the main thread once the
    /// GPU has finished it.
    func draw(_ draws: [FXDraw], done: (@MainActor @Sendable () -> Void)? = nil) {
        framesDrawn += 1
        guard let metalLayer else {
            let (w, h) = pixelSize
            layer.contents = engine.image(draws, width: w, height: h)
            done?()
            return
        }
        guard gate.enter() else { return }
        let engine = engine, gate = gate
        nonisolated(unsafe) let target = metalLayer
        engine.renderQueue.async {
            guard let buffer = engine.queue.makeCommandBuffer(), let drawable = target.nextDrawable() else {
                gate.leave()
                return
            }
            engine.encode(draws, into: drawable.texture, buffer: buffer)
            buffer.present(drawable)
            buffer.addCompletedHandler { b in
                engine.record(gpu: b.gpuEndTime - b.gpuStartTime)
                gate.leave()
                if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
            }
            buffer.commit()
        }
    }

    /// An empty frame, so a layer never shows a stale picture.
    func clear() {
        if metalLayer == nil { layer.contents = nil; return }
        draw([])
    }
}

// MARK: - Driver

/// Something a display link frame can advance. Returns whether it wants the next frame too.
@MainActor
protocol FXClient: AnyObject {
    func tick(now: CFTimeInterval) -> Bool
}

/// One display link for every live canvas, running only while one of them
/// has something to draw; it stops by itself and in deactivate().
@MainActor
final class FXDriver: NSObject {
    static let shared = FXDriver()
    private struct Weak { weak var client: FXClient? }
    private var clients: [ObjectIdentifier: Weak] = [:]
    private var link: CADisplayLink?

    func wake(_ client: FXClient) {
        guard MetalFX.mode == .live else { return }
        clients[ObjectIdentifier(client)] = Weak(client: client)
        // The crossing's screen (the pointer's, as LandingPresenter picks it), at its top
        // rate like FrameClock (PortalFeel.swift): 120 Hz on ProMotion, never stuck at 60.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if link == nil, let screen {
            let link = screen.displayLink(target: self, selector: #selector(step(_:)))
            link.preferredFrameRateRange = FrameRate.range(on: screen)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func remove(_ client: FXClient) {
        clients[ObjectIdentifier(client)] = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (id, box) in clients {
            guard let client = box.client, client.tick(now: now) else { clients[id] = nil; continue }
        }
        if clients.isEmpty { stopAll() }
    }

    func stopAll() {
        clients.removeAll()
        link?.invalidate()
        link = nil
    }
}

// MARK: - Shared values

extension FXUniforms {
    /// The palette and the scale, the same for every pass of a crossing.
    mutating func set(palette: PortalPalette, k: CGFloat) {
        func rgb(_ c: NSColor) -> SIMD3<Float> {
            let s = c.usingColorSpace(.sRGB) ?? c
            return SIMD3(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent))
        }
        let core = rgb(palette.core), glow = rgb(palette.glow), accent = rgb(palette.accent)
        e = SIMD4(core.x, core.y, core.z, palette.rainbow ? 1 : 0)
        f = SIMD4(glow.x, glow.y, glow.z, 0)
        g = SIMD4(accent.x, accent.y, accent.z, Float(k))
    }
}

extension PortalEffect {
    /// The shaders' number for the effect.
    var shaderID: Float {
        switch self {
        case .portal: 0
        case .liquid: 1
        case .wormhole: 2
        case .beam: 3
        case .plane: 4
        case .stardust: 5
        case .lightning: 6
        case .cheek, .pounce, .mole, .ducks: 0
        }
    }

    /// GPU particles at the impact: thousands of points, all gone 0.55 s after the landing.
    var particleCount: Int {
        switch self {
        case .portal: 2400
        case .liquid: 1800
        case .wormhole: 3000
        case .beam: 2000
        case .plane: 1400
        case .stardust, .lightning, .cheek, .pounce, .mole, .ducks: 0
        }
    }
}
