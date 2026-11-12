import Foundation
@testable import DropPortalCore
import XCTest

/// Mac → phone: offered files over HTTP, messages over the peek socket, and the batch count.
final class TwoWayTests: XCTestCase {
    func testPeekStartCarriesClampedCount() throws {
        func count(_ value: Any?) throws -> Int {
            var json: [String: Any] = ["type": "peek-start", "id": "p1", "name": "a.jpg"]
            json["count"] = value
            guard case .start(let info) = try PeekMessage.parse(JSONSerialization.data(withJSONObject: json)) else { return -1 }
            return info.count
        }
        XCTAssertEqual(try count(nil), 1)
        XCTAssertEqual(try count(3), 3)
        XCTAssertEqual(try count(0), 1)
        XCTAssertEqual(try count(5000), 99)
    }

    func testOfferedFileDownloadsOnlyWithToken() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("portal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = DropPortalServer(port: 18790, destination: folder)
        server.token = "good-token"
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
        defer { server.stop() }

        let file = folder.appendingPathComponent("รูป one.txt")
        let body = Data((0..<700_000).map { UInt8($0 % 251) })
        try body.write(to: file)
        XCTAssertNil(server.offer(folder), "a folder is not offered")
        let offer = try XCTUnwrap(server.offer(file))
        XCTAssertEqual(offer.size, Int64(body.count))

        func get(_ path: String) async throws -> (Int, Data, HTTPURLResponse) {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18790" + path)!)
            let http = response as! HTTPURLResponse
            return (http.statusCode, data, http)
        }
        let (noToken, _, _) = try await get("/download/\(offer.id)")
        XCTAssertEqual(noToken, 403)
        let (unknown, _, _) = try await get("/download/nope?t=good-token")
        XCTAssertEqual(unknown, 404)
        let (ok, data, http) = try await get("/download/\(offer.id)?t=good-token")
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(data, body)
        let disposition = try XCTUnwrap(http.value(forHTTPHeaderField: "Content-Disposition"))
        XCTAssertTrue(disposition.hasPrefix("attachment; filename=\""))
        XCTAssertTrue(disposition.contains("filename*=UTF-8''%E0%B8%A3"), disposition)
    }

    func testBroadcastReachesOnlyPairedPages() async throws {
        let channel = PeekChannel(port: 18791)
        channel.token = "good-token"
        let ready = expectation(description: "ready")
        channel.onReady = { if $0 { ready.fulfill() } }
        channel.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { channel.stop() }

        let none = expectation(description: "nobody")
        channel.broadcast(["type": "clipboard", "text": "hi"]) { XCTAssertEqual($0, 0); none.fulfill() }
        await fulfillment(of: [none], timeout: 2)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18791/")!)
        task.resume()
        try await task.send(.string(#"{"type":"hello","t":"good-token"}"#))
        _ = try await task.receive()
        let one = expectation(description: "one")
        channel.broadcast(["type": "clipboard", "text": "สวัสดี \"x\""]) { XCTAssertEqual($0, 1); one.fulfill() }
        guard case .string(let text) = try await task.receive() else { return XCTFail("no message") }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(json, ["type": "clipboard", "text": "สวัสดี \"x\""])
        await fulfillment(of: [one], timeout: 2)
        task.cancel(with: .normalClosure, reason: nil)
    }
}
