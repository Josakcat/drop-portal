import Foundation
@testable import DropPortalCore
import XCTest

/// A folder from the Mac goes to the phone as one .zip in the staging folder, removed afterwards.
final class FolderZipTests: XCTestCase {
    private var root: URL!
    private var staging: URL { root.appendingPathComponent("Outgoing", isDirectory: true) }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("portal-zip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 50_000).write(to: folder.appendingPathComponent("inner/b.bin"))
        return folder
    }

    func testArchivePathIsInItsOwnStagingFolder() throws {
        let folder = try makeFolder("Trip photos")
        let archive = FolderZip.archiveURL(for: folder, in: staging)
        XCTAssertEqual(archive.lastPathComponent, "Trip photos.zip")
        XCTAssertTrue(archive.deletingLastPathComponent().lastPathComponent.hasPrefix(FolderZip.folderPrefix))
        XCTAssertEqual(archive.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       staging.standardizedFileURL.path)
        XCTAssertTrue(FolderZip.isArchive(archive, in: staging))
        XCTAssertNotEqual(archive, FolderZip.archiveURL(for: folder, in: staging), "each send gets its own folder")
        XCTAssertEqual(FolderZip.archiveURL(for: root.appendingPathComponent("a/b..").appendingPathComponent("x"), in: staging).lastPathComponent, "x.zip")
    }

    func testIsFolder() throws {
        let folder = try makeFolder("F")
        XCTAssertTrue(FolderZip.isFolder(folder))
        XCTAssertFalse(FolderZip.isFolder(folder.appendingPathComponent("a.txt")))
        XCTAssertFalse(FolderZip.isFolder(root.appendingPathComponent("missing")))
        XCTAssertEqual(FolderZip.size(of: folder), 50_003)
    }

    func testZipsWithKeepParentAndRemovesOnlyItsOwn() throws {
        let folder = try makeFolder("Docs")
        let done = expectation(description: "zipped")
        nonisolated(unsafe) var result: Result<URL, FolderZip.Failure>?
        FolderZip.zip(folder, in: staging) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 30)
        let archive = try XCTUnwrap(try result?.get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(archive.lastPathComponent, "Docs.zip")
        // The archive holds the folder itself (--keepParent).
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", archive.path]
        let pipe = Pipe(); list.standardOutput = pipe
        try list.run(); list.waitUntilExit()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(names.contains("Docs/a.txt"), names)
        XCTAssertTrue(names.contains("Docs/inner/b.bin"), names)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the original stays")

        // Something that is not one of ours is never removed.
        let other = folder.appendingPathComponent("a.txt")
        XCTAssertFalse(FolderZip.remove(other, in: staging))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FolderZip.remove(archive, in: staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.deletingLastPathComponent().path), "its own folder goes too")
    }

    func testZipOfAFileFailsAndLeavesNothing() throws {
        let file = root.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file)
        let done = expectation(description: "done")
        nonisolated(unsafe) var result: Result<URL, FolderZip.Failure>?
        FolderZip.zip(file, in: staging) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        guard case .failure(.notAFolder) = result else { return XCTFail("\(String(describing: result))") }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [], [])
    }

    func testExpiredArchivesGoWithTheStagedCopies() throws {
        let old = staging.appendingPathComponent(FolderZip.folderPrefix + "old", isDirectory: true)
        let new = staging.appendingPathComponent(FolderZip.folderPrefix + "new", isDirectory: true)
        for dir in [old, new] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: old.path)
        OutgoingQueue.removeStaged(in: staging, olderThan: OutgoingQueue.lifetime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    func testServerReportsACompleteDownload() async throws {
        let server = DropPortalServer(port: 18793, destination: root)
        server.token = "good-token"
        let ready = expectation(description: "ready")
        server.onState = { if $0 == .ready { ready.fulfill() } }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        server.onState = nil
        defer { server.stop() }
        let file = root.appendingPathComponent("big.zip")
        try Data(repeating: 1, count: 600_000).write(to: file)
        let offer = try XCTUnwrap(server.offer(file))
        let downloaded = expectation(description: "downloaded")
        server.onDownloaded = { url in
            XCTAssertEqual(url, file)
            downloaded.fulfill()
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18793/download/\(offer.id)?t=good-token")!)
        XCTAssertEqual(data.count, 600_000)
        await fulfillment(of: [downloaded], timeout: 5)
    }
}
