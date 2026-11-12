//
//  PhonePresence.swift
//  DropPortalCore
//
//  Whether a phone page is open right now: true from the first good hello on
//  the peek socket, false a few seconds after the last paired socket closed.
//  The page closes its socket when it is hidden (locked, switched away, tab
//  closed) and reconnects when it comes back; the grace keeps a quick
//  reconnect from flickering the status. A phone that vanished without a
//  close is dropped by the socket's idle timeout.
//

import Foundation

public struct PhonePresence: Equatable, Sendable {
    /// Seconds with no paired page before the phone counts as gone.
    public static let defaultGrace: TimeInterval = 3

    public let grace: TimeInterval
    /// Paired sockets open now.
    public private(set) var pages = 0
    /// What the Mac shows: a page is open (or closed less than `grace` ago).
    public private(set) var isConnected = false
    private var emptySince: Date?

    public init(grace: TimeInterval = PhonePresence.defaultGrace) {
        self.grace = grace
    }

    /// A page said hello. Returns true when `isConnected` changed.
    @discardableResult
    public mutating func opened() -> Bool {
        pages += 1
        emptySince = nil
        return set(true)
    }

    /// A paired socket closed. Never flips at once: `tick` does, after the grace.
    public mutating func closed(at now: Date = Date()) {
        pages = max(0, pages - 1)
        if pages == 0 { emptySince = now }
    }

    /// Called now and then. Returns true when `isConnected` changed.
    @discardableResult
    public mutating func tick(at now: Date = Date()) -> Bool {
        guard pages == 0, let since = emptySince, now.timeIntervalSince(since) >= grace else { return false }
        emptySince = nil
        return set(false)
    }

    /// Every socket is gone at once (stop, Reset pairing). Returns true when `isConnected` changed.
    @discardableResult
    public mutating func reset() -> Bool {
        pages = 0
        emptySince = nil
        return set(false)
    }

    private mutating func set(_ value: Bool) -> Bool {
        guard isConnected != value else { return false }
        isConnected = value
        return true
    }
}
