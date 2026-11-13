//
//  SkyMetal.swift
//  DropPortal
//
//  The GPU side of Stardust and Lightning: their pipelines (SkyShaders.swift)
//  compiled off the main thread on MetalFX's device, and an EDR canvas: a
//  CAMetalLayer in rgba16Float, extended linear sRGB, opted into extended
//  dynamic range, so the glint and the return stroke can go past SDR white,
//  never past the screen's headroom. In the harness the same frame renders
//  into a bitmap. Additive to MetalFX: when either is missing, the effects
//  play their Core Animation fallback (SkyCrossing.swift).
//

import AppKit
import DropPortalCore
import Metal
import QuartzCore

/// What the sky shaders read (`struct SkyU`).
struct SkyUniforms {
    var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>(), d = SIMD4<Float>()
    var e = SIMD4<Float>(), f = SIMD4<Float>(), g = SIMD4<Float>(), h = SIMD4<Float>()
    var i = SIMD4<Float>(), j = SIMD4<Float>()
}

/// `struct BoltVertex`: 32 bytes.
struct SkyBoltVertex {
    var p: SIMD2<Float>, n: SIMD2<Float>
    var along: Float, side: Float, weight: Float, pad: Float = 0
}

final class SkyEngine: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: SkyEngine?
    nonisolated(unsafe) private static var compiling = false
    nonisolated(unsafe) private static var failed = false

    static let format: MTLPixelFormat = .rgba16Float
    let device: MTLDevice
    let queue: MTLCommandQueue
    let grain, glitter, filler, bolt, down, up, comp, lift: MTLRenderPipelineState
    let blank: MTLTexture
    let renderQueue = DispatchQueue(label: "drop-portal.sky-fx", qos: .userInteractive)

    private enum Blend { case over, add, max, none }

    private init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) { options.mathMode = .fast } else { options.fastMathEnabled = true }
        guard let library = try? device.makeLibrary(source: SkyShaders.source, options: options) else { return nil }
        func pipeline(_ v: String, _ f: String, _ blend: Blend) -> MTLRenderPipelineState? {
            guard let vf = library.makeFunction(name: v), let ff = library.makeFunction(name: f) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.format
            switch blend {
            case .none: c.isBlendingEnabled = false
            case .over, .add:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
            case .max:
                // The bolt's overlapping quads leave no bright dots at the joints.
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .max
                c.alphaBlendOperation = .max
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let grain = pipeline("grain_vs", "grain_fs", .over),
              let glitter = pipeline("glitter_vs", "glow_fs", .add),
              let filler = pipeline("filler_vs", "glow_fs", .add),
              let bolt = pipeline("bolt_vs", "bolt_fs", .max),
              let down = pipeline("sky_tri", "down_fs", .none),
              let up = pipeline("sky_tri", "up_fs", .add),
              let comp = pipeline("sky_tri", "comp_fs", .add),
              let lift = pipeline("sky_tri", "lift_fs", .add)
        else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let blank = device.makeTexture(descriptor: td) else { return nil }
        var zero: UInt32 = 0
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.device = device
        self.queue = queue
        (self.grain, self.glitter, self.filler, self.bolt) = (grain, glitter, filler, bolt)
        (self.down, self.up, self.comp, self.lift) = (down, up, comp, lift)
        self.blank = blank
    }

    /// MetalFX's engine is ready (its background queue): compile ours on the same device.
    static func prepare(device: MTLDevice) {
        lock.lock()
        guard shared == nil, !compiling, !failed else { lock.unlock(); return }
        compiling = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let start = CFAbsoluteTimeGetCurrent()
            let made = SkyEngine(device: device)
            lock.lock()
            compiling = false
            if MetalFX.mode != .off { shared = made }
            failed = made == nil
            lock.unlock()
            PortalLog.write(made == nil ? "sky: shaders failed, Core Animation fallback"
                                        : "sky: ready in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms")
        }
    }

    /// The engine for a crossing that starts now, or nil for the Core Animation fallback.
    @MainActor static func forCrossing() -> SkyEngine? {
        guard let fx = MetalFX.forCrossing() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if MetalFX.mode == .stills, shared == nil, !failed {
            shared = SkyEngine(device: fx.device)
            failed = shared == nil
        }
        if shared == nil, !compiling, !failed, MetalFX.mode == .live {
            lock.unlock()
            prepare(device: fx.device)
            lock.lock()
        }
        return shared
    }

    static func shutdown() {
        lock.lock()
        shared = nil
        failed = false
        lock.unlock()
    }

    // MARK: Textures

    /// The card's picture, sampled as linear light (an sRGB texture).
    func texture(from image: CGImage?) -> MTLTexture? {
        guard let image, image.width > 0, image.height > 0 else { return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return t
    }

    /// An offscreen float target (the bolt and its bloom levels).
    func target(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.format, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    func pass(_ buffer: MTLCommandBuffer, into target: MTLTexture, clear: Bool, _ body: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        body(enc)
        enc.endEncoding()
    }
}

extension MTLRenderCommandEncoder {
    func sky(_ pipeline: MTLRenderPipelineState, _ u: SkyUniforms, textures: [MTLTexture] = []) {
        var u = u
        setRenderPipelineState(pipeline)
        setVertexBytes(&u, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        setFragmentBytes(&u, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        for (i, t) in textures.enumerated() {
            setVertexTexture(t, index: i)
            setFragmentTexture(t, index: i)
        }
    }
}

// MARK: - Canvas

/// One EDR surface. Live: a CAMetalLayer drawn on the engine's render queue,
/// a frame dropped while two are still on the GPU. Harness: a bitmap of the
/// same frame (EDR clipped to white by the PNG).
@MainActor
final class SkyCanvas {
    let layer: CALayer
    private let metalLayer: CAMetalLayer?
    let engine: SkyEngine
    let pxScale: CGFloat
    private let gate = Gate()
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func enter() -> Bool { lock.lock(); defer { lock.unlock() }; guard count < 2 else { return false }; count += 1; return true }
        func leave() { lock.lock(); count = max(0, count - 1); lock.unlock() }
    }

    init(engine: SkyEngine, frame: CGRect, scale: CGFloat, maxPixels: CGFloat) {
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
            m.pixelFormat = SkyEngine.format
            m.framebufferOnly = true
            m.isOpaque = false
            m.maximumDrawableCount = 3
            m.allowsNextDrawableTimeout = true
            m.wantsExtendedDynamicRangeContent = true
            m.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
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

    /// The headroom of the screen the canvas is on (1 on an SDR screen), read every frame.
    var headroom: CGFloat {
        guard metalLayer != nil else { return 1 }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return max(1, screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
    }

    /// One frame: `encode` fills the target (cleared) on the render queue.
    func draw(_ encode: @escaping @Sendable (MTLCommandBuffer, MTLTexture) -> Void) {
        guard let metalLayer else {
            layer.contents = still(encode)
            return
        }
        guard gate.enter() else { return }
        let engine = engine, gate = gate
        nonisolated(unsafe) let target = metalLayer
        engine.renderQueue.async {
            guard let buffer = engine.queue.makeCommandBuffer(), let drawable = target.nextDrawable() else { gate.leave(); return }
            encode(buffer, drawable.texture)
            buffer.present(drawable)
            buffer.addCompletedHandler { b in
                SkyStats.shared.record(b.gpuEndTime - b.gpuStartTime)
                gate.leave()
            }
            buffer.commit()
        }
    }

    func clear() {
        if metalLayer == nil { layer.contents = nil; return }
        let engine = engine
        draw { buffer, target in engine.pass(buffer, into: target, clear: true) { _ in } }
    }

    /// The harness: the frame at once, as premultiplied sRGB bytes.
    private func still(_ encode: (MTLCommandBuffer, MTLTexture) -> Void) -> CGImage? {
        let (w, h) = pixelSize
        guard w > 0, h > 0, let buffer = engine.queue.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SkyEngine.format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = engine.device.hasUnifiedMemory ? .shared : .managed
        guard let target = engine.device.makeTexture(descriptor: d) else { return nil }
        engine.pass(buffer, into: target, clear: true) { _ in }
        encode(buffer, target)
        if target.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        SkyStats.shared.record(buffer.gpuEndTime - buffer.gpuStartTime)
        var half = [UInt16](repeating: 0, count: w * h * 4)
        target.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // Premultiplied linear light to premultiplied sRGB bytes without unpremultiplying: CG's own
        // conversion divides by alpha and clamps, which loses light added over little cover; the
        // screen's compositor never does. EDR above 1 is clipped to white here.
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let lut = Self.srgbTable
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = min(1, max(0, Self.float(half[i * 4 + c])))
                bytes[i * 4 + c] = lut[Int(v * 4095)]
            }
            bytes[i * 4 + 3] = UInt8(min(1, max(0, Self.float(half[i * 4 + 3]))) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// IEEE half to Float (Float16 is not on Intel Macs).
    private static func float(_ h: UInt16) -> Float {
        let sign: Float = h & 0x8000 != 0 ? -1 : 1, e = Int(h >> 10 & 0x1F), m = Float(h & 0x3FF)
        if e == 0 { return sign * m * pow(2, -24) }
        if e == 31 { return m == 0 ? sign * .infinity : .nan }
        return sign * (1 + m / 1024) * pow(2, Float(e - 15))
    }

    private static let srgbTable: [UInt8] = (0..<4096).map { i in
        let v = Double(i) / 4095
        let e = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }
}

/// GPU time of the sky frames, for the bench.
final class SkyStats: @unchecked Sendable {
    static let shared = SkyStats()
    private let lock = NSLock()
    private var times: [Double] = []
    func record(_ seconds: Double) {
        guard seconds > 0 else { return }
        lock.lock(); times.append(seconds); if times.count > 480 { times.removeFirst(times.count - 480) }; lock.unlock()
    }
    func take() -> (frames: Int, mean: Double, worst: Double) {
        lock.lock(); defer { times.removeAll(); lock.unlock() }
        guard !times.isEmpty else { return (0, 0, 0) }
        return (times.count, times.reduce(0, +) / Double(times.count) * 1000, (times.max() ?? 0) * 1000)
    }
}
