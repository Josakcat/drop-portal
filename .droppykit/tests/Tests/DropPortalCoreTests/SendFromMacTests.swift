import Foundation
import Network
@testable import DropPortalCore
import XCTest

/// Mac → phone without a page open (the queue), and the Finder Quick Action's
/// localhost-only, token-protected `/send-to-iphone`.
final class SendFromMacTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("portal-q-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Queue

    func testQueueKeepsFilesUntilTakenAndSkipsFolders() throws {
        let queue = OutgoingQueue(manifest: nil)
        let a = try file("a.txt"), b = try file("b.txt")
        queue.add([a, folder, folder.appendingPathComponent("missing.txt")])
        queue.add([b, a])
        XCTAssertEqual(queue.items.map(\.path), [b.path, a.path], "a repeat moves to the end, once")
        XCTAssertEqual(queue.take().map(\.path), [b.path, a.path])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.take(), [])
    }

    func testQueueDropsExpiredAndDeletedFiles() throws {
        let now = Date()
        let queue = OutgoingQueue(manifest: nil)
        let old = try file("old.txt"), gone = try file("gone.txt"), fresh = try file("fresh.txt")
        queue.add([old], now: now.addingTimeInterval(-OutgoingQueue.lifetime - 5))
        queue.add([gone, fresh], now: now)
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(queue.take(now: now).map(\.lastPathComponent), ["fresh.txt"])
    }

    func testQueueSurvivesARelaunchThroughItsManifest() throws {
        let manifest = folder.appendingPathComponent("state/outgoing-queue.json")
        let a = try file("a.txt")
        OutgoingQueue(manifest: manifest).add([a])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        let again = OutgoingQueue(manifest: manifest)
        XCTAssertEqual(again.items.map(\.path), [a.path])
        _ = again.take()
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path), "an empty queue leaves no manifest")
        // A day later the manifest's entries are dropped on load.
        OutgoingQueue(manifest: manifest).add([a], now: Date().addingTimeInterval(-OutgoingQueue.lifetime - 60))
        XCTAssertTrue(OutgoingQueue(manifest: manifest).isEmpty)
    }

    func testQueueCapsItsLength() throws {
        let queue = OutgoingQueue(manifest: nil)
        let urls = try (0..<(OutgoingQueue.maxItems + 5)).map { try file("f\($0).txt") }
        queue.add(urls)
        XCTAssertEqual(queue.count, OutgoingQueue.maxItems)
        XCTAssertEqual(queue.items.first?.path, urls[5].path, "the oldest go first")
    }

    func testRemoveStagedOnlyOldCopies() throws {
        let old = folder.appendingPathComponent("old", isDirectory: true)
        let new = folder.appendingPathComponent("new", isDirectory: true)
        for dir in [old, new] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old.path)
        OutgoingQueue.removeStaged(in: folder, olderThan: OutgoingQueue.lifetime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    // MARK: Loopback

    func testLoopbackEndpoints() {
        func endpoint(_ host: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: 8787) }
        XCTAssertTrue(DropPortalServer.isLoopback(endpoint("127.0.0.1")))
        XCTAssertTrue(DropPortalServer.isLoopback(endpoint("::1")))
        XCTAssertTrue(DropPortalServer.isLoopback(endpoint("::ffff:127.0.0.1")))
        XCTAssertFalse(DropPortalServer.isLoopback(endpoint("192.168.1.20")))
        XCTAssertFalse(DropPortalServer.isLoopback(endpoint("fe80::1")))
        XCTAssertFalse(DropPortalServer.isLoopback(endpoint("10.0.0.127")))
    }

    // MARK: /send-to-iphone

    private func startServer(port: UInt16, outbox: URL?) async throws -> DropPortalServer {
        let server = DropPortalServer(port: port, destination: folder.appendingPathComponent("Downloads"), outbox: outbox)
        server.token = "good-token"
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
        return server
    }

    private func post(_ host: String, port: UInt16, headers: [String: String], body: Data, method: String = "POST") async throws -> Int {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)\(DropPortalServer.sendPath)")!)
        request.httpMethod = method
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as! HTTPURLResponse).statusCode
    }

    func testSendToIPhoneNeedsTokenAndStagesTheFile() async throws {
        let outbox = folder.appendingPathComponent("Outgoing")
        let server = try await startServer(port: 18793, outbox: outbox)
        defer { server.stop() }
        let staged = Locked<[URL]>([])
        let got = expectation(description: "outgoing")
        server.onOutgoing = { url in staged.mutate { $0.append(url) }; got.fulfill() }
        server.onFile = { _, _ in XCTFail("a Quick Action file is not a received file") }
        let body = Data("hello phone".utf8)
        let name = "รายงาน final.pdf".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        let none = try await post("127.0.0.1", port: 18793, headers: ["X-DropPortal-Name": name], body: body)
        XCTAssertEqual(none, 403)
        let wrong = try await post("127.0.0.1", port: 18793, headers: ["X-DropPortal-Token": "bad", "X-DropPortal-Name": name], body: body)
        XCTAssertEqual(wrong, 403)
        let get = try await post("127.0.0.1", port: 18793, headers: ["X-DropPortal-Token": "good-token"], body: Data(), method: "GET")
        XCTAssertEqual(get, 405)
        let ok = try await post("127.0.0.1", port: 18793, headers: ["X-DropPortal-Token": "good-token", "X-DropPortal-Name": name], body: body)
        XCTAssertEqual(ok, 200)
        await fulfillment(of: [got], timeout: 2)
        let url = try XCTUnwrap(staged.value.first)
        XCTAssertEqual(url.lastPathComponent, "รายงาน final.pdf")
        XCTAssertTrue(url.path.hasPrefix(outbox.path))
        XCTAssertEqual(try Data(contentsOf: url), body)
        let downloads = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Downloads").path)) ?? []
        XCTAssertTrue(downloads.isEmpty, "nothing lands in Downloads")
        // The staged copy can be offered to the phone like any file.
        XCTAssertNotNil(server.offer(url))
    }

    /// The Quick Action's current shortcut: a folder (or a file) by its path, no body, offered as it is.
    func testSendToIPhoneTakesAFolderByPath() async throws {
        let server = try await startServer(port: 18797, outbox: folder.appendingPathComponent("Outgoing"))
        defer { server.stop() }
        let album = folder.appendingPathComponent("Trip photos ทริป", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: album.appendingPathComponent("a.jpg"))
        let got = Locked<[URL]>([])
        let arrived = expectation(description: "outgoing")
        server.onOutgoing = { url in got.mutate { $0.append(url) }; arrived.fulfill() }
        let encoded = album.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        let none = try await post("127.0.0.1", port: 18797, headers: ["X-DropPortal-Path": encoded], body: Data())
        XCTAssertEqual(none, 403)
        let missing = try await post("127.0.0.1", port: 18797, headers: ["X-DropPortal-Token": "good-token",
                                                                         "X-DropPortal-Path": "%2Fno%2Fsuch%2Fplace"], body: Data())
        XCTAssertEqual(missing, 404)
        let relative = try await post("127.0.0.1", port: 18797, headers: ["X-DropPortal-Token": "good-token",
                                                                          "X-DropPortal-Path": "Trip%20photos"], body: Data())
        XCTAssertEqual(relative, 404)
        let ok = try await post("127.0.0.1", port: 18797, headers: ["X-DropPortal-Token": "good-token", "X-DropPortal-Path": encoded],
                                body: Data("{}".utf8))
        XCTAssertEqual(ok, 200)
        await fulfillment(of: [arrived], timeout: 2)
        XCTAssertEqual(got.value.map { $0.resolvingSymlinksInPath().path }, [album.resolvingSymlinksInPath().path])
        XCTAssertTrue(FolderZip.isFolder(try XCTUnwrap(got.value.first)), "the droplet zips it, as it zips Finder's selection")
    }

    func testSendToIPhoneWithoutOutboxIsRefused() async throws {
        let server = try await startServer(port: 18794, outbox: nil)
        defer { server.stop() }
        let status = try await post("127.0.0.1", port: 18794, headers: ["X-DropPortal-Token": "good-token"], body: Data("x".utf8))
        XCTAssertEqual(status, 503)
    }

    /// From the Mac's own LAN address the request is not loopback: it must look like no such path.
    func testSendToIPhoneIsHiddenFromTheNetwork() async throws {
        guard let lan = LocalAddress.ipv4() else { throw XCTSkip("no LAN address on this Mac") }
        let server = try await startServer(port: 18795, outbox: folder.appendingPathComponent("Outgoing"))
        defer { server.stop() }
        server.onOutgoing = { _ in XCTFail("a LAN request must not stage a file") }
        let status = try await post(lan, port: 18795, headers: ["X-DropPortal-Token": "good-token", "X-DropPortal-Name": "a.txt"],
                                    body: Data("x".utf8))
        XCTAssertEqual(status, 404)
    }

    // MARK: Paired page

    func testPairedFiresOnlyForTheRightToken() async throws {
        let channel = PeekChannel(port: 18796)
        channel.token = "good-token"
        let ready = expectation(description: "ready")
        channel.onReady = { if $0 { ready.fulfill() } }
        channel.start()
        await fulfillment(of: [ready], timeout: 5)
        defer { channel.stop() }
        let paired = Locked(0)
        channel.onPaired = { paired.mutate { $0 += 1 } }

        let bad = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18796/")!)
        bad.resume()
        try await bad.send(.string(#"{"type":"hello","t":"nope"}"#))
        _ = try? await bad.receive()
        XCTAssertEqual(paired.value, 0)

        let good = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18796/")!)
        good.resume()
        try await good.send(.string(#"{"type":"hello","t":"good-token"}"#))
        _ = try await good.receive()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(paired.value, 1)
        good.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: Quick Action shortcut

    func testQuickActionShortcutPostsToLoopbackWithToken() throws {
        let data = try QuickActionShortcut.unsigned(port: 8787, token: "tok-123")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["WFWorkflowTypes"] as? [String], ["QuickActions"])
        XCTAssertEqual(plist["WFQuickActionSurfaces"] as? [String], ["Finder"])
        let actions = try XCTUnwrap(plist["WFWorkflowActions"] as? [[String: Any]])
        let post = try XCTUnwrap(actions.first { ($0["WFWorkflowActionIdentifier"] as? String) == "is.workflow.actions.downloadurl" })
        let parameters = try XCTUnwrap(post["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(parameters["WFURL"] as? String, "http://127.0.0.1:8787/send-to-iphone")
        XCTAssertNil(parameters["WFHTTPBodyType"], "the item goes by its path, never as a body (a folder cannot be one)")
        XCTAssertTrue((plist["WFWorkflowInputContentItemClasses"] as? [String])?.contains("WFFolderContentItem") == true)
        let text = String(decoding: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), as: UTF8.self)
        XCTAssertTrue(text.contains("tok-123"))
        XCTAssertTrue(text.contains("X-DropPortal-Token"))
        XCTAssertTrue(text.contains("X-DropPortal-Path"))
        XCTAssertTrue(text.contains("File Path"))
    }
}
