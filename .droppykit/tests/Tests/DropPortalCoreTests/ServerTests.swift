import Foundation
@testable import DropPortalCore
import XCTest

/// Runs the real server on a spare loopback port.
final class ServerTests: XCTestCase {
    private var server: DropPortalServer!
    private var folder: URL!
    private let port: UInt16 = 18787
    private var base: String { "http://127.0.0.1:\(port)" }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("portal-\(UUID().uuidString)")
        var limits = DropPortalServer.Limits()
        limits.maxUpload = 1024
        server = DropPortalServer(port: port, destination: folder, limits: limits)
        server.token = "good-token"
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func request(_ path: String, method: String = "GET", headers: [String: String] = [:],
                         body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func testStateRoundTrips() {
        let states: [DropPortalServer.State] = [.stopped, .starting, .ready,
                                                .waiting("No network"), .failed("Port in use: by x")]
        for state in states { XCTAssertEqual(DropPortalServer.State(encoded: state.encoded), state) }
        XCTAssertEqual(DropPortalServer.State(encoded: "garbage"), .stopped)
    }

    /// Regression: the listener once went ready and then failed a millisecond
    /// later (a refused Bonjour advertisement), and the pane showed "Stopped".
    func testStaysReady() async throws {
        let changed = expectation(description: "no state change after ready")
        changed.isInverted = true
        server.onState = { _ in changed.fulfill() }
        await fulfillment(of: [changed], timeout: 0.5)
        server.onState = nil
        let (status, _) = try await request("/?t=good-token")
        XCTAssertEqual(status, 200)
    }

    /// The Home Screen icon is only the logo, so it needs no token.
    func testTouchIconIsPublicPNG() async throws {
        let (status, png) = try await request("/apple-touch-icon.png")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testManifestIsPublicAndStatic() async throws {
        let (status, body) = try await request("/manifest.webmanifest")
        XCTAssertEqual(status, 200)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"standalone\""))
        XCTAssertTrue(text.contains("/apple-touch-icon.png"))
        XCTAssertFalse(text.contains("good-token"))
    }

    func testPageNeedsToken() async throws {
        let (missing, _) = try await request("/")
        XCTAssertEqual(missing, 403)
        let (wrong, _) = try await request("/?t=bad")
        XCTAssertEqual(wrong, 403)
        let (ok, page) = try await request("/?t=good-token")
        XCTAssertEqual(ok, 200)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("Flick them off the left edge"))
        XCTAssertTrue(html.contains("Mac not reachable - same Wi-Fi?"))
        XCTAssertFalse(html.contains("Paste from clipboard"))
        XCTAssertFalse(html.contains("relay"))
        // The portal light, with a calm version for Reduce motion.
        XCTAssertTrue(html.contains("id=\"portal\""))
        XCTAssertTrue(html.contains("prefers-reduced-motion"))
        XCTAssertTrue(html.contains(#"data-effect="portal""#))
    }

    func testShortcutNeedsTokenAndWaitsUntilSigned() async throws {
        let (missing, _) = try await request("/shortcut")
        XCTAssertEqual(missing, 403)
        let (notYet, _) = try await request("/shortcut?t=good-token")
        XCTAssertEqual(notYet, 503)
        server.setShortcut(Data("signed".utf8), for: .share)
        let (wrong, _) = try await request("/shortcut?t=bad")
        XCTAssertEqual(wrong, 403)
        let (ok, file) = try await request("/shortcut?t=good-token")
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(file, Data("signed".utf8))
        let (page, html) = try await request("/?t=good-token")
        XCTAssertEqual(page, 200)
        let text = String(decoding: html, as: UTF8.self)
        XCTAssertTrue(text.contains("iPhone Shortcuts"))
        for kind in PhoneShortcut.allCases {
            XCTAssertTrue(text.contains(#"data-shortcut="\#(kind.path)""#), kind.rawValue)
            XCTAssertTrue(text.contains(kind.title), kind.rawValue)
        }
        XCTAssertFalse(text.contains("<!--shortcut-rows-->"))
    }

    func testEveryPhoneShortcutNeedsTokenAndIsServedOnItsOwnPath() async throws {
        for kind in PhoneShortcut.allCases where kind != .share {
            let (missing, _) = try await request(kind.path)
            XCTAssertEqual(missing, 403, kind.rawValue)
            let (wrong, _) = try await request("\(kind.path)?t=bad")
            XCTAssertEqual(wrong, 403, kind.rawValue)
            let (notYet, _) = try await request("\(kind.path)?t=good-token")
            XCTAssertEqual(notYet, 503, kind.rawValue)
        }
        for kind in PhoneShortcut.allCases { server.setShortcut(Data(kind.rawValue.utf8), for: kind) }
        for kind in PhoneShortcut.allCases {
            let (ok, file) = try await request("\(kind.path)?t=good-token")
            XCTAssertEqual(ok, 200, kind.rawValue)
            XCTAssertEqual(file, Data(kind.rawValue.utf8), kind.rawValue)
        }
        let (unknown, _) = try await request("/shortcut/nope?t=good-token")
        XCTAssertEqual(unknown, 404)
        // A new token drops them all until they are signed again.
        server.clearShortcuts()
        let (cleared, _) = try await request("/shortcut/clipboard?t=good-token")
        XCTAssertEqual(cleared, 503)
    }

    func testPageServesTheChosenEffect() async throws {
        server.setEffect(.beam, tint: .lime)
        let (status, page) = try await request("/?t=good-token")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains(##"<html lang="en" data-effect="beam" data-tint="#6BFF1F">"##))
    }

    func testUploadSavesSanitizedUniqueFile() async throws {
        let received = expectation(description: "file")
        received.expectedFulfillmentCount = 2
        server.onFile = { _, peek in
            XCTAssertNil(peek)
            received.fulfill()
        }
        let headers = ["X-DropPortal-Token": "good-token", "X-DropPortal-Name": "..%2F..%2Fevil.txt"]
        let (s1, _) = try await request("/upload", method: "POST", headers: headers, body: Data("hello".utf8))
        let (s2, _) = try await request("/upload", method: "POST", headers: headers, body: Data("again".utf8))
        XCTAssertEqual([s1, s2], [200, 200])
        await fulfillment(of: [received], timeout: 5)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["evil 2.txt", "evil.txt"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("evil.txt"), encoding: .utf8), "hello")
        XCTAssertNotNil(ReceivedFile.quarantineValue(folder.appendingPathComponent("evil.txt")), "quarantined")
    }

    func testUploadRefusals() async throws {
        let (noToken, _) = try await request("/upload", method: "POST", body: Data("x".utf8))
        XCTAssertEqual(noToken, 403)
        let big = Data(count: 2048)
        let (tooBig, _) = try await request("/upload", method: "POST",
                                            headers: ["X-DropPortal-Token": "good-token"], body: big)
        XCTAssertEqual(tooBig, 413)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testTextReachesHandler() async throws {
        let got = expectation(description: "text")
        server.onText = { text in
            XCTAssertEqual(text, "héllo")
            got.fulfill()
        }
        let (status, _) = try await request("/text", method: "POST", headers: ["X-DropPortal-Token": "good-token"],
                                            body: Data("héllo".utf8))
        XCTAssertEqual(status, 200)
        await fulfillment(of: [got], timeout: 5)
    }

    func testResetTokenLocksOutOldOne() async throws {
        server.token = "new-token"
        let (old, _) = try await request("/?t=good-token")
        XCTAssertEqual(old, 403)
    }

    func testUploadCarriesValidPeekIDOnly() async throws {
        let got = expectation(description: "files")
        got.expectedFulfillmentCount = 2
        let ids = Locked<[String?]>([])
        server.onFile = { _, peek in ids.mutate { $0.append(peek) }; got.fulfill() }
        for peek in ["p1-ab_C", "bad id\r\nX: y"] {
            let headers = ["X-DropPortal-Token": "good-token", "X-DropPortal-Name": "a.txt", "X-DropPortal-Peek": peek]
            _ = try? await request("/upload", method: "POST", headers: headers, body: Data("x".utf8))
        }
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(Set(ids.value.map { $0 ?? "nil" }), ["p1-ab_C", "nil"])
    }

    func testPageAllowsPeekSocketOnSameHost() async throws {
        var request = URLRequest(url: URL(string: base + "/?t=good-token")!)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        let csp = (response as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        XCTAssertTrue(csp.contains("connect-src 'self' ws://127.0.0.1:8788;"), csp)
        XCTAssertNil(WebPage.socketHost("evil\r\nx:1"))
        XCTAssertNil(WebPage.socketHost("a b"))
        XCTAssertEqual(WebPage.socketHost("192.168.1.5:8787"), "192.168.1.5")
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}
