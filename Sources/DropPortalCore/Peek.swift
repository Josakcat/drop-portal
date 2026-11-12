//
//  Peek.swift
//  DropPortalCore
//
//  The live preview while a card is dragged on the phone: the messages the
//  page sends over the peek socket, and the state machine that keeps one peek
//  at a time and gives up on a silent one.
//

import Foundation

/// What the phone says about the card being dragged.
public struct PeekInfo: Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video, file }

    public var id: String
    public var name: String
    public var kind: Kind
    public var size: Int64
    /// A small JPEG, empty when the phone made none (the Mac draws an icon).
    public var thumb: Data
    /// Cards flicked together, 1 to 99; the uploads after the first repeat the id.
    public var count: Int

    public init(id: String, name: String, kind: Kind, size: Int64, thumb: Data = Data(), count: Int = 1) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.thumb = thumb
        self.count = count
    }
}

/// One message from the page, validated.
public enum PeekMessage: Equatable, Sendable {
    case hello(token: String)
    case start(PeekInfo)
    case move(id: String, progress: Double)
    case commit(id: String)
    case progress(id: String, progress: Double)
    case cancel(id: String)

    public enum ParseError: Error, Equatable {
        case tooLarge, malformed, unknownType, badID, thumbTooLarge, thumbNotJPEG
    }

    /// Longest message accepted: a 64 KB thumbnail in base64 and the rest.
    public static let maxMessageBytes = 96 * 1024
    /// Largest decoded thumbnail. The page aims for 20 KB.
    public static let maxThumbBytes = 64 * 1024

    public var id: String? {
        switch self {
        case .hello: nil
        case .start(let info): info.id
        case .move(let id, _), .commit(let id), .progress(let id, _), .cancel(let id): id
        }
    }

    public static func parse(_ data: Data) throws -> PeekMessage {
        guard data.count <= maxMessageBytes else { throw ParseError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let type = json["type"] as? String
        else { throw ParseError.malformed }

        if type == "hello" {
            guard let token = json["t"] as? String else { throw ParseError.malformed }
            return .hello(token: token)
        }
        guard let id = json["id"] as? String, isValidID(id) else { throw ParseError.badID }

        switch type {
        case "peek-start":
            let name = FileNames.sanitize((json["name"] as? String) ?? "file")
            let kind = (json["kind"] as? String).flatMap(PeekInfo.Kind.init(rawValue:)) ?? .file
            let size = max(0, (json["size"] as? NSNumber)?.int64Value ?? 0)
            var thumb = Data()
            if let encoded = json["thumb"] as? String, !encoded.isEmpty {
                // Base64 is 4/3 of the bytes: refuse before decoding.
                guard encoded.utf8.count <= (maxThumbBytes / 3 + 1) * 4 else { throw ParseError.thumbTooLarge }
                guard let decoded = Data(base64Encoded: encoded) else { throw ParseError.malformed }
                guard decoded.count <= maxThumbBytes else { throw ParseError.thumbTooLarge }
                // The page only ever sends a JPEG; anything else is not decoded at all.
                guard isJPEG(decoded) else { throw ParseError.thumbNotJPEG }
                thumb = decoded
            }
            let count = min(99, max(1, (json["count"] as? NSNumber)?.intValue ?? 1))
            return .start(PeekInfo(id: id, name: name, kind: kind, size: size, thumb: thumb, count: count))
        case "peek-move", "peek-progress":
            guard let number = json["progress"] as? NSNumber else { throw ParseError.malformed }
            let value = number.doubleValue
            guard value.isFinite else { throw ParseError.malformed }
            let clamped = min(1, max(0, value))
            return type == "peek-move" ? .move(id: id, progress: clamped) : .progress(id: id, progress: clamped)
        case "peek-commit":
            return .commit(id: id)
        case "peek-cancel":
            return .cancel(id: id)
        default:
            throw ParseError.unknownType
        }
    }

    /// Starts with the JPEG magic, FF D8 FF.
    public static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF])
    }

    /// 1 to 64 letters, digits, `-` or `_`: the id also travels in an HTTP header.
    public static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x5F
        }
    }
}

/// What the Mac should draw.
public enum PeekEvent: Equatable, Sendable {
    case start(PeekInfo)
    case move(id: String, progress: Double)
    case commit(id: String)
    case progress(id: String, progress: Double)
    case cancel(id: String)
}

/// One peek at a time. A message for another id is ignored, and a peek that
/// hears nothing for `timeout` seconds is cancelled.
public struct PeekTracker: Sendable {
    public static let defaultTimeout: TimeInterval = 3

    public let timeout: TimeInterval
    public private(set) var currentID: String?
    public private(set) var isCommitted = false
    private var lastHeard = Date.distantPast

    public init(timeout: TimeInterval = PeekTracker.defaultTimeout) {
        self.timeout = timeout
    }

    /// The event to draw for `message`, or nil when it is ignored.
    public mutating func handle(_ message: PeekMessage, now: Date = Date()) -> PeekEvent? {
        switch message {
        case .hello:
            return nil
        case .start(let info):
            // A new peek replaces the old one; the old card goes with it.
            currentID = info.id
            isCommitted = false
            lastHeard = now
            return .start(info)
        default:
            guard let id = message.id, id == currentID else { return nil }
            lastHeard = now
            switch message {
            case .move(_, let p): return isCommitted ? nil : .move(id: id, progress: p)
            case .commit:
                isCommitted = true
                return .commit(id: id)
            case .progress(_, let p): return isCommitted ? .progress(id: id, progress: p) : nil
            case .cancel:
                currentID = nil
                isCommitted = false
                return .cancel(id: id)
            default: return nil
            }
        }
    }

    /// A cancel for a peek that has been silent too long, or nil.
    public mutating func expire(now: Date = Date()) -> PeekEvent? {
        guard let id = currentID, now.timeIntervalSince(lastHeard) >= timeout else { return nil }
        currentID = nil
        isCommitted = false
        return .cancel(id: id)
    }

    /// The file for `id` arrived: the peek is over, nothing to cancel.
    public mutating func finish(id: String) {
        guard id == currentID else { return }
        currentID = nil
        isCommitted = false
    }
}
