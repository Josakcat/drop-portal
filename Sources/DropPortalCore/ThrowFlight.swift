//
//  ThrowFlight.swift
//  DropPortalCore
//
//  The Mac card's path after a flick: it leaves where the drag left it with
//  the phone's release velocity (mapped onto the Mac) and decelerates into
//  its landing spot, arriving at rest exactly `duration` later. A fast flick
//  arrives sooner and, past what the distance can absorb, flies beyond the
//  spot and comes back; a slow one drifts in. The impact, the light and the
//  sound are all timed to `duration`.
//
//  Each axis is `target − (1 − u)³ (D + (3D − v₀T) u)` with u = t / T: it
//  starts at the card with velocity v₀, ends on the target with zero
//  velocity and zero acceleration (no snap). With v₀T = 4D it is the quartic
//  ease-out; slower starts gentler, faster overshoots.
//

import Foundation

public struct ThrowFlight: Equatable, Sendable {
    public struct Vector: Equatable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
        public var length: Double { (x * x + y * y).squareRoot() }
    }

    /// Mac points, y up.
    public let from: Vector
    public let to: Vector
    /// Points per second at the release, y up, after the limits.
    public let velocity: Vector
    /// Release to landing, seconds.
    public let duration: Double

    /// Phone CSS px/s to Mac pt/s on a 1280-wide screen (`scale` 1).
    public static let gain = 1.6
    /// Mapped speed limits, pt/s at `scale` 1.
    public static let speedRange = 360.0...6000.0
    /// At most this far from straight left (the card has to come in).
    public static let maxAngle = 55.0 * .pi / 180
    /// The longest overshoot past the spot, pt at `scale` 1.
    public static let maxOvershoot = 70.0

    /// - Parameters:
    ///   - release: the phone's velocity, CSS px/s, y down.
    ///   - base: the effect's own flight; the throw stays within 0.8× to base + 0.3 s.
    ///   - scale: the screen's size against 1280 × 800.
    ///   - yRange: where the card's middle may go (inside the visible frame).
    public init(from: Vector, to: Vector, release: Vector, base: Double, scale: Double = 1,
                yRange: ClosedRange<Double>? = nil) {
        self.from = from
        self.to = to
        let k = max(0.5, scale)
        // Phone px/s, y down → Mac pt/s, y up, heading left, within limits.
        var v = Vector(release.x * Self.gain * k, -release.y * Self.gain * k)
        var angle = atan2(v.y, -v.x)
        if !angle.isFinite || v.x >= 0 { angle = 0 }
        angle = min(Self.maxAngle, max(-Self.maxAngle, angle))
        let speed = min(Self.speedRange.upperBound * k, max(Self.speedRange.lowerBound * k, v.length))
        v = Vector(-cos(angle) * speed, sin(angle) * speed)

        // The time a natural deceleration (quartic ease-out) takes to cover
        // the distance at this speed: shorter for a fast flick, longer for a
        // slow one, within the effect's beat.
        let dx = to.x - from.x
        let natural = abs(dx) > 1 ? 4 * abs(dx) / max(1, abs(v.x)) : 0
        let T = min(base + 0.3, max(0.8 * base, natural))

        // Past what the distance can take, the excess flies beyond the spot: capped.
        func capped(_ v0: Double, _ d: Double, limit: Double) -> Double {
            let excess = v0 * T - 4 * d
            let most = limit / 0.105 // the overshoot is about 0.105 × the excess
            guard abs(excess) > most else { return v0 }
            return (4 * d + (excess < 0 ? -most : most)) / T
        }
        v.x = capped(v.x, dx, limit: Self.maxOvershoot * k)
        v.y = capped(v.y, to.y - from.y, limit: Self.maxOvershoot * k)
        if let yRange { v.y = Self.keep(ThrowFlight(from: from, to: to, velocity: v, duration: T), in: yRange) }
        self.velocity = v
        self.duration = T
    }

    private init(from: Vector, to: Vector, velocity: Vector, duration: Double) {
        self.from = from; self.to = to; self.velocity = velocity; self.duration = duration
    }

    /// The vertical speed scaled down until the path stays inside `range`.
    private static func keep(_ flight: ThrowFlight, in range: ClosedRange<Double>) -> Double {
        var vy = flight.velocity.y
        for _ in 0..<8 {
            let test = ThrowFlight(from: flight.from, to: flight.to, velocity: Vector(flight.velocity.x, vy), duration: flight.duration)
            let ys = (0...24).map { test.position(at: flight.duration * Double($0) / 24).y }
            guard let low = ys.min(), let high = ys.max(),
                  low < range.lowerBound - 0.5 || high > range.upperBound + 0.5 else { return vy }
            vy *= 0.6
        }
        return 0
    }

    private static func axis(_ p0: Double, _ target: Double, _ v0: Double, _ T: Double, _ u: Double) -> (Double, Double) {
        let d = target - p0, b = 3 * d - v0 * T, w = 1 - u
        let position = target - w * w * w * (d + b * u)
        // d/dt = (3w²(d + bu) − w³b) / T
        let speed = (3 * w * w * (d + b * u) - w * w * w * b) / T
        return (position, speed)
    }

    /// Where the card is `t` seconds after the release; the target from `duration` on.
    public func position(at t: Double) -> Vector {
        guard duration > 0, t < duration else { return to }
        let u = max(0, t) / duration
        return Vector(Self.axis(from.x, to.x, velocity.x, duration, u).0, Self.axis(from.y, to.y, velocity.y, duration, u).0)
    }

    /// Its velocity then, points per second.
    public func velocity(at t: Double) -> Vector {
        guard duration > 0, t < duration else { return Vector(0, 0) }
        let u = max(0, t) / duration
        return Vector(Self.axis(from.x, to.x, velocity.x, duration, u).1, Self.axis(from.y, to.y, velocity.y, duration, u).1)
    }

    /// 0 at the release to 1 at the landing, along the throw's main axis
    /// (the card's own progress toward the spot), never past 1.
    public func progress(at t: Double) -> Double {
        let total = to.x - from.x
        guard abs(total) > 1 else { return min(1, max(0, t / max(0.001, duration))) }
        return min(1, max(0, (position(at: t).x - from.x) / total))
    }

    /// The phone's exit height (0 top to 1 bottom) as the card's middle on a
    /// screen whose usable span is `range` (y up), kept inside it.
    public static func entryY(exitY: Double, in range: ClosedRange<Double>) -> Double {
        let y = range.upperBound - min(1, max(0, exitY)) * (range.upperBound - range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, y))
    }
}
