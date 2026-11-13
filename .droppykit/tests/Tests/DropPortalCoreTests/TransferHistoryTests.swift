import Foundation
import ImageIO
@testable import DropPortalCore
import XCTest

/// Recent: the store (add, cap, prune, round trip) and the phone's token-checked `/history` routes.
final class TransferHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("portal-h-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, _ bytes: Int = 3) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url
    }

    func testAddsNewestFirstAndMovesARepeatUp() throws {
        let history = TransferHistory()
        let a = try file("a.txt", 10), b = try file("b.jpg", 20)
        let now = Date()
        XCTAssertNotNil(history.add(a, direction: .fromPhone, now: now))
        history.add(b, direction: .toPhone, now: now.addingTimeInterval(1))
        history.add(a, direction: .toPhone, now: now.addingTimeInterval(2))
        XCTAssertEqual(history.items.map(\.name), ["a.txt", "b.jpg", "a.txt"], "the same file the other way is its own entry")
        history.add(b, direction: .toPhone, now: now.addingTimeInterval(3))
        XCTAssertEqual(history.items.map(\.name), ["b.jpg", "a.txt", "a.txt"], "a repeat moves to the top, once")
        XCTAssertEqual(history.items.first?.size, 20)
        XCTAssertEqual(history.items.first?.kind, "image")
        XCTAssertEqual(history.items.last?.direction, .fromPhone)
    }

    func testSkipsMissingFilesKeepsFoldersAndCaps() throws {
        let history = TransferHistory()
        XCTAssertNil(history.add(folder.appendingPathComponent("missing.txt"), direction: .fromPhone))
        let sub = folder.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let record = try XCTUnwrap(history.add(sub, direction: .toPhone, name: "Trip", size: 1234))
        XCTAssertEqual(record.kind, "folder")
        XCTAssertEqual(record.size, 1234)
        for i in 0..<(TransferHistory.maxItems + 4) { history.add(try file("f\(i).txt"), direction: .fromPhone) }
        XCTAssertEqual(history.items.count, TransferHistory.maxItems)
        XCTAssertEqual(history.items.first?.name, "f\(TransferHistory.maxItems + 3).txt")
    }

    func testPruneDropsEntriesWhoseFileIsGone() throws {
        let history = TransferHistory()
        let keep = try file("keep.txt"), gone = try file("gone.txt")
        history.add(keep, direction: .fromPhone)
        history.add(gone, direction: .toPhone)
        XCTAssertFalse(history.prune())
        try FileManager.default.removeItem(at: gone)
        XCTAssertTrue(history.prune())
        XCTAssertEqual(history.items.map(\.name), ["keep.txt"])
        history.clear()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testRoundTripsThroughItsJSON() throws {
        let history = TransferHistory()
        let a = try file("รูป.jpg"), b = try file("b.txt")
        history.add(a, direction: .fromPhone, now: Date(timeIntervalSince1970: 1_800_000_000))
        history.add(b, direction: .toPhone, now: Date(timeIntervalSince1970: 1_800_000_100))
        let again = TransferHistory(encoded: history.encoded)
        XCTAssertEqual(again.items, history.items)
        XCTAssertEqual(again.record(id: history.items[1].id)?.name, "รูป.jpg")
        XCTAssertTrue(TransferHistory(encoded: "not json").items.isEmpty)
        XCTAssertTrue(TransferHistory(encoded: nil).items.isEmpty)
    }

    func testIDsAreHexOnly() {
        XCTAssertTrue(TransferRecord.isValidID(TransferRecord.newID()))
        for bad in ["", "../etc", "ABC", "abc/def", String(repeating: "a", count: 40)] {
            XCTAssertFalse(TransferRecord.isValidID(bad), bad)
        }
    }

    // MARK: Server

    func testHistoryRoutesNeedTheTokenAndServeOnlyListedFiles() async throws {
        let server = DropPortalServer(port: 18794, destination: folder)
        server.token = "good-token"
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
        defer { server.stop() }

        let history = TransferHistory()
        let body = Data((0..<300_000).map { UInt8($0 % 251) })
        let doc = folder.appendingPathComponent("report.pdf")
        try body.write(to: doc)
        let sub = folder.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let gone = try file("gone.txt")
        let docRecord = try XCTUnwrap(history.add(doc, direction: .fromPhone))
        let folderRecord = try XCTUnwrap(history.add(sub, direction: .toPhone, name: "Trip", size: 9))
        let goneRecord = try XCTUnwrap(history.add(gone, direction: .toPhone))
        try FileManager.default.removeItem(at: gone)
        server.history = history.items
        let resent = expectation(description: "resend")
        nonisolated(unsafe) var resentURL: URL?
        server.onResend = { resentURL = $0; resent.fulfill() }

        func call(_ path: String, method: String = "GET", token: String? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18794" + path)!)
            request.httpMethod = method
            if let token { request.setValue(token, forHTTPHeaderField: "X-DropPortal-Token") }
            if method == "POST" { request.httpBody = Data() }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }

        let v1 = try await call("/history").0
        XCTAssertEqual(v1, 403)
        let v2 = try await call("/history?t=wrong").0
        XCTAssertEqual(v2, 403)
        let (ok, json) = try await call("/history?t=good-token")
        XCTAssertEqual(ok, 200)
        let items = try XCTUnwrap((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["name"] as? String }, ["Trip", "report.pdf"], "a file that is gone is not listed")
        XCTAssertEqual(items.first?["kind"] as? String, "folder")
        XCTAssertEqual(items.last?["dir"] as? String, "in")

        let v3 = try await call("/history/\(docRecord.id)").0
        XCTAssertEqual(v3, 403)
        let (got, data) = try await call("/history/\(docRecord.id)?t=good-token")
        XCTAssertEqual(got, 200)
        XCTAssertEqual(data, body)
        let v4 = try await call("/history/\(goneRecord.id)?t=good-token").0
        XCTAssertEqual(v4, 404)
        let v5 = try await call("/history/0123456789abcdef?t=good-token").0
        XCTAssertEqual(v5, 404, "an id not in the list")
        let v6 = try await call("/history/..%2F..%2Fetc?t=good-token").0
        XCTAssertEqual(v6, 404)
        let v7 = try await call("/history/\(folderRecord.id)?t=good-token").0
        XCTAssertEqual(v7, 404, "a folder is not downloaded")
        let v8 = try await call("/history/\(docRecord.id)/thumb?t=good-token").0
        XCTAssertEqual(v8, 404, "a PDF has no photo thumbnail")

        let v9 = try await call("/history/\(folderRecord.id)/send", method: "POST").0
        XCTAssertEqual(v9, 403)
        let v10 = try await call("/history/\(folderRecord.id)/send", method: "POST", token: "wrong").0
        XCTAssertEqual(v10, 403)
        let v11 = try await call("/history/\(folderRecord.id)/send?t=good-token", method: "POST").0
        XCTAssertEqual(v11, 403,
                       "a POST takes the token from its header only")
        let v12 = try await call("/history/\(folderRecord.id)/send").0
        XCTAssertEqual(v12, 405)
        let v13 = try await call("/history/\(folderRecord.id)/send", method: "POST", token: "good-token").0
        XCTAssertEqual(v13, 200)
        await fulfillment(of: [resent], timeout: 5)
        XCTAssertEqual(resentURL?.standardizedFileURL.path, sub.standardizedFileURL.path)
    }

    func testPhotoThumbnail() async throws {
        let server = DropPortalServer(port: 18795, destination: folder)
        server.token = "t"
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
        defer { server.stop() }
        // A 400 × 300 PNG, written with ImageIO.
        let png = folder.appendingPathComponent("p.png")
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let history = TransferHistory()
        let record = try XCTUnwrap(history.add(png, direction: .fromPhone))
        server.history = history.items
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18795/history/\(record.id)/thumb?t=t")!)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        XCTAssertEqual((response as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 160)
    }

    func testLinkReplyTellsThePage() async throws {
        let server = DropPortalServer(port: 18796, destination: folder)
        server.token = "t"
        // Off until the droplet passes the setting (off for new installs).
        XCTAssertFalse(server.opensLinks)
        server.opensLinks = true
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
        defer { server.stop() }
        func send(_ text: String) async throws -> [String: String] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18796/text")!)
            request.httpMethod = "POST"
            request.setValue("t", forHTTPHeaderField: "X-DropPortal-Token")
            request.httpBody = Data(text.utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
        }
        let v14 = try await send(" https://example.com/a ")["link"]
        XCTAssertEqual(v14, "1")
        let v15 = try await send("javascript:alert(1)")["link"]
        XCTAssertNil(v15)
        server.opensLinks = false
        let v16 = try await send("https://example.com")["link"]
        XCTAssertNil(v16)
    }
}
