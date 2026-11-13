//
//  PhoneShots.swift
//  DropPortalHarness
//
//  `--phone-shots <dir> [effect] [css|gl|gl-rainbow|gl-send|sent]` (debug builds):
//  the real phone page in an offscreen WKWebView at 393 × 852 on the promo
//  capture's virtual clock, a card dragged to p .6 off the left edge:
//  `<effect>-css.png` with WebGL taken away (the fallback, today's look),
//  `<effect>-gl.png`, `-gl-rainbow.png`, `-gl-send.png` 60 ms into the impact,
//  Stardust and Lightning also `-sky-<ms>.png` that long after the release,
//  `<effect>-sent.png` the "Sent" line's kinetic name 200 ms in (the upload is real),
//  and `perf-<effect>.json` with the shader's cost per frame at the page's own
//  canvas size. One shot per process is the reliable way: a process that
//  makes several web views in a row sometimes stops getting answers.
//

#if DEBUG
import AppKit
import DropPortalCore
import WebKit

@MainActor
final class PhoneShots: NSObject, WKNavigationDelegate {
    static func run(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--phone-shots"), args.indices.contains(i + 1) else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await PhoneShots(dir: URL(fileURLWithPath: args[i + 1])).all()
                exit(0)
            } catch {
                FileHandle.standardError.write("phone shots: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        app.run()
        exit(0)
    }

    let dir: URL
    private var webView: WKWebView!
    private var window: NSWindow!
    private var loaded: CheckedContinuation<Void, Never>?

    init(dir: URL) { self.dir = dir }

    /// Keeps a real clock for the bench, and (`noGL`) takes WebGL away as on a phone without it.
    static func preScript(noGL: Bool) -> String {
        """
        window.__realNow = performance.now.bind(performance);
        \(noGL ? "(function(){ var g = HTMLCanvasElement.prototype.getContext; HTMLCanvasElement.prototype.getContext = function(t){ return /webgl/.test(t) ? null : g.apply(this, arguments); }; })();" : "")
        """
    }

    func all() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let assets = fm.temporaryDirectory.appendingPathComponent("dropportal-phone-assets")
        if !fm.fileExists(atPath: assets.appendingPathComponent("City lights.jpg").path) { try PromoAssets.write(to: assets) }
        let received = fm.temporaryDirectory.appendingPathComponent("dropportal-phone-received-\(UUID().uuidString)")
        try fm.createDirectory(at: received, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: received) }

        let port = UInt16(18_000 + Int.random(in: 800...899))
        let server = DropPortalServer(port: port, destination: received, outbox: received.appendingPathComponent("outbox"))
        server.token = PairingToken.generate()
        server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 400_000_000)
        let url = URL(string: "http://127.0.0.1:\(port)/?t=\(server.token)")!

        let effects = ["portal", "liquid", "wormhole", "beam", "plane", "stardust", "lightning"]
        let args = CommandLine.arguments
        let only = args.first { effects.contains($0) }.map { [$0] }
        let variant = args.first { ["css", "gl", "gl-rainbow", "gl-send", "sent"].contains($0) || $0.hasPrefix("sky-") }
        var perf: [String: Any] = [:]
        for effect in only ?? effects {
            let tint = PortalTint.defaultTint(for: PortalEffect(stored: effect)).stored
            var runs: [(String, Bool, String, Bool)] = [("css", false, tint, false), ("gl", true, tint, false),
                                                        ("gl-rainbow", true, "rainbow", false), ("gl-send", true, tint, true),
                                                        ("sent", false, tint, true)]
            // Stardust and Lightning: stills after the release (WebSkyEffect.swift); "-nogl" is the Canvas2D fallback.
            if effect == "stardust" { runs += ["sky-40", "sky-250", "sky-500", "sky-800", "sky-250-nogl"].map { ($0, !$0.hasSuffix("nogl"), tint, true) } }
            if effect == "lightning" { runs += ["sky-30", "sky-70", "sky-150", "sky-70-red"].map { ($0, true, $0.hasSuffix("red") ? "#FF0000" : tint, true) } }
            for (name, gl, shotTint, send) in runs {
                if let variant, variant != name { continue }
                // The kinetic name only when asked for: it waits for a real upload.
                if variant == nil, name == "sent" { continue }
                let file = dir.appendingPathComponent("\(effect)-\(name).png")
                // A web content process now and then dies after many views: one more try.
                let result: [String: Any]
                let after = name.hasPrefix("sky-") ? Double(name.split(separator: "-")[1]) : nil
                let sent = name == "sent" ? 0.2 : nil
                do { result = try await shot(url: url, effect: effect, tint: shotTint, gl: gl, send: send, after: after, sentAt: sent, to: file) }
                catch { result = try await shot(url: url, effect: effect, tint: shotTint, gl: gl, send: send, after: after, sentAt: sent, to: file) }
                if name == "gl" { perf[effect] = result }
                print("\(effect)-\(name): \(result)")
            }
        }
        if !perf.isEmpty {
            let name = only.map { "perf-\($0[0]).json" } ?? "perf.json"
            try JSONSerialization.data(withJSONObject: perf, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent(name))
        }
    }

    private func shot(url: URL, effect: String, tint: String, gl: Bool, send: Bool, after: Double? = nil, sentAt: Double? = nil,
                      to file: URL) async throws -> [String: Any] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.preScript(noGL: !gl), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: PhoneCapture.clockScript(effect: effect, tint: tint), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: PhoneCapture.safeAreaScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // The first-visit tour would cover the page.
        controller.addUserScript(WKUserScript(source: "try { localStorage.setItem('dropportal.tour.v2', '1'); } catch (e) {}", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller
        let size = PhoneCapture.size
        webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.evaluateJavaScript("window.DropPortalGL && DropPortalGL.dispose(); 0", completionHandler: nil)
            window.orderOut(nil); window.contentView = nil
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loaded = c
            webView.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.loaded?.resume(); self?.loaded = nil }
        }
        try await pump(0.4)
        try await addFiles(["Golden hour.jpg", "Ridge at dusk.jpg", "City lights.jpg", "Lake at dawn.jpg"])

        // Card 1 (right column) dragged left to p .6 over 24 frames.
        let json = try await js("""
            (function(){ var c = document.querySelectorAll('#grid .card')[1]; var r = c.getBoundingClientRect();
              return JSON.stringify([r.left + r.width / 2, r.top + r.height / 2, Math.max(40, r.left + r.width * 0.35)]); })()
            """) as? String ?? "[]"
        let a = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Double] ?? [290, 400, 270]
        let (x0, y0, reach) = (a[0], a[1], a[2])
        _ = try await js("__V.pointer('pointerdown', \(x0), \(y0))")
        let frames = 24
        for f in 1...frames {
            let k = Double(f) / Double(frames)
            _ = try await js("__V.pointer('pointermove', \(x0 - 0.6 * reach * k), \(y0 - 30 * k)); __V.step(16.7)")
        }
        try await pump(0.2)
        var result: [String: Any] = [:]
        let on = try await js("document.documentElement.classList.contains('gl')") as? Bool ?? false
        result["gl"] = on
        if gl, on {
            let c = try await js("(function(){ var c = document.querySelector('canvas.fxgl'); return c ? [c.width, c.height] : [0, 0]; })()") as? [Int] ?? []
            result["canvas"] = c
            // Warm up, then the median of five runs of 60 frames.
            _ = try await js("DropPortalGL.bench(10, window.__realNow)")
            var runs: [Double] = []
            for _ in 0..<5 { runs.append(try await js("DropPortalGL.bench(60, window.__realNow)") as? Double ?? -1) }
            runs.sort()
            result["msPerFrame"] = (runs[2] * 1000).rounded() / 1000
            // The bench drew at the last p; draw the held frame again for the shot.
            _ = try await js("__V.pointer('pointermove', \(x0 - 0.6 * reach), \(y0 - 30)); __V.step(16.7)")
        }
        if send {
            let x = x0 - 0.6 * reach - 40
            _ = try await js("__V.pointer('pointermove', \(x), \(y0 - 30)); __V.step(8); __V.pointer('pointerup', \(x), \(y0 - 30))")
            if let after {
                // That many ms after the release, in 8 ms frames.
                for _ in 0..<Int(after / 8) { _ = try await js("__V.step(8)") }
            }
            // Step to the impact, then 60 ms into it.
            for _ in 0..<(after == nil ? 90 : 0) {
                _ = try await js("__V.step(8)")
                if (try await js("document.querySelector('.portal').classList.contains('flash')") as? Bool) == true { break }
            }
            if after == nil { for _ in 0..<4 { _ = try await js("__V.step(15)") } }
        }
        if let sentAt {
            // The upload is real: wait for "Sent", then step the page's clock into the name.
            for _ in 0..<200 {
                _ = try await js("__V.step(16.7)")
                if (try await js("!!document.querySelector('#grid .card.sent .kname')") as? Bool) == true { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            for _ in 0..<Int(sentAt * 1000 / 10) { _ = try await js("__V.step(10)") }
            result["kname"] = try await js("(function(){ var k = document.querySelector('#grid .card.sent .kname'); return k ? k.textContent : ''; })()") as? String ?? ""
        }
        try await pump(0.15)
        try await snapshot(to: file)
        result["errors"] = try await js("JSON.stringify(__V.errors)") as? String ?? ""
        return result
    }

    private func addFiles(_ names: [String]) async throws {
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent("dropportal-phone-assets")
        var items: [String] = []
        for (i, name) in names.enumerated() {
            let data = try Data(contentsOf: assets.appendingPathComponent(name))
            items.append(#"{"name":"IMG_\#(2041 + i).JPG","type":"image/jpeg","b64":"\#(data.base64EncodedString())"}"#)
        }
        _ = try await js("__V.addFiles([\(items.joined(separator: ","))]); 0")
        for _ in 0..<120 {
            _ = try await js("__V.step(0)")
            let n = try await js("Array.prototype.filter.call(document.querySelectorAll('#grid .card'), function(c){ return !!c._thumb && c._thumb.length > 3000; }).length") as? Int ?? 0
            if n >= names.count { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await pump(0.3)
    }

    private func pump(_ seconds: Double) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            _ = try await js("__V.step(0)")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @discardableResult
    private func js(_ source: String) async throws -> Any? {
        // A web view that stops answering fails the shot (and its one retry) instead of hanging the run.
        let view = webView!
        return try await withThrowingTaskGroup(of: Box.self) { group in
            group.addTask { @MainActor in Box(value: try await view.evaluateJavaScript(source)) }
            group.addTask { try await Task.sleep(nanoseconds: 15_000_000_000); throw CocoaError(.userCancelled) }
            let first = try await group.next()!
            group.cancelAll()
            return first.value
        }
    }

    private struct Box: @unchecked Sendable { let value: Any? }

    private func snapshot(to url: URL) async throws {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: Double(PhoneCapture.size.width) * 1.5)
        let image = try await webView.takeSnapshot(configuration: config)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
        try PromoAssets.writePNG(cg, to: url)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
}
#endif
