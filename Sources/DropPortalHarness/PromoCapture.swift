//
//  PromoCapture.swift
//
//  The promo video's raw footage, for the harness only (debug builds):
//
//    --promo-assets <dir>                       made-up photos and a plain dark desktop
//    --promo-phone <dir> <effect> <tint> <assets> [edge]
//        the real phone page, served by a real DropPortalServer on 127.0.0.1,
//        in an offscreen WKWebView at 393 × 852, driven by scripted touches on
//        a virtual clock (timers, rAF and every Web Animation stepped 1/60 s at
//        a time) and snapshotted at 30 fps; writes frames/, peeks.json (what
//        the page sent to the Mac, with times) and touches.json
//    --promo-mac <dir> <effect> <tint> <phoneDir> <assets>
//        the Mac side of that same crossing, fed the page's peek messages:
//        PromoCrossing's layers through CARenderer, 30 fps
//    --promo-edge <dir> <effect> <tint> <assets>
//        a file dragged to the Mac's right edge and dropped (PromoEdgeSend)
//
//  Nothing is shown on screen: the web view's window sits off every display,
//  the Mac frames are rendered into a Metal texture. Uploads land in <dir>.
//

#if DEBUG
import AppKit
import DropPortal
import DropPortalCore
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
import WebKit

@MainActor
enum PromoCapture {
    static let fps = 60.0
    /// A 14-inch MacBook Pro's default resolution, menu bar beside the notch.
    static let screen = CGSize(width: 1512, height: 982)
    static let menuBar: CGFloat = 37
    static let renderScale: CGFloat = 1.5
    static let rainbowAt = Date(timeIntervalSince1970: 1_794_476_460)

    static func run(_ args: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await dispatch(args)
                exit(0)
            } catch {
                FileHandle.standardError.write("promo: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        app.run()
        exit(0)
    }

    static func dispatch(_ args: [String]) async throws {
        func arg(_ flag: String, _ n: Int) -> [String]? {
            guard let i = args.firstIndex(of: flag), args.count > i + n else { return nil }
            return Array(args[(i + 1)...(i + n)])
        }
        if let a = arg("--promo-assets", 1) {
            try PromoAssets.write(to: URL(fileURLWithPath: a[0]))
        } else if let a = arg("--promo-phone", 4) {
            let scene = args.contains("edge") ? "edge" : args.contains("shortcuts") ? "shortcuts" : "flick"
            let capture = PhoneCapture(dir: URL(fileURLWithPath: a[0]), effect: a[1], tint: resolve(a[2], a[1]),
                                       assets: URL(fileURLWithPath: a[3]), scene: scene)
            try await capture.run()
        } else if let a = arg("--promo-mac", 5) {
            try await renderMac(dir: URL(fileURLWithPath: a[0]), effect: a[1], tint: resolve(a[2], a[1]),
                          phone: URL(fileURLWithPath: a[3]), assets: URL(fileURLWithPath: a[4]))
        } else if let a = arg("--promo-edge", 4) {
            try renderEdge(dir: URL(fileURLWithPath: a[0]), effect: a[1], tint: resolve(a[2], a[1]), assets: URL(fileURLWithPath: a[3]))
        } else {
            throw CocoaError(.featureUnsupported)
        }
    }

    /// "default" is the effect's own colour, as the app stores it.
    static func resolve(_ tint: String, _ effect: String) -> String {
        tint == "default" ? PortalTint.defaultTint(for: PortalEffect(stored: effect)).stored : tint
    }

    // MARK: Mac

    static func renderMac(dir: URL, effect: String, tint: String, phone: URL, assets: URL) async throws {
        let frames = dir.appendingPathComponent("frames")
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let log = try JSONSerialization.jsonObject(with: Data(contentsOf: phone.appendingPathComponent("peeks.json"))) as? [[String: Any]] ?? []
        let events = log.compactMap { m -> PromoCrossing.Event? in
            guard let type = m["type"] as? String, let t = m["t"] as? Double else { return nil }
            return PromoCrossing.Event(t: t / 1000, type: type, progress: m["progress"] as? Double ?? 0)
        }
        let start = log.first { $0["type"] as? String == "peek-start" } ?? [:]
        let name = start["name"] as? String ?? "IMG_2041.JPG"
        let bytes = (start["size"] as? NSNumber)?.int64Value ?? 0
        var thumbText = (try? String(contentsOf: phone.appendingPathComponent("thumb.txt"), encoding: .utf8)) ?? ""
        if let comma = thumbText.firstIndex(of: ",") { thumbText = String(thumbText[thumbText.index(after: comma)...]) }
        let thumb = Data(base64Encoded: thumbText) ?? Data()
        let received = (try? FileManager.default.contentsOfDirectory(at: phone.appendingPathComponent("received"), includingPropertiesForKeys: nil))?
            .first { !$0.lastPathComponent.hasPrefix(".") }
        var landed = NSImage(size: NSSize(width: 10, height: 10))
        if let received { landed = await PromoCrossing.landedImage(for: received) }
        // When the upload finished, as the page saw it.
        let progress = events.filter { $0.type == "peek-progress" }
        let commit = events.first { $0.type == "peek-commit" }?.t ?? 0
        let done = progress.first { $0.progress >= 1 }?.t ?? (commit + 0.4)
        let crossing = PromoCrossing(effect: effect, tint: tint, rainbowAt: rainbowAt, screen: screen, menuBar: menuBar,
                                     desktop: PromoAssets.image(assets.appendingPathComponent("desktop.png")),
                                     name: name, bytes: bytes, thumb: thumb, landed: landed, events: events,
                                     uploadSeconds: max(0.45, done - commit))
        let renderer = try LayerRenderer(size: screen, scale: renderScale)
        let count = Int((crossing.endT * fps).rounded(.up))
        for i in 0..<count {
            let t = Double(i) / fps
            let image = try renderer.render(crossing.layer(at: t))
            try PromoAssets.writePNG(image, to: frames.appendingPathComponent(String(format: "%04d.png", i)))
        }
        let meta: [String: Any] = ["fps": fps, "frames": count, "start": crossing.startT, "commit": crossing.commitT,
                                   "land": crossing.landT, "settle": crossing.settleT, "end": crossing.endT,
                                   "screen": [screen.width, screen.height], "scale": renderScale]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("meta.json"))
        print("mac: \(count) frames, commit \(crossing.commitT), land \(crossing.landT)")
    }

    static func renderEdge(dir: URL, effect: String, tint: String, assets: URL) throws {
        let frames = dir.appendingPathComponent("frames")
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let file = assets.appendingPathComponent("Lake at dawn.jpg")
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        let y: CGFloat = 470
        let home = CGPoint(x: 1080, y: y + 40)
        let path: [(Double, CGPoint)] = [(0, CGPoint(x: 820, y: 330)), (0.55, CGPoint(x: home.x + 4, y: home.y - 6)),
                                         (0.75, CGPoint(x: home.x + 4, y: home.y - 6)),
                                         (1.5, CGPoint(x: 1380, y: y + 10)), (2.05, CGPoint(x: 1494, y: y))]
        let send = PromoEdgeSend(effect: effect, tint: tint, rainbowAt: rainbowAt, screen: screen,
                                 desktop: PromoAssets.image(assets.appendingPathComponent("desktop.png")),
                                 icon: icon, label: file.lastPathComponent, home: home, path: path, pressT: 0.62, dropT: 2.15)
        let renderer = try LayerRenderer(size: screen, scale: renderScale)
        let end = 3.6
        let count = Int(end * fps)
        for i in 0..<count {
            let image = try renderer.render(send.layer(at: Double(i) / fps))
            try PromoAssets.writePNG(image, to: frames.appendingPathComponent(String(format: "%04d.png", i)))
        }
        let meta: [String: Any] = ["fps": fps, "frames": count, "drop": send.dropT, "file": file.lastPathComponent,
                                   "screen": [screen.width, screen.height], "scale": renderScale]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("meta.json"))
        print("edge: \(count) frames, drop \(send.dropT)")
    }
}

/// A layer tree drawn by Core Animation's own renderer into a Metal texture.
@MainActor
final class LayerRenderer {
    let width: Int, height: Int, scale: CGFloat
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let texture: MTLTexture
    private let renderer: CARenderer
    private let top = CALayer()

    init(size: CGSize, scale: CGFloat) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        self.device = device
        self.queue = queue
        self.scale = scale
        width = Int(size.width * scale)
        height = Int(size.height * scale)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else { throw CocoaError(.featureUnsupported) }
        self.texture = texture
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue as String: queue,
                                                              kCARendererColorSpace as String: CGColorSpace(name: CGColorSpace.sRGB)!])
        top.frame = CGRect(x: 0, y: 0, width: width, height: height)
        top.backgroundColor = NSColor.black.cgColor
        renderer.layer = top
        renderer.bounds = top.frame
    }

    func render(_ layer: CALayer) throws -> CGImage {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        top.sublayers?.forEach { $0.removeFromSuperlayer() }
        // The texture's first row is the top: the tree goes in upside down.
        layer.anchorPoint = .zero
        layer.position = CGPoint(x: 0, y: CGFloat(height))
        layer.transform = CATransform3DMakeScale(scale, -scale, 1)
        top.addSublayer(layer)
        CATransaction.commit()
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { throw CocoaError(.featureUnsupported) }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let rowBytes = width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}

// MARK: - Phone

/// The real page in a web view, on a clock the capture owns.
@MainActor
final class PhoneCapture: NSObject, WKNavigationDelegate {
    static let size = CGSize(width: 393, height: 852)
    static let safeTop: CGFloat = 59, safeBottom: CGFloat = 34
    let dir: URL, effect: String, tint: String, assets: URL, scene: String
    private var edge: Bool { scene == "edge" }
    private var webView: WKWebView!
    private var window: NSWindow!
    private var loaded: CheckedContinuation<Void, Never>?
    private var touches: [[String: Any]] = []

    init(dir: URL, effect: String, tint: String, assets: URL, scene: String) {
        self.dir = dir
        self.effect = effect
        self.tint = tint
        self.assets = assets
        self.scene = scene
    }

    func run() async throws {
        let fm = FileManager.default
        let frames = dir.appendingPathComponent("frames"), received = dir.appendingPathComponent("received")
        try? fm.removeItem(at: frames)
        try? fm.removeItem(at: received)
        try fm.createDirectory(at: frames, withIntermediateDirectories: true)
        try fm.createDirectory(at: received, withIntermediateDirectories: true)

        let port = UInt16(18_000 + Int.random(in: 700...799))
        let server = DropPortalServer(port: port, destination: received, outbox: dir.appendingPathComponent("outbox"))
        server.token = PairingToken.generate()
        server.setEffect(PortalEffect(stored: effect), tint: PortalTint(stored: tint) ?? .defaultTint(for: PortalEffect(stored: effect)))
        server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 400_000_000)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.clockScript(effect: effect, tint: tint), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.safeAreaScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: Self.size.width, height: Self.size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()

        let url = URL(string: "http://127.0.0.1:\(port)/?t=\(server.token)")!
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loaded = c
            webView.load(URLRequest(url: url))
        }
        try await pump(seconds: 0.5)

        // The script: the page waits, Pick, the photos come in, a touch on the
        // second card, a flick off the left edge. `edge` instead keeps the page
        // still and a file arrives from the Mac.
        let photos = ["Golden hour.jpg", "Ridge at dusk.jpg", "City lights.jpg", "Lake at dawn.jpg"]
        let end = edge ? 4.8 : scene == "shortcuts" ? 3.0 : 3.6
        var step = 0
        var frame = 0
        var addedAt: Double? = nil
        var flick: (start: CGPoint, t0: Double)? = nil
        if scene != "flick" {
            try await addFiles(photos)
            try await waitForThumbs(photos.count)
        }
        let shortcutsTop = scene == "shortcuts"
            ? (try await js("Math.max(0, document.getElementById('shortcuts').getBoundingClientRect().top - \(Int(Self.safeTop)) - 70)") as? Double ?? 0) : 0
        let dt = 1.0 / 60
        while Double(frame) / PromoCapture.fps < end {
            let t = Double(step) * dt
            if scene == "flick" {
                if addedAt == nil, t >= 0.55, touches.isEmpty {
                    touch(t, x: 70, y: Self.pickY, down: true)
                }
                if addedAt == nil, t >= 0.75 {
                    touch(t, x: 70, y: Self.pickY, down: false)
                    try await addFiles(photos)
                    try await waitForThumbs(photos.count)
                    addedAt = t
                }
                if let added = addedAt, flick == nil, t >= added + 0.9 {
                    let center = try await cardCenter(1)
                    flick = (center, t)
                    _ = try await js("__V.pointer('pointerdown', \(center.x), \(center.y))")
                    touch(t, x: center.x, y: center.y, down: true)
                }
                if let f = flick, f.t0 >= 0 {
                    let u = (t - f.t0 - 0.08) / 0.40
                    if u > 0 {
                        let k = pow(min(1, u), 1.9)
                        let p = CGPoint(x: f.start.x - 210 * k, y: f.start.y - 14 * k)
                        _ = try await js("__V.pointer('pointermove', \(p.x), \(p.y))")
                        touch(t, x: p.x, y: p.y, down: true)
                        if u >= 1 {
                            _ = try await js("__V.pointer('pointerup', \(p.x), \(p.y))")
                            touch(t, x: p.x, y: p.y, down: false)
                            flick = (f.start, -100)
                        }
                    }
                }
            } else if scene == "shortcuts" {
                // A slow scroll down to the iPhone Shortcuts section, then still.
                let u = min(1, max(0, (t - 0.4) / 1.4))
                let k = u * u * (3 - 2 * u)
                _ = try await js("window.scrollTo(0, \(shortcutsTop * k)); 0")
            } else if step == Int(2.45 / dt) {
                // The Mac offered the dropped file: the page hears "incoming" over its socket.
                let file = assets.appendingPathComponent("Lake at dawn.jpg")
                if let offer = server.offer(file) {
                    let message: [String: Any] = ["type": "incoming", "id": offer.id, "name": offer.name, "size": offer.size, "kind": offer.kind]
                    let json = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
                    _ = try await js("__V.deliver(\(json))")
                    try await pump(seconds: 0.4)
                }
            }
            _ = try await js("__V.step(\(dt * 1000))")
            try await snapshot(to: frames.appendingPathComponent(String(format: "%04d.png", frame)))
            frame += 1
            // Real time for the network and the image decoder between frames.
            try await Task.sleep(nanoseconds: 8_000_000)
            step += 1
        }
        try await pump(seconds: 1.0)
        let log = try await js("JSON.stringify(__V.log)") as? String ?? "[]"
        try log.write(to: dir.appendingPathComponent("peeks.json"), atomically: true, encoding: .utf8)
        let thumb = try await js("__V.thumb || ''") as? String ?? ""
        try thumb.write(to: dir.appendingPathComponent("thumb.txt"), atomically: true, encoding: .utf8)
        let errors = try await js("JSON.stringify(__V.errors)") as? String ?? "[]"
        let debug = try await js("""
            JSON.stringify({ now: __V.now, timers: __V.timers.map(function(t){ return [t.at, t.every, String(t.cb).slice(0, 80)]; }),
              raf: __V.raf.length,
              anims: document.getAnimations().map(function(a){ return [a.playState, a.currentTime, a.effect && a.effect.getComputedTiming().endTime, a.effect && a.effect.target && (a.effect.target.className || a.effect.target.tagName), a.constructor.name]; }),
              cards: Array.prototype.map.call(document.querySelectorAll('#grid .card'), function(c){ return [c.className, c.style.cssText]; }),
              portal: document.getElementById('portal').className + ' ' + document.getElementById('portal').style.cssText })
            """) as? String ?? ""
        try debug.write(to: dir.appendingPathComponent("debug.json"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: touches, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("touches.json"))
        let meta: [String: Any] = ["fps": PromoCapture.fps, "frames": frame, "size": [Self.size.width, Self.size.height]]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("meta.json"))
        print("phone: \(frame) frames, errors \(errors)")
        window.orderOut(nil)
    }

    /// The Pick button's height on the page, under the status bar.
    static let pickY: CGFloat = 59 + 16 + 24

    private func touch(_ t: Double, x: CGFloat, y: CGFloat, down: Bool) {
        touches.append(["t": t, "x": x, "y": y, "down": down])
    }

    private func cardCenter(_ index: Int) async throws -> CGPoint {
        let json = try await js("""
            (function(){ var c = document.querySelectorAll('#grid .card')[\(index)]; if (!c) return '[]';
              var r = c.getBoundingClientRect(); return JSON.stringify([r.left + r.width / 2, r.top + r.height / 2]); })()
            """) as? String ?? "[]"
        let a = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Double] ?? [196, 400]
        return CGPoint(x: a.first ?? 196, y: a.last ?? 400)
    }

    private func addFiles(_ names: [String]) async throws {
        var items: [String] = []
        // Named the way a phone's camera names them.
        for (i, name) in names.enumerated() {
            let data = try Data(contentsOf: assets.appendingPathComponent(name))
            items.append(#"{"name":"IMG_\#(2041 + i).JPG","type":"image/jpeg","b64":"\#(data.base64EncodedString())"}"#)
        }
        _ = try await js("__V.addFiles([\(items.joined(separator: ","))]); 0")
    }

    private func waitForThumbs(_ count: Int) async throws {
        // A thumbnail made before the photo has decoded is a few hundred bytes: wait for the real ones.
        for _ in 0..<120 {
            _ = try await js("__V.step(0)")
            let n = try await js("Array.prototype.filter.call(document.querySelectorAll('#grid .card'), function(c){ return !!c._thumb && c._thumb.length > 3000; }).length") as? Int ?? 0
            if n >= count { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await pump(seconds: 0.3)
    }

    /// Real time with the virtual clock held: loads, decodes and the network finish.
    private func pump(seconds: Double) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            _ = try await js("__V.step(0)")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @discardableResult
    private func js(_ source: String) async throws -> Any? {
        try await webView.evaluateJavaScript(source)
    }

    private func snapshot(to url: URL) async throws {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: Double(Self.size.width) * 1.5)
        let image = try await webView.takeSnapshot(configuration: config)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
        try PromoAssets.writePNG(cg, to: url)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    /// On a phone the page runs under the status bar and above the home
    /// indicator (viewport-fit=cover); here env(safe-area-inset-*) is 0, so
    /// the same insets are given to the body by hand.
    static let safeAreaScript = """
        (function(){ var s = document.createElement('style');
          s.textContent = 'body{padding-top:calc(\(Int(safeTop))px + 16px) !important;padding-bottom:calc(\(Int(safeBottom))px + 24px) !important}';
          document.head.appendChild(s); })();
        """

    /// Time the capture owns: performance.now, Date.now, timers, rAF and every
    /// animation advance only when the capture steps; the peek socket is a
    /// stand-in that answers hello like the Mac and keeps what the page sends.
    static func clockScript(effect: String, tint: String) -> String {
        """
        (function(){
          var V = window.__V = { now: 0, base: \(Int(PromoCapture.rainbowAt.timeIntervalSince1970 * 1000)), raf: [], timers: [], seq: 1,
                                 anims: new Map(), log: [], errors: [], sock: null, target: null, thumb: null,
                                 effect: \(String(reflecting: effect)), tint: \(String(reflecting: tint)) };
          var realTimeout = window.setTimeout.bind(window);
          try { localStorage.setItem('dropportal.tip', '1'); } catch (e) {}
          performance.now = function(){ return V.now; };
          Date.now = function(){ return V.base + V.now; };
          window.requestAnimationFrame = function(cb){ var id = V.seq++; V.raf.push({ id: id, cb: cb }); return id; };
          window.cancelAnimationFrame = function(id){ V.raf = V.raf.filter(function(r){ return r.id !== id; }); };
          window.setTimeout = function(cb, ms){ var id = V.seq++; V.timers.push({ id: id, at: V.now + Math.max(0, +ms || 0), cb: cb, args: [].slice.call(arguments, 2), every: 0 }); return id; };
          window.setInterval = function(cb, ms){ var id = V.seq++, e = Math.max(16, +ms || 0); V.timers.push({ id: id, at: V.now + e, cb: cb, args: [].slice.call(arguments, 2), every: e }); return id; };
          window.clearTimeout = window.clearInterval = function(id){ V.timers = V.timers.filter(function(t){ return t.id !== id; }); };
          Object.defineProperty(Document.prototype, 'hidden', { get: function(){ return false; }, configurable: true });
          Object.defineProperty(Document.prototype, 'visibilityState', { get: function(){ return 'visible'; }, configurable: true });
          function Sock(url){ var s = this; s.url = url; s.readyState = 0; s.bufferedAmount = 0; V.sock = s;
            realTimeout(function(){ s.readyState = 1; if (s.onopen) s.onopen({}); }, 0); }
          Sock.prototype.send = function(d){ var m = null, s = this; try { m = JSON.parse(d); } catch (e) {}
            if (!m) return;
            if (m.type === 'hello') { realTimeout(function(){ if (s.onmessage) s.onmessage({ data: JSON.stringify({ type: 'ready', effect: V.effect, tint: V.tint }) }); }, 0); return; }
            if (m.thumb) { V.thumb = m.thumb; m.thumb = m.thumb.length; }
            m.t = V.now; V.log.push(m); };
          Sock.prototype.close = function(){ this.readyState = 3; };
          Sock.CONNECTING = 0; Sock.OPEN = 1; Sock.CLOSING = 2; Sock.CLOSED = 3;
          window.WebSocket = Sock;
          V.deliver = function(m){ if (V.sock && V.sock.onmessage) V.sock.onmessage({ data: JSON.stringify(m) }); return 0; };
          V.pointer = function(type, x, y){
            var target = type === 'pointerdown' ? document.elementFromPoint(x, y) : (V.target || document.elementFromPoint(x, y));
            if (type === 'pointerdown') V.target = target;
            var ev = new PointerEvent(type, { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, pointerId: 7,
              pointerType: 'touch', isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, width: 30, height: 30, pressure: type === 'pointerup' ? 0 : 0.5 });
            Object.defineProperty(ev, 'timeStamp', { value: V.now });
            if (target) target.dispatchEvent(ev);
            if (type === 'pointerup') V.target = null;
            return 0;
          };
          V.addFiles = function(list){
            var dt = new DataTransfer();
            list.forEach(function(f){ var bin = atob(f.b64), u = new Uint8Array(bin.length);
              for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
              dt.items.add(new File([u], f.name, { type: f.type, lastModified: V.base })); });
            var input = document.getElementById('file'); input.files = dt.files;
            input.dispatchEvent(new Event('change', { bubbles: true }));
          };
          V.sync = function(){
            document.getAnimations().forEach(function(a){
              var rec = V.anims.get(a);
              if (!rec) { rec = { start: V.now }; V.anims.set(a, rec); }
              if (rec.done) return;
              try {
                var timing = a.effect ? a.effect.getComputedTiming() : null, end = timing ? timing.endTime : 0;
                var local = (V.now - rec.start) * (a.playbackRate || 1);
                if (a.playState !== 'paused') a.pause();
                if (isFinite(end) && local >= end) {
                  rec.done = true; a.finish();
                  // An offscreen page never gets its animation events: the finish callback runs here, once.
                  var f = a.onfinish; a.onfinish = null; if (f) f.call(a, new Event('finish'));
                } else a.currentTime = local;
              } catch (e) { V.errors.push(String(e)); }
            });
          };
          V.step = function(ms){
            V.now += ms;
            for (var guard = 0; guard < 500; guard++) {
              var due = null;
              V.timers.forEach(function(t){ if (t.at <= V.now && (!due || t.at < due.at)) due = t; });
              if (!due) break;
              if (due.every) due.at += due.every; else V.timers = V.timers.filter(function(t){ return t !== due; });
              try { if (typeof due.cb === 'function') due.cb.apply(window, due.args); } catch (e) { V.errors.push(String(e)); }
            }
            if (ms > 0) { var list = V.raf; V.raf = []; list.forEach(function(r){ try { r.cb(V.now); } catch (e) { V.errors.push(String(e)); } }); }
            V.sync();
            return V.now;
          };
        })();
        """
    }
}

// MARK: - Assets

/// Made-up photos (painted here, nobody's pictures) and a plain dark desktop.
@MainActor
enum PromoAssets {
    static func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 1512, height: 2016)
        for (name, paint) in [("Golden hour.jpg", sunset), ("Ridge at dusk.jpg", ridges),
                              ("City lights.jpg", bokeh), ("Lake at dawn.jpg", lake)] as [(String, (CGContext, CGSize) -> Void)] {
            let image = try draw(size) { ctx in paint(ctx, size); grain(ctx, size, amount: 0.035) }
            try writeJPEG(image, to: dir.appendingPathComponent(name))
        }
        let desk = CGSize(width: PromoCapture.screen.width * 2, height: PromoCapture.screen.height * 2)
        try writePNG(try draw(desk) { ctx in desktop(ctx, desk) }, to: dir.appendingPathComponent("desktop.png"))
        print("assets: \(dir.path)")
    }

    static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func draw(_ size: CGSize, _ body: (CGContext) -> Void) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        body(ctx)
        guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    static func linear(_ ctx: CGContext, _ colors: [CGColor], _ stops: [CGFloat], from: CGPoint, to: CGPoint, extend: Bool = true) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: stops)!
        ctx.drawLinearGradient(g, start: from, end: to, options: extend ? [.drawsBeforeStartLocation, .drawsAfterEndLocation] : [])
    }

    static func glow(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ color: UInt32, _ alpha: CGFloat, sy: CGFloat = 1) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: sy)
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(color, alpha), rgb(color, alpha * 0.45), rgb(color, 0)] as CFArray, locations: [0, 0.4, 1])!
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    struct Noise {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
    }

    static func grain(_ ctx: CGContext, _ size: CGSize, amount: CGFloat) {
        var n = Noise(state: 99)
        for _ in 0..<Int(size.width * size.height / 30) {
            let v = n.next()
            ctx.setFillColor(gray: v > 0.5 ? 1 : 0, alpha: amount * n.next())
            ctx.fill(CGRect(x: n.next() * size.width, y: n.next() * size.height, width: 2, height: 2))
        }
        // A lens's falloff.
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0, 0), rgb(0, 0), rgb(0, 0.38)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: hypot(size.width, size.height) / 2, options: [.drawsAfterEndLocation])
    }

    static func ridge(_ ctx: CGContext, _ size: CGSize, base: CGFloat, rough: CGFloat, seed: UInt64, color: CGColor) {
        var n = Noise(state: seed)
        var pts = [CGFloat](repeating: 0, count: 257)
        pts[0] = (n.next() - 0.5) * rough
        pts[256] = (n.next() - 0.5) * rough
        var step = 256, scale = rough
        while step > 1 {
            let half = step / 2
            var i = half
            while i < 256 { pts[i] = (pts[i - half] + pts[i + half]) / 2 + (n.next() - 0.5) * scale; i += step }
            step = half
            scale *= 0.55
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        for (i, v) in pts.enumerated() { path.addLine(to: CGPoint(x: CGFloat(i) / 256 * size.width, y: base + v)) }
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    static func sunset(_ ctx: CGContext, _ s: CGSize) {
        let horizon = s.height * 0.42
        linear(ctx, [rgb(0x182454), rgb(0x5a3f86), rgb(0xd9745a), rgb(0xffc98e)], [0, 0.45, 0.82, 1],
               from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: horizon))
        for (x, y, r, a) in [(0.2, 0.83, 380.0, 0.22), (0.7, 0.75, 460.0, 0.18), (0.45, 0.66, 300.0, 0.2)] {
            glow(ctx, CGPoint(x: s.width * x, y: s.height * y), r, 0xffb3a0, a, sy: 0.22)
        }
        let sun = CGPoint(x: s.width * 0.6, y: horizon + 150)
        glow(ctx, sun, 900, 0xffb070, 0.55)
        glow(ctx, sun, 170, 0xfff1d0, 1)
        ctx.setFillColor(rgb(0xfff6e2))
        ctx.fillEllipse(in: CGRect(x: sun.x - 72, y: sun.y - 72, width: 144, height: 144))
        // The sea, and the sun's path on it.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: s.width, height: horizon))
        linear(ctx, [rgb(0x2c3a6c), rgb(0x1a2347), rgb(0x0b1026)], [0, 0.4, 1], from: CGPoint(x: 0, y: horizon), to: .zero)
        var n = Noise(state: 7)
        for _ in 0..<900 {
            let depth = n.next()
            let y = horizon - pow(depth, 1.6) * horizon
            let spread = 40 + depth * 520
            let x = sun.x + (n.next() - 0.5) * 2 * spread * (0.3 + n.next())
            let w = 20 + depth * 140 * n.next()
            let a = (1 - abs(x - sun.x) / (spread * 1.3)) * (0.9 - depth * 0.5)
            guard a > 0 else { continue }
            ctx.setFillColor(rgb(n.next() > 0.3 ? 0xffd9a0 : 0xffffff, a * 0.8))
            ctx.fill(CGRect(x: x - w / 2, y: y, width: w, height: 2 + depth * 7))
        }
        ctx.restoreGState()
        glow(ctx, CGPoint(x: sun.x, y: horizon * 0.55), 520, 0xffb070, 0.28, sy: 0.25)
    }

    static func ridges(_ ctx: CGContext, _ s: CGSize) {
        linear(ctx, [rgb(0x0c1633), rgb(0x34478a), rgb(0xc98aa8), rgb(0xf3c0a0)], [0, 0.5, 0.85, 1],
               from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: s.height * 0.38))
        var n = Noise(state: 12)
        for _ in 0..<160 {
            let y = s.height * (0.7 + 0.3 * n.next())
            ctx.setFillColor(rgb(0xffffff, 0.3 + 0.6 * n.next()))
            let r = 1.5 + 2.5 * n.next()
            ctx.fillEllipse(in: CGRect(x: n.next() * s.width, y: y, width: r, height: r))
        }
        glow(ctx, CGPoint(x: s.width * 0.3, y: s.height * 0.45), 800, 0xffc0a0, 0.45, sy: 0.5)
        let layers: [(CGFloat, CGFloat, UInt32)] = [(0.52, 260, 0x8e86b6), (0.46, 230, 0x6a6596), (0.39, 200, 0x494775),
                                                    (0.31, 180, 0x2e2d52), (0.22, 150, 0x1b1a34), (0.12, 120, 0x0d0c1c)]
        for (i, (base, rough, color)) in layers.enumerated() {
            ridge(ctx, s, base: s.height * base, rough: rough, seed: UInt64(20 + i), color: rgb(color))
            // Haze in the valleys.
            linear(ctx, [rgb(0xf0b8b0, 0.0), rgb(0xf0b8b0, 0.16)], [0, 1],
                   from: CGPoint(x: 0, y: s.height * base + 60), to: CGPoint(x: 0, y: s.height * base - 120), extend: false)
        }
    }

    static func bokeh(_ ctx: CGContext, _ s: CGSize) {
        linear(ctx, [rgb(0x0c0a18), rgb(0x1d1126), rgb(0x2a1420)], [0, 0.6, 1], from: CGPoint(x: 0, y: s.height), to: .zero)
        var n = Noise(state: 5)
        let colors: [UInt32] = [0xffb347, 0xff7a45, 0xffd28a, 0xff4f6b, 0x6fd3ff, 0xffffff, 0xffa060]
        ctx.setBlendMode(.screen)
        for i in 0..<170 {
            let far = i < 110
            let r = far ? 18 + 40 * n.next() : 70 + 120 * n.next()
            let c = CGPoint(x: n.next() * s.width, y: s.height * (0.15 + 0.7 * n.next()))
            let color = colors[Int(n.next() * CGFloat(colors.count)) % colors.count]
            let a = (far ? 0.5 : 0.22) * (0.4 + 0.6 * n.next())
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(color, a * 0.7), rgb(color, a * 0.85), rgb(color, a), rgb(color, 0)] as CFArray,
                               locations: [0, 0.75, 0.93, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
        ctx.setBlendMode(.normal)
        // A wet street's reflection under it.
        linear(ctx, [rgb(0x000000, 0), rgb(0x000000, 0.55)], [0, 1], from: CGPoint(x: 0, y: s.height * 0.3), to: .zero, extend: false)
    }

    static func lake(_ ctx: CGContext, _ s: CGSize) {
        let horizon = s.height * 0.46
        linear(ctx, [rgb(0x7fa6c6), rgb(0xc9d8e2), rgb(0xf6e3cc)], [0, 0.7, 1], from: CGPoint(x: 0, y: s.height), to: CGPoint(x: 0, y: horizon))
        glow(ctx, CGPoint(x: s.width * 0.7, y: horizon + 60), 700, 0xfff0d8, 0.7, sy: 0.5)
        // The far shore and its trees, then their reflection.
        func shore(_ mirror: Bool) {
            ctx.saveGState()
            if mirror { ctx.translateBy(x: 0, y: 2 * horizon); ctx.scaleBy(x: 1, y: -1) }
            ridge(ctx, s, base: horizon + 70, rough: 60, seed: 41, color: rgb(0x6f8796, mirror ? 0.55 : 1))
            var n = Noise(state: 9)
            var x: CGFloat = -20
            while x < s.width + 20 {
                let h = 120 + 260 * n.next(), w = h * (0.28 + 0.1 * n.next())
                let path = CGMutablePath()
                path.move(to: CGPoint(x: x - w / 2, y: horizon - 2))
                path.addLine(to: CGPoint(x: x, y: horizon + h))
                path.addLine(to: CGPoint(x: x + w / 2, y: horizon - 2))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(rgb(n.next() > 0.5 ? 0x1f3a33 : 0x26443a, mirror ? 0.6 : 1))
                ctx.fillPath()
                x += w * (0.35 + 0.4 * n.next())
            }
            ctx.restoreGState()
        }
        shore(false)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: s.width, height: horizon))
        linear(ctx, [rgb(0xb8cad6), rgb(0x5d7d93), rgb(0x2b4252)], [0, 0.5, 1], from: CGPoint(x: 0, y: horizon), to: .zero)
        shore(true)
        var n = Noise(state: 77)
        for _ in 0..<500 {
            let y = n.next() * horizon
            ctx.setFillColor(rgb(0xffffff, 0.05 + 0.12 * n.next()))
            ctx.fill(CGRect(x: n.next() * s.width, y: y, width: 40 + 260 * n.next(), height: 1.5 + 2 * n.next()))
        }
        ctx.restoreGState()
        // Morning mist on the water line.
        linear(ctx, [rgb(0xffffff, 0), rgb(0xffffff, 0.35), rgb(0xffffff, 0)], [0, 0.5, 1],
               from: CGPoint(x: 0, y: horizon + 90), to: CGPoint(x: 0, y: horizon - 90), extend: false)
    }

    /// A dark abstract wallpaper and the menu bar beside the notch: no menus, no names.
    static func desktop(_ ctx: CGContext, _ s: CGSize) {
        linear(ctx, [rgb(0x0a0d1a), rgb(0x0d0b18), rgb(0x07080f)], [0, 0.5, 1], from: CGPoint(x: 0, y: s.height), to: CGPoint(x: s.width, y: 0))
        glow(ctx, CGPoint(x: s.width * 0.18, y: s.height * 0.72), s.width * 0.55, 0x1b2d63, 0.9, sy: 0.7)
        glow(ctx, CGPoint(x: s.width * 0.82, y: s.height * 0.25), s.width * 0.5, 0x3a1b58, 0.75, sy: 0.75)
        glow(ctx, CGPoint(x: s.width * 0.55, y: s.height * 0.95), s.width * 0.4, 0x0e3a4a, 0.6, sy: 0.6)
        // Two soft folds of light across it.
        for (k, color, a) in [(0.0, UInt32(0x4a5fbf), 0.16), (0.12, UInt32(0x8a4fbf), 0.12)] as [(CGFloat, UInt32, CGFloat)] {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -100, y: s.height * (0.35 + k)))
            path.addCurve(to: CGPoint(x: s.width + 100, y: s.height * (0.55 + k)),
                          control1: CGPoint(x: s.width * 0.35, y: s.height * (0.75 + k)), control2: CGPoint(x: s.width * 0.6, y: s.height * (0.15 + k)))
            ctx.saveGState()
            ctx.setBlendMode(.screen)
            for w in stride(from: 260.0, to: 10, by: -25) {
                ctx.addPath(path)
                ctx.setLineWidth(w)
                ctx.setStrokeColor(rgb(color, a * 0.12))
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        grain(ctx, s, amount: 0.02)
        // Menu bar: the bar, the notch, the clock and two status symbols.
        let scale = s.width / PromoCapture.screen.width
        let bar = PromoCapture.menuBar * scale
        ctx.setFillColor(rgb(0x000000, 0.28))
        ctx.fill(CGRect(x: 0, y: s.height - bar, width: s.width, height: bar))
        let notch = CGRect(x: s.width / 2 - 92 * scale, y: s.height - 32 * scale, width: 184 * scale, height: 32 * scale)
        ctx.addPath(CGPath(roundedRect: notch.insetBy(dx: 0, dy: -12 * scale).offsetBy(dx: 0, dy: 12 * scale),
                           cornerWidth: 10 * scale, cornerHeight: 10 * scale, transform: nil))
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let font = NSFont.systemFont(ofSize: 13 * scale, weight: .medium)
        let clock = NSAttributedString(string: "Thu 12 Nov  9:41", attributes: [.font: font, .foregroundColor: NSColor.white])
        let clockSize = clock.size()
        let midY = s.height - bar / 2
        var x = s.width - 14 * scale - clockSize.width
        clock.draw(at: CGPoint(x: x, y: midY - clockSize.height / 2))
        for name in ["wifi", "battery.75percent"] {
            let config = NSImage.SymbolConfiguration(pointSize: 14 * scale, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { continue }
            x -= symbol.size.width + 16 * scale
            symbol.draw(in: CGRect(x: x, y: midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
