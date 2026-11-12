import Foundation
@testable import DropPortalCore
import XCTest

final class HTTPParserTests: XCTestCase {
    private func parse(_ text: String) throws -> (head: HTTPRequestHead, consumed: Int)? {
        try HTTPRequestHead.parse(Data(text.utf8))
    }

    func testParsesRequestLineQueryAndHeaders() throws {
        let raw = "GET /?t=abc%2Bd&x=1 HTTP/1.1\r\nHost: mac:8787\r\nX-DropPortal-Token:  tok \r\n\r\nBODY"
        let (head, consumed) = try XCTUnwrap(parse(raw))
        XCTAssertEqual(head.method, "GET")
        XCTAssertEqual(head.path, "/")
        XCTAssertEqual(head.query["t"], "abc+d")
        XCTAssertEqual(head.headers["x-dropportal-token"], "tok")
        XCTAssertEqual(String(decoding: Data(raw.utf8).dropFirst(consumed), as: UTF8.self), "BODY")
    }

    func testIncompleteHeadNeedsMoreBytes() throws {
        XCTAssertNil(try parse("POST /upload HTTP/1.1\r\nContent-Length: 4\r\n"))
    }

    func testContentLength() throws {
        let head = try XCTUnwrap(parse("POST /upload HTTP/1.1\r\nContent-Length: 2147483648\r\n\r\n")).head
        XCTAssertEqual(head.contentLength, 2_147_483_648)
    }

    func testRejectsMalformedAndSmuggling() {
        for raw in [
            "GARBAGE\r\n\r\n",
            "GET nothing HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\nNoColon\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        ] {
            XCTAssertThrowsError(try parse(raw), raw)
        }
    }

    func testRejectsHugeHead() {
        let raw = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequestHead.maxHeadBytes + 10)
        XCTAssertThrowsError(try parse(raw)) { XCTAssertEqual($0 as? HTTPRequestHead.ParseError, .tooLarge) }
    }

    func testResponseSerialization() {
        let text = String(decoding: HTTPResponse.text(403, "no").serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nno"))
    }
}

final class SecurityTests: XCTestCase {
    func testTokenShapeAndUniqueness() {
        let a = PairingToken.generate(), b = PairingToken.generate()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testTokenMatching() {
        XCTAssertTrue(PairingToken.matches("secret", expected: "secret"))
        XCTAssertFalse(PairingToken.matches("secreT", expected: "secret"))
        XCTAssertFalse(PairingToken.matches("secret2", expected: "secret"))
        XCTAssertFalse(PairingToken.matches("secre", expected: "secret"))
        XCTAssertFalse(PairingToken.matches(nil, expected: "secret"))
        XCTAssertFalse(PairingToken.matches("", expected: ""))
    }

    func testSanitizerStripsPaths() {
        XCTAssertEqual(FileNames.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileNames.sanitize("..\\..\\Windows\\x.txt"), "x.txt")
        XCTAssertEqual(FileNames.sanitize("/abs/path/photo.jpg"), "photo.jpg")
        XCTAssertEqual(FileNames.sanitize(".."), "file")
        XCTAssertEqual(FileNames.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileNames.sanitize(""), "file")
        XCTAssertEqual(FileNames.sanitize("a:b\u{0}\nc.png"), "abc.png")
        XCTAssertEqual(FileNames.sanitize("IMG_0001.HEIC"), "IMG_0001.HEIC")
    }

    func testSanitizerCapsLengthKeepingExtension() {
        let name = FileNames.sanitize(String(repeating: "x", count: 400) + ".mov")
        XCTAssertEqual(name.utf8.count, FileNames.maxBytes)
        XCTAssertTrue(name.hasSuffix(".mov"))
        let short = "IMG " + String(repeating: "x", count: 200) + ".jpg"
        XCTAssertEqual(FileNames.sanitize(short), short)
    }

    func testSanitizerCapsThaiNameInBytes() throws {
        // Thai is 3 bytes a letter: 120 letters fit the old 150-character cap
        // but are 360 bytes, more than APFS's 255.
        let base = String(repeating: "รูปภาพวันหยุดที่เชียงใหม่", count: 6)
        let raw = base + ".jpeg"
        XCTAssertGreaterThan(raw.utf8.count, 255)
        let name = FileNames.sanitize(raw)
        XCTAssertLessThanOrEqual(name.utf8.count, FileNames.maxBytes)
        XCTAssertGreaterThan(name.utf8.count, FileNames.maxBytes - 12, "cut close to the cap")
        XCTAssertTrue(name.hasSuffix(".jpeg"))
        XCTAssertTrue(base.hasPrefix(String(name.dropLast(5))), "cut on a whole character")
        // The file can really be created, also with unique's " 2".
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()))
        let second = FileNames.unique(name, in: dir)
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))
        // Emoji stay whole too (4 bytes each).
        let emoji = FileNames.sanitize(String(repeating: "😀", count: 100) + ".png")
        XCTAssertLessThanOrEqual(emoji.utf8.count, FileNames.maxBytes)
        XCTAssertTrue(emoji.dropLast(4).allSatisfy { $0 == "😀" })
    }

    func testReceivedFileSafety() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let photo = dir.appendingPathComponent("photo.jpg")
        fm.createFile(atPath: photo.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertNil(ReceivedFile.quarantineValue(photo))
        XCTAssertTrue(ReceivedFile.quarantine(photo))
        XCTAssertTrue(ReceivedFile.quarantineValue(photo)?.hasSuffix(";Drop Portal;") == true)
        XCTAssertFalse(ReceivedFile.revealsInsteadOfOpening(photo))
        for name in ["Installer.PKG", "run.command", "x.sh", "a.app", "b.dmg", "c.jar", "d.scpt", "e.workflow", "f.terminal", "g.tool"] {
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o644])
            XCTAssertTrue(ReceivedFile.revealsInsteadOfOpening(url), name)
        }
        let binary = dir.appendingPathComponent("tool-without-extension")
        fm.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(ReceivedFile.revealsInsteadOfOpening(binary))

        let old = dir.appendingPathComponent(".dropportal-old.part")
        let fresh = dir.appendingPathComponent(".dropportal-fresh.part")
        fm.createFile(atPath: old.path, contents: Data())
        fm.createFile(atPath: fresh.path, contents: Data())
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: photo.path)
        XCTAssertEqual(ReceivedFile.removeOrphanPartials(in: dir), 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a transfer still running keeps its file")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "only partial files go")
    }

    func testUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(FileNames.unique("a.jpg", in: dir).lastPathComponent, "a.jpg")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.jpg").path, contents: Data())
        XCTAssertEqual(FileNames.unique("a.jpg", in: dir).lastPathComponent, "a 2.jpg")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a 2.jpg").path, contents: Data())
        XCTAssertEqual(FileNames.unique("a.jpg", in: dir).lastPathComponent, "a 3.jpg")
    }

    func testShareShortcutPostsToThisMacWithToken() throws {
        let data = try ShareShortcut.unsigned(host: "mac.local", port: 8787, token: "good-token")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["WFWorkflowTypes"] as? [String], ["ActionExtension"])
        let actions = try XCTUnwrap(plist["WFWorkflowActions"] as? [[String: Any]])
        let posts = actions.filter { ($0["WFWorkflowActionIdentifier"] as? String) == "is.workflow.actions.downloadurl" }
            .compactMap { $0["WFWorkflowActionParameters"] as? [String: Any] }
        XCTAssertEqual(posts.compactMap { $0["WFURL"] as? String },
                       ["http://mac.local:8787/text", "http://mac.local:8787/upload"])
        XCTAssertTrue(posts.allSatisfy { $0["WFHTTPMethod"] as? String == "POST" })
        // Every If and Repeat opens and closes.
        let modes = actions.compactMap { ($0["WFWorkflowActionParameters"] as? [String: Any])?["WFControlFlowMode"] as? Int }
        XCTAssertEqual(modes, [0, 0, 1, 2, 2])
        XCTAssertEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "good-token").count - 1, 2)
    }
}
