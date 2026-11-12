//
//  OutgoingQueue.swift
//  DropPortalCore
//
//  Files sent from the Mac while no phone page is connected. They wait here,
//  in memory and in a small JSON manifest (paths and times only, never file
//  contents), for up to 24 hours, and go out the moment a page says hello.
//  Not thread-safe: the droplet uses it on the main actor only.
//

import Foundation

public final class OutgoingQueue {
    public struct Item: Codable, Equatable, Sendable {
        public let path: String
        public let added: Date

        public init(path: String, added: Date) {
            self.path = path
            self.added = added
        }
    }

    /// How long a file waits for the phone.
    public static let lifetime: TimeInterval = 24 * 3600
    /// The oldest go first past this many.
    public static let maxItems = 50

    /// Where the queue is kept between launches; `nil` keeps it in memory only.
    public let manifest: URL?
    public private(set) var items: [Item] = []

    public init(manifest: URL?, now: Date = Date()) {
        self.manifest = manifest
        if let manifest, let data = try? Data(contentsOf: manifest),
           let stored = try? JSONDecoder().decode([Item].self, from: data) {
            items = stored
        }
        if prune(now: now) { save() }
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Queues regular files (a folder or a missing path is skipped); a file
    /// already waiting moves to the end with a fresh time.
    public func add(_ urls: [URL], now: Date = Date()) {
        let paths = urls.map(\.standardizedFileURL.path).filter(Self.isRegularFile)
        guard !paths.isEmpty else { return }
        items.removeAll { paths.contains($0.path) }
        items += paths.map { Item(path: $0, added: now) }
        if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        prune(now: now)
        save()
    }

    /// Everything still worth sending, oldest first; the queue is empty after.
    /// Expired items and files that are gone are dropped on the way.
    public func take(now: Date = Date()) -> [URL] {
        prune(now: now)
        let urls = items.map { URL(fileURLWithPath: $0.path) }
        items = []
        save()
        return urls
    }

    /// Drops expired items and files that are gone; true when anything went.
    @discardableResult
    public func prune(now: Date = Date()) -> Bool {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.added) > Self.lifetime || $0.added > now.addingTimeInterval(60)
            || !Self.isRegularFile($0.path) }
        return items.count != before
    }

    private func save() {
        guard let manifest else { return }
        let fm = FileManager.default
        if items.isEmpty {
            try? fm.removeItem(at: manifest)
            return
        }
        try? fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: manifest, options: .atomic)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }

    /// Removes files in `folder` (the Quick Action's staged copies) older than
    /// `age` seconds. Safe off the main thread.
    public static func removeStaged(in folder: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
