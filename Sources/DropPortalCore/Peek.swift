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
    /// The courier effects' variant (Couriers.swift), made by the page when the
    /// drag starts so both screens play the same one; nil from an older page.
    public var seed: UInt32?
    /// The page's last flick was under 10 s ago: the courier's short version.
    public var short: Bool

    public init(id: String, name: String, kind: Kind, size: Int64, thumb: Data = Data(), count: Int = 1,
                seed: UInt32? = nil, short: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.thumb = thumb
        self.count = count
        self.seed = seed
        self.short = short
    }
}

/// How the finger let go of the card on the phone, sent with `peek-commit`
/// (`vx`, `vy`, `exitY`, `angle`). Every field is optional on the wire; a
/// release with no usable velocity is nil and the Mac flies its own way.
public struct PeekRelease: Equatable, Sendable {
    /// Release velocity in the page's CSS px per second, y down (negative x = toward the left edge).
    public var vx: Double
    public var vy: Double
    /// Where the card leaves the phone's left edge: 0 top to 1 bottom.
    public var exitY: Double?
    /// The card's turn at the release, degrees clockwise as CSS draws it.
    public var angle: Double

    /// Faster than this is a glitch in the samples, not a finger.
    public static let maxSpeed = 20_000.0

    public init(vx: Double, vy: Double, exitY: Double? = nil, angle: Double = 0) {
        let speed = (vx * vx + vy * vy).squareRoot()
        let k = speed > Self.maxSpeed ? Self.maxSpeed / speed : 1
        self.vx = vx * k
        self.vy = vy * k
        self.exitY = exitY.map { min(1, max(0, $0)) }
        self.angle = min(90, max(-90, angle))
    }

    init?(json: [String: Any]) {
        func number(_ key: String) -> Double? {
            guard let n = json[key] as? NSNumber, !PeekMessage.isBool(n), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        guard let vx = number("vx"), let vy = number("vy") else { return nil }
        self.init(vx: vx, vy: vy, exitY: PeekMessage.unit(json["exitY"]), angle: number("angle") ?? 0)
    }
}

/// One message from the page, validated.
public enum PeekMessage: Equatable, Sendable {
    case hello(token: String)
    case start(PeekInfo)
    /// `y`: the card's middle on the phone, 0 top to 1 bottom; nil from an older page.
    case move(id: String, progress: Double, y: Double? = nil)
    /// `release`: how the finger let go; nil from an older page.
    case commit(id: String, release: PeekRelease? = nil)
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
        case .move(let id, _, _), .commit(let id, _), .progress(let id, _), .cancel(let id): id
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
            // A whole number 1 ... 2³² − 1; anything else is no seed.
            var seed: UInt32?
            if let n = json["seed"] as? NSNumber, !isBool(n), n.doubleValue.isFinite,
               n.doubleValue >= 1, n.doubleValue <= Double(UInt32.max), n.doubleValue.rounded() == n.doubleValue {
                seed = UInt32(n.doubleValue)
            }
            let short = (json["short"] as? NSNumber).map { isBool($0) && $0.boolValue } ?? false
            return .start(PeekInfo(id: id, name: name, kind: kind, size: size, thumb: thumb, count: count,
                                   seed: seed, short: short))
        case "peek-move", "peek-progress":
            guard let number = json["progress"] as? NSNumber else { throw ParseError.malformed }
            let value = number.doubleValue
            guard value.isFinite else { throw ParseError.malformed }
            let clamped = min(1, max(0, value))
            return type == "peek-move" ? .move(id: id, progress: clamped, y: unit(json["y"])) : .progress(id: id, progress: clamped)
        case "peek-commit":
            return .commit(id: id, release: PeekRelease(json: json))
        case "peek-cancel":
            return .cancel(id: id)
        default:
            throw ParseError.unknownType
        }
    }

    /// A finite number clamped to 0...1, or nil.
    static func unit(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number), number.doubleValue.isFinite else { return nil }
        return min(1, max(0, number.doubleValue))
    }

    /// JSON's true and false arrive as NSNumber too.
    static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
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
    case move(id: String, progress: Double, y: Double? = nil)
    case commit(id: String, release: PeekRelease? = nil)
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
            case .move(_, let p, let y): return isCommitted ? nil : .move(id: id, progress: p, y: y)
            case .commit(_, let release):
                isCommitted = true
                return .commit(id: id, release: release)
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
