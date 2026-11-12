//
//  EdgeDropState.swift
//  DropPortalCore
//
//  When the right-edge drop zone and its light are on screen, and when they
//  go. No AppKit: `EdgePortal` feeds it the drag's events and a clock and
//  does what it answers, so the rules are unit-tested. Nothing it shows can
//  outlive the drag: a button-up away from the zone hides at once, a button-up
//  on the zone waits `dropWait` for the drop, and `stall` without any drag
//  event while the button is up hides whatever is left, even when the drag
//  watcher never said the drag ended.
//

import Foundation

public struct EdgeDropState: Sendable {
    public enum HideReason: String, Sendable {
        case dropped = "dropped"
        case buttonUpAway = "button up away from the zone"
        case noDrop = "button up on the zone but no drop arrived"
        case stalled = "no drag activity, button up"
        case refused = "drop refused"
        case teardown = "teardown"
    }

    public enum Action: Equatable, Sendable {
        case none
        case showZones
        /// The light goes out, the zone stays: the button is still down but the pointer rests.
        case dimLight
        case hide(HideReason)
    }

    /// After a button-up on the zone, how long the drop has to arrive.
    public static let dropWait: TimeInterval = 0.6
    /// Without any drag event for this long, the light dims (button down) or everything hides (button up).
    public static let stall: TimeInterval = 1.5

    public private(set) var visible = false
    public private(set) var hovering = false
    public private(set) var lastActivity: TimeInterval = 0
    public private(set) var buttonUpAt: TimeInterval?
    private var dimmed = false

    public init() {}

    public mutating func begin(at now: TimeInterval) -> Action {
        lastActivity = now
        buttonUpAt = nil
        dimmed = false
        guard !visible else { return .none }
        visible = true
        hovering = false
        return .showZones
    }

    /// The pointer moved during the drag (or the zone heard `draggingUpdated`).
    public mutating func moved(at now: TimeInterval) {
        lastActivity = now
        dimmed = false
    }

    public mutating func entered(at now: TimeInterval) {
        hovering = true
        lastActivity = now
    }

    public mutating func exited(at now: TimeInterval) -> Action {
        hovering = false
        lastActivity = now
        // The button already came up while we waited for the drop: nothing will land.
        if visible, buttonUpAt != nil { return hide(.buttonUpAway) }
        return .none
    }

    /// The left button came up, dropped or not.
    public mutating func buttonUp(at now: TimeInterval) -> Action {
        guard visible else { return .none }
        if hovering {
            if buttonUpAt == nil { buttonUpAt = now }
            return .none
        }
        return hide(.buttonUpAway)
    }

    public mutating func dropped() -> Action {
        guard visible else { return .none }
        return hide(.dropped)
    }

    public mutating func refused() -> Action {
        guard visible else { return .none }
        return hide(.refused)
    }

    public mutating func tearDown() -> Action {
        guard visible else { return .none }
        return hide(.teardown)
    }

    /// The watchdog, a few times a second while anything is visible.
    public mutating func tick(at now: TimeInterval, buttonDown: Bool) -> Action {
        guard visible else { return .none }
        if let up = buttonUpAt, now - up >= Self.dropWait { return hide(.noDrop) }
        if !buttonDown, buttonUpAt == nil {
            // The watcher has not said so yet (or never will): the watchdog notices on its own.
            if !hovering { return hide(.buttonUpAway) }
            buttonUpAt = now
        }
        guard now - lastActivity >= Self.stall else { return .none }
        if !buttonDown { return hide(.stalled) }
        guard !dimmed else { return .none }
        dimmed = true
        return .dimLight
    }

    private mutating func hide(_ reason: HideReason) -> Action {
        visible = false
        hovering = false
        buttonUpAt = nil
        dimmed = false
        return .hide(reason)
    }
}
