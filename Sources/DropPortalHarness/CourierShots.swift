//
//  CourierShots.swift
//  DropPortalHarness
//
//  `--courier-shots <dir> [courier]` (debug builds): every courier, or the one
//  named (`cheek` or `pip`, `pounce`/`tofu`, `mole`/`digby`, `ducks`/`matcha`),
//  light and dark. The Mac at waiting, arrival, landing and after (CourierShots
//  in the droplet), then the phone: the page's courier script in one offscreen
//  WKWebView at 393 × 852, `DPCourier.still` at hold (p 0.6), leap (35% of the
//  way to a clear edge) and exit (85%). `<courier>-<mac|phone>-<instant>-<light|dark>.png`.
//

#if DEBUG
import AppKit
import DropPortal
import DropPortalCore
import WebKit

@MainActor
final class CourierPhoneShots: NSObject, WKNavigationDelegate {
    static func run(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--courier-shots"), args.indices.contains(i + 1) else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: args[i + 1])
        let name = args.indices.contains(i + 2) ? args[i + 2] : nil
        let only = CourierShots.couriers(named: name)
        guard !only.isEmpty else {
            FileHandle.standardError.write("courier shots: no courier named \(name ?? "")\n".data(using: .utf8)!)
            exit(2)
        }
        Task { @MainActor in
            do {
                var urls = try CourierShots.writeMac(to: dir, only: only)
                urls += try await CourierPhoneShots(dir: dir).all(only)
                urls.forEach { print($0.path) }
                print("\(urls.count) courier shots in \(dir.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write("courier shots: \(error)\n".data(using: .utf8)!)
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
    private static let size = CGSize(width: 393, height: 852)

    init(dir: URL) { self.dir = dir }

    func all(_ couriers: [Courier]) async throws -> [URL] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: Self.size.width, height: Self.size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        var urls: [URL] = []
        for light in [true, false] {
            await load(light: light)
            for courier in couriers {
                let clear = courier.phoneClearMS
                for (name, phase, x) in [("hold", "hold", 0.6), ("leap", "leap", clear * 0.35), ("exit", "leap", clear * 0.85)] {
                    // The real card shows while it is held; after the release only the courier's copy.
                    let drawn = try await js("""
                        document.getElementById('card').style.visibility = '\(phase == "hold" ? "visible" : "hidden")';
                        DPCourier.still('\(courier.rawValue)', '\(phase)', \(x), document.getElementById('card').getBoundingClientRect(), 7)
                        """) as? Bool ?? false
                    if !drawn { print("\(courier.rawValue) \(name): the courier drew nothing") }
                    let url = dir.appendingPathComponent("\(courier.rawValue)-phone-\(name)-\(light ? "light" : "dark").png")
                    try await snapshot(to: url)
                    urls.append(url)
                }
            }
        }
        return urls
    }

    /// A phone-sized page: the background, one card dragged most of the way to the left edge, the courier script.
    private func load(light: Bool) async {
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=393">
            <style>html,body{margin:0;width:393px;height:852px;overflow:hidden;background:\(light ? "#f2f2f7" : "#000")}
            .card{position:absolute;left:58px;top:330px;width:150px;height:186px;border-radius:14px;background:#fbf8f2;
            box-shadow:0 10px 30px rgba(0,0,0,.3);transform:rotate(-2deg)}
            .card::after{content:"";position:absolute;inset:8px 8px 30px;border-radius:9px;background:linear-gradient(#ffc59a,#5fb3c1 55%,#ffe0a8)}</style>
            </head><body><div class="card" id="card"></div>\(WebCourierEffect.block)</body></html>
            """
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loaded = c
            webView.loadHTMLString(html, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.loaded?.resume(); self?.loaded = nil }
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
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
}
#endif
