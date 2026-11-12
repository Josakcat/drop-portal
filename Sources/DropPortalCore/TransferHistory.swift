//
//  TransferHistory.swift
//  DropPortalCore
//
//  The last 30 transfers, both ways, newest first: what crossed, how big, which
//  way and when, and where it is on this Mac. Paths only, never copies; an
//  entry whose file is gone is dropped. The droplet keeps it as JSON in
//  `host.preferences` (written by the main process only) and hands a copy to
//  the server for the phone page's Recent list. Not thread-safe: main actor only.
//

import Foundation
import UniformTypeIdentifiers

public struct TransferRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Direction: String, Codable, Sendable {
        /// Phone → Mac: the file is in Downloads › Drop Portal.
        case fromPhone = "in"
        /// Mac → phone: the file (or folder, sent as a .zip) where the user keeps it.
        case toPhone = "out"
    }

    public let id: String
    public let name: String
    public let path: String
    public let size: Int64
    public let direction: Direction
    public let date: Date

    public init(id: String = TransferRecord.newID(), name: String, path: String, size: Int64,
                direction: Direction, date: Date) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.direction = direction
        self.date = date
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// "image", "video", "folder" or "file", for the thumbnail and the phone's row.
    public var kind: String {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue { return "folder" }
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : "file"
    }

    /// 16 random hex digits; what the phone names an entry by.
    /// "just now", "2 min ago", "3 h ago", "5 d ago": short enough for the notch.
    public static func shortAge(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    public static func isValidID(_ id: String) -> Bool {
        (1...32).contains(id.utf8.count) && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

public final class TransferHistory {
    public static let maxItems = 30

    /// Newest first.
    public private(set) var items: [TransferRecord]

    public init(items: [TransferRecord] = []) {
        self.items = Array(items.sorted { $0.date > $1.date }.prefix(Self.maxItems))
    }

    /// From the stored JSON; anything unreadable is an empty history.
    public convenience init(encoded: String?) {
        self.init(items: Self.decode(encoded))
    }

    public static func decode(_ encoded: String?) -> [TransferRecord] {
        guard let encoded, let data = encoded.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([TransferRecord].self, from: data)) ?? []
    }

    /// The JSON kept in the preferences.
    public var encoded: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    /// Adds a transfer at the top. The same file the same way again moves up
    /// with a fresh time. `name` and `size` default to the file's own; a path
    /// that does not exist is not added.
    @discardableResult
    public func add(_ url: URL, direction: TransferRecord.Direction, name: String? = nil, size: Int64? = nil,
                    now: Date = Date()) -> TransferRecord? {
        let path = url.standardizedFileURL.path
        guard Self.exists(path) else { return nil }
        let bytes = size ?? Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let record = TransferRecord(name: name ?? url.lastPathComponent, path: path, size: bytes,
                                    direction: direction, date: now)
        items.removeAll { $0.path == path && $0.direction == direction }
        items.insert(record, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        return record
    }

    /// Drops entries whose file or folder is gone; true when anything went.
    @discardableResult
    public func prune() -> Bool {
        let before = items.count
        items.removeAll { !Self.exists($0.path) }
        return items.count != before
    }

    public func clear() { items = [] }

    public func record(id: String) -> TransferRecord? { items.first { $0.id == id } }

    public static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}
