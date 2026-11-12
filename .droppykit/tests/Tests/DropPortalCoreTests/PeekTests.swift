import Foundation
@testable import DropPortalCore
import XCTest

final class PeekMessageTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> PeekMessage {
        try PeekMessage.parse(JSONSerialization.data(withJSONObject: object))
    }

    func testParsesEveryType() throws {
        let thumb = Data([0xFF, 0xD8, 0xFF, 0x00])
        XCTAssertEqual(try parse(["type": "hello", "t": "tok"]), .hello(token: "tok"))
        XCTAssertEqual(try parse(["type": "peek-start", "id": "p1", "name": "../x/IMG 1.HEIC", "kind": "image",
                                  "size": 1234, "thumb": thumb.base64EncodedString()]),
                       .start(PeekInfo(id: "p1", name: "IMG 1.HEIC", kind: .image, size: 1234, thumb: thumb)))
        XCTAssertEqual(try parse(["type": "peek-move", "id": "p1", "progress": 0.5]), .move(id: "p1", progress: 0.5))
        XCTAssertEqual(try parse(["type": "peek-move", "id": "p1", "progress": 7]), .move(id: "p1", progress: 1))
        XCTAssertEqual(try parse(["type": "peek-progress", "id": "p1", "progress": -1]), .progress(id: "p1", progress: 0))
        XCTAssertEqual(try parse(["type": "peek-commit", "id": "p1"]), .commit(id: "p1"))
        XCTAssertEqual(try parse(["type": "peek-cancel", "id": "p1"]), .cancel(id: "p1"))
        // Unknown kind and missing fields fall back, never fail.
        XCTAssertEqual(try parse(["type": "peek-start", "id": "p2", "kind": "weird"]),
                       .start(PeekInfo(id: "p2", name: "file", kind: .file, size: 0)))
    }

    func testStackCountComesWithTheFirstPeekStart() throws {
        // A stack of selected cards: the Mac shows the count from the first message, capped at 99.
        XCTAssertEqual(try parse(["type": "peek-start", "id": "p3", "name": "a.jpg", "kind": "image", "size": 1, "count": 3]),
                       .start(PeekInfo(id: "p3", name: "a.jpg", kind: .image, size: 1, count: 3)))
        XCTAssertEqual(try parse(["type": "peek-start", "id": "p4", "count": 500]),
                       .start(PeekInfo(id: "p4", name: "file", kind: .file, size: 0, count: 99)))
        // The page sends the stack's size in its peek-start, gathered before it.
        XCTAssertTrue(WebPage.template.contains("peekStart(card, group.length)"))
        XCTAssertTrue(WebPage.template.contains("count: count || 1"))
    }

    func testRejectsBadJSONAndFields() {
        XCTAssertThrowsError(try PeekMessage.parse(Data("{not json".utf8))) { XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed) }
        XCTAssertThrowsError(try PeekMessage.parse(Data("[1,2]".utf8))) { XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed) }
        XCTAssertThrowsError(try parse(["id": "p1"])) { XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed) }
        XCTAssertThrowsError(try parse(["type": "hello"])) { XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed) }
        XCTAssertThrowsError(try parse(["type": "peek-nope", "id": "p1"])) { XCTAssertEqual($0 as? PeekMessage.ParseError, .unknownType) }
        XCTAssertThrowsError(try parse(["type": "peek-move", "id": "p1"])) { XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed) }
        XCTAssertThrowsError(try parse(["type": "peek-move", "id": "p1", "progress": "half"])) { XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed) }
        for id in ["", "has space", "line\r\nbreak", String(repeating: "a", count: 65), "ü"] {
            XCTAssertThrowsError(try parse(["type": "peek-commit", "id": id])) { XCTAssertEqual($0 as? PeekMessage.ParseError, .badID) }
        }
        XCTAssertThrowsError(try parse(["type": "peek-start", "id": "p1", "thumb": "%%%not base64"])) {
            XCTAssertEqual($0 as? PeekMessage.ParseError, .malformed)
        }
    }

    func testOnlyJPEGThumbsAreAccepted() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertThrowsError(try parse(["type": "peek-start", "id": "p1", "thumb": png.base64EncodedString()])) {
            XCTAssertEqual($0 as? PeekMessage.ParseError, .thumbNotJPEG)
        }
        // Two bytes of the magic are not enough, and FF D8 without the third FF is not a JPEG.
        for bytes: [UInt8] in [[0xFF, 0xD8], [0xFF, 0xD8, 0x00, 0x01]] {
            XCTAssertThrowsError(try parse(["type": "peek-start", "id": "p1", "thumb": Data(bytes).base64EncodedString()])) {
                XCTAssertEqual($0 as? PeekMessage.ParseError, .thumbNotJPEG)
            }
        }
        XCTAssertTrue(PeekMessage.isJPEG(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(PeekMessage.isJPEG(Data()))
    }

    func testRejectsOversizedThumbAndMessage() throws {
        let ok = Data([0xFF, 0xD8, 0xFF]) + Data(count: PeekMessage.maxThumbBytes - 3)
        XCTAssertNoThrow(try parse(["type": "peek-start", "id": "p1", "thumb": ok.base64EncodedString()]))
        let big = Data(count: PeekMessage.maxThumbBytes + 1)
        XCTAssertThrowsError(try parse(["type": "peek-start", "id": "p1", "thumb": big.base64EncodedString()])) {
            XCTAssertEqual($0 as? PeekMessage.ParseError, .thumbTooLarge)
        }
        let huge = Data(repeating: 0x20, count: PeekMessage.maxMessageBytes + 1)
        XCTAssertThrowsError(try PeekMessage.parse(huge)) { XCTAssertEqual($0 as? PeekMessage.ParseError, .tooLarge) }
    }
}

final class PeekTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func info(_ id: String) -> PeekInfo { PeekInfo(id: id, name: "a.jpg", kind: .image, size: 1) }

    func testIgnoresUnknownID() {
        var tracker = PeekTracker()
        XCTAssertNil(tracker.handle(.move(id: "x", progress: 0.3), now: t0), "no peek yet")
        _ = tracker.handle(.start(info("a")), now: t0)
        XCTAssertNil(tracker.handle(.move(id: "b", progress: 0.3), now: t0))
        XCTAssertNil(tracker.handle(.commit(id: "b"), now: t0))
        XCTAssertNil(tracker.handle(.cancel(id: "b"), now: t0))
        XCTAssertEqual(tracker.handle(.move(id: "a", progress: 0.3), now: t0), .move(id: "a", progress: 0.3))
    }

    func testNewStartReplacesOld() {
        var tracker = PeekTracker()
        _ = tracker.handle(.start(info("a")), now: t0)
        _ = tracker.handle(.commit(id: "a"), now: t0)
        XCTAssertEqual(tracker.handle(.start(info("b")), now: t0), .start(info("b")))
        XCTAssertEqual(tracker.currentID, "b")
        XCTAssertFalse(tracker.isCommitted)
        XCTAssertNil(tracker.handle(.progress(id: "a", progress: 0.5), now: t0))
    }

    func testCommitGatesMoveAndProgress() {
        var tracker = PeekTracker()
        _ = tracker.handle(.start(info("a")), now: t0)
        XCTAssertNil(tracker.handle(.progress(id: "a", progress: 0.5), now: t0), "no progress before commit")
        XCTAssertEqual(tracker.handle(.commit(id: "a"), now: t0), .commit(id: "a"))
        XCTAssertNil(tracker.handle(.move(id: "a", progress: 0.2), now: t0), "a stale move after commit")
        XCTAssertEqual(tracker.handle(.progress(id: "a", progress: 0.5), now: t0), .progress(id: "a", progress: 0.5))
    }

    func testAutoCancelsAfterSilence() {
        var tracker = PeekTracker(timeout: 3)
        _ = tracker.handle(.start(info("a")), now: t0)
        XCTAssertNil(tracker.expire(now: t0.addingTimeInterval(2.9)))
        // Any message for the peek keeps it alive.
        _ = tracker.handle(.move(id: "a", progress: 0.1), now: t0.addingTimeInterval(2.9))
        XCTAssertNil(tracker.expire(now: t0.addingTimeInterval(5.8)))
        // A message for another id does not.
        _ = tracker.handle(.move(id: "z", progress: 0.1), now: t0.addingTimeInterval(5.8))
        XCTAssertEqual(tracker.expire(now: t0.addingTimeInterval(5.9)), .cancel(id: "a"))
        XCTAssertNil(tracker.currentID)
        XCTAssertNil(tracker.expire(now: t0.addingTimeInterval(100)), "cancelled once")
    }

    func testFinishEndsWithoutCancel() {
        var tracker = PeekTracker(timeout: 3)
        _ = tracker.handle(.start(info("a")), now: t0)
        _ = tracker.handle(.commit(id: "a"), now: t0)
        tracker.finish(id: "other")
        XCTAssertEqual(tracker.currentID, "a")
        tracker.finish(id: "a")
        XCTAssertNil(tracker.expire(now: t0.addingTimeInterval(10)))
    }
}

/// The real socket on a spare loopback port.
final class PeekChannelTests: XCTestCase {
    private var channel: PeekChannel!
    private let port: UInt16 = 18788

    override func setUp() async throws {
        channel = PeekChannel(port: port, timeout: 0.6)
        channel.token = "good-token"
        let ready = expectation(description: "ready")
        channel.onReady = { if $0 { ready.fulfill() } }
        channel.start()
        await fulfillment(of: [ready], timeout: 5)
        channel.onReady = nil
    }

    override func tearDown() async throws {
        channel.onEvent = nil
        channel.stop()
    }

    private func socket() -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
        task.resume()
        return task
    }

    private func send(_ task: URLSessionWebSocketTask, _ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func testWrongTokenClosesSocket() async throws {
        let events = expectation(description: "no event")
        events.isInverted = true
        channel.onEvent = { _ in events.fulfill() }
        let task = socket()
        try await send(task, ["type": "hello", "t": "bad-token"])
        try? await send(task, ["type": "peek-start", "id": "p1", "name": "a.jpg"])
        do {
            _ = try await task.receive()
            XCTFail("the socket should be closed")
        } catch {}
        XCTAssertEqual(task.closeCode, .policyViolation)
        await fulfillment(of: [events], timeout: 0.5)
    }

    func testPeekBeforeHelloClosesSocket() async throws {
        let task = socket()
        try await send(task, ["type": "peek-start", "id": "p1"])
        do {
            _ = try await task.receive()
            XCTFail("the socket should be closed")
        } catch {}
    }

    func testGoodTokenDeliversEventsAndAutoCancels() async throws {
        let got = Locked<[PeekEvent]>([])
        let cancelled = expectation(description: "auto-cancel")
        channel.onEvent = { event in
            got.mutate { $0.append(event) }
            if case .cancel = event { cancelled.fulfill() }
        }
        let task = socket()
        try await send(task, ["type": "hello", "t": "good-token"])
        guard case .string(let reply) = try await task.receive() else { return XCTFail("no ready") }
        XCTAssertTrue(reply.contains("ready"))
        try await send(task, ["type": "peek-start", "id": "p1", "name": "a.jpg", "kind": "image", "size": 9])
        try await send(task, ["type": "peek-move", "id": "nope", "progress": 0.4])
        try await send(task, ["type": "peek-move", "id": "p1", "progress": 0.4])
        // Silence: the channel cancels by itself after its 0.6 s timeout.
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(got.value, [
            .start(PeekInfo(id: "p1", name: "a.jpg", kind: .image, size: 9)),
            .move(id: "p1", progress: 0.4),
            .cancel(id: "p1"),
        ])
        task.cancel(with: .normalClosure, reason: nil)
    }

    func testChangingTheTokenClosesAuthenticatedSockets() async throws {
        let task = socket()
        try await send(task, ["type": "hello", "t": "good-token"])
        guard case .string(let reply) = try await task.receive() else { return XCTFail("no ready") }
        XCTAssertTrue(reply.contains("ready"))
        channel.token = "new-token"
        do {
            _ = try await task.receive()
            XCTFail("the old pairing's socket should be closed")
        } catch {}
        // The new token works on a fresh socket.
        let again = socket()
        try await send(again, ["type": "hello", "t": "new-token"])
        guard case .string(let ok) = try await again.receive() else { return XCTFail("no ready") }
        XCTAssertTrue(ok.contains("ready"))
        again.cancel(with: .normalClosure, reason: nil)
    }

    func testSilentAuthenticatedSocketIsDropped() async throws {
        channel.idleTimeout = 1
        let task = socket()
        try await send(task, ["type": "hello", "t": "good-token"])
        _ = try await task.receive()
        do {
            _ = try await task.receive()
            XCTFail("a silent socket should be dropped")
        } catch {}
    }
}

/// The crossing effect: stored, mapped from the old landing animation, and handed to the page.
final class EffectTests: XCTestCase {
    func testEffectRoundTripsAndLegacyMapsToPortal() {
        for effect in PortalEffect.allCases {
            XCTAssertEqual(PortalEffect(stored: effect.rawValue), effect)
        }
        for legacy in ["fly", "fade", "pop", "", "garbage", "Liquid"] {
            XCTAssertEqual(PortalEffect(stored: legacy), .portal, legacy)
        }
        XCTAssertEqual(PortalEffect(stored: nil), .portal)
        XCTAssertEqual(PortalEffect.allCases.map(\.title), ["Portal light", "Liquid", "Wormhole", "Beam", "Paper plane"])
    }

    func testPageCarriesTheEffect() {
        XCTAssertTrue(WebPage.html(effect: .portal).contains(##"<html lang="en" data-effect="portal" data-tint="#2F6BFF">"##))
        XCTAssertTrue(WebPage.html(effect: .beam, tint: .rainbow).contains(#"data-effect="beam" data-tint="rainbow""#))
        XCTAssertTrue(WebPage.html(effect: .liquid, tint: .gold).contains(##"data-tint="#FFC21A""##))
        for effect in PortalEffect.allCases {
            let html = WebPage.html(effect: effect)
            XCTAssertTrue(html.contains(#"data-effect="\#(effect.rawValue)""#))
            // The page knows every effect by name and has its edge look.
            XCTAssertTrue(html.contains(#""\#(effect.rawValue)""#))
            if effect != .portal { XCTAssertTrue(html.contains("html[data-effect=\(effect.rawValue)]")) }
        }
    }
}

/// The effect over the live socket: in "ready", and pushed when it changes.
final class EffectChannelTests: XCTestCase {
    func testReadyCarriesEffectAndChangesArePushed() async throws {
        let channel = PeekChannel(port: 18789)
        channel.token = "good-token"
        channel.effect = .wormhole
        let ready = expectation(description: "ready")
        channel.onReady = { if $0 { ready.fulfill() } }
        channel.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { channel.stop() }

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18789/")!)
        task.resume()
        try await task.send(.string(#"{"type":"hello","t":"good-token"}"#))
        guard case .string(let reply) = try await task.receive() else { return XCTFail("no ready") }
        XCTAssertEqual(reply, ##"{"type":"ready","effect":"wormhole","tint":"#2F6BFF"}"##)

        channel.setEffect(.plane, tint: .sunset)
        guard case .string(let pushed) = try await task.receive() else { return XCTFail("no effect message") }
        XCTAssertEqual(pushed, ##"{"type":"effect","effect":"plane","tint":"#FF5A1F"}"##)

        // A new colour alone is pushed too.
        channel.tint = .rainbow
        guard case .string(let recoloured) = try await task.receive() else { return XCTFail("no tint message") }
        XCTAssertEqual(recoloured, #"{"type":"effect","effect":"plane","tint":"rainbow"}"#)
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Each effect's colour: stored as `#RRGGBB` or `rainbow`, its tones, and Rainbow's clock.
final class PortalTintTests: XCTestCase {
    func testStoredValues() {
        XCTAssertEqual(PortalTint(stored: "rainbow"), .rainbow)
        XCTAssertEqual(PortalTint(stored: "Rainbow"), .rainbow)
        XCTAssertEqual(PortalTint(stored: "#ff5a1f"), .sunset)
        XCTAssertEqual(PortalTint(stored: "FF5A1F"), .sunset)
        for bad in [nil, "", "#12345", "#GGGGGG", "red", "#1234567"] as [String?] {
            XCTAssertNil(PortalTint(stored: bad), String(describing: bad))
        }
        for (_, tint) in PortalTint.presets {
            XCTAssertEqual(PortalTint(stored: tint.stored), tint)
        }
        XCTAssertEqual(PortalTint.presets.count, 8)
        XCTAssertEqual(PortalTint.presets.last?.tint, .rainbow)
    }

    func testEveryEffectHasItsOwnVividDefault() {
        let defaults = PortalEffect.allCases.map(PortalTint.defaultTint(for:))
        XCTAssertEqual(Set(defaults).count, PortalEffect.allCases.count)
        for tint in defaults {
            let (_, s, v) = tint.base().hsv
            XCTAssertGreaterThan(s, 0.8)
            XCTAssertGreaterThan(v, 0.9)
        }
    }

    func testTonesAreSaturatedWithAWhiteCore() {
        let dull = PortalRGB(hue: 0.6, saturation: 0.3, value: 0.4)
        let tones = PortalTones(dull)
        XCTAssertGreaterThanOrEqual(tones.glow.hsv.saturation, 0.8)
        XCTAssertGreaterThanOrEqual(tones.glow.hsv.value, 0.9)
        XCTAssertEqual(tones.glow.hsv.hue, 0.6, accuracy: 0.01)
        XCTAssertEqual(tones.second.hsv.hue, 0.675, accuracy: 0.01)
        XCTAssertGreaterThan(min(tones.core.red, tones.core.green, tones.core.blue), 0.75)
        // White stays white: no colour is invented for a grey pick.
        XCTAssertLessThan(PortalTones(.white).glow.hsv.saturation, 0.05)
    }

    func testRainbowWalksTheWheelWithTheClock() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(PortalTint.rainbowHue(at: t0), 0)
        XCTAssertEqual(PortalTint.rainbowHue(at: t0.addingTimeInterval(1.5)), 1.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(PortalTint.rainbowHue(at: t0.addingTimeInterval(18)), 0, accuracy: 1e-9)
        XCTAssertEqual(PortalTint.rainbow.base(at: t0.addingTimeInterval(6)).hsv.hue, 4.0 / 12, accuracy: 0.01)
    }

    func testHexRoundTrip() {
        XCTAssertEqual(PortalRGB(hex: "#2F6BFF")?.hex, "#2F6BFF")
        XCTAssertEqual(PortalRGB(hue: 0, saturation: 1, value: 1).hex, "#FF0000")
        XCTAssertEqual(PortalRGB(hue: 1.0 / 3, saturation: 1, value: 1).hex, "#00FF00")
    }
}
