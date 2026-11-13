//
//  SkyEffects.swift
//  DropPortalCore
//
//  The maths Stardust and Lightning share between the phone and the Mac,
//  free of AppKit so the tests can check it: the motion curves, Stardust's
//  release and arrival times, the lightning bolt (midpoint displacement with
//  branches, built once per strike on the CPU), the strike's timeline and the
//  three-flashes-a-second cap. Every grain and every bolt vertex is a function
//  of (id, time, seed); nothing is integrated frame to frame.
//
//  Stardust follows the published idea of Telegram's dust effect (a noisy
//  release front, grains that dwindle to a pixel, one in ten glittering);
//  none of its code, which is GPL.
//

import Foundation

// MARK: - Curves

public enum SkyCurve {
    /// `cubic-bezier(x1, y1, x2, y2)` at `x` (0…1), x solved by bisection.
    public static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = min(1, max(0, x))
        var lo = 0.0, hi = 1.0, u = 0.5
        for _ in 0..<24 {
            u = (lo + hi) / 2
            let v = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            if v < x { lo = u } else { hi = u }
        }
        return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }

    /// Material's emphasized accelerate, `cubic-bezier(0.3, 0, 0.8, 0.15)`: leaving (the phone).
    public static func accelerate(_ x: Double) -> Double { bezier(x, 0.3, 0, 0.8, 0.15) }
    /// Material's emphasized decelerate, `cubic-bezier(0.05, 0.7, 0.1, 1)`: arriving (the Mac).
    public static func decelerate(_ x: Double) -> Double { bezier(x, 0.05, 0.7, 0.1, 1) }
}

// MARK: - Hash

/// The shaders' integer hash (the same lines are in the Metal source), so a
/// grain's numbers can be checked here.
public enum SkyHash {
    public static func uint(_ n: UInt32) -> UInt32 {
        var x = n &* 747_796_405 &+ 2_891_336_453
        x = ((x >> ((x >> 28) &+ 4)) ^ x) &* 277_803_737
        return (x >> 22) ^ x
    }

    /// 0 ≤ value < 1.
    public static func unit(_ n: UInt32) -> Double { Double(uint(n)) / 4_294_967_296 }
}

// MARK: - Stardust

public enum Stardust {
    // The phone: the release front sweeps the card left to right.
    /// Seconds the release front takes to cross the card.
    public static let sweepSeconds = 0.7
    /// Released grains blow left at 300 to 800 pt/s.
    public static let wind: ClosedRange<Double> = 300...800
    /// A released grain dwindles from this size (pt) to one physical pixel over 0.5 to 1.3 s.
    public static let grainSize: ClosedRange<Double> = 0.6...1.8
    public static let dwindle: ClosedRange<Double> = 0.5...1.3
    /// Grains within this distance (pt) ahead of the front shiver by `shiver` pt.
    public static let shiverReach = 16.0, shiver = 0.4
    /// About one grain in ten glitters, at about 6 Hz.
    public static let glitterShare = 0.1, twinkleHz = 6.0

    // The Mac: the same function read backwards, as an arrival.
    /// After the release the filler stardust holds the edge alone this long.
    public static let holdSeconds = 0.05
    /// Launches are spread over this many seconds (right side of the card first).
    public static let launchSpread = 0.18
    /// Each image grain flies 450 to 550 ms (the spec allows up to 600).
    public static let flight: ClosedRange<Double> = 0.45...0.55
    /// The last 20 % of a grain's flight grows it from a dot back to a square.
    public static let growFrom = 0.8
    /// The real picture crossfades in over the last 120 ms, from 1.02 to 1.0.
    public static let handoffSeconds = 0.12, handoffScale = 1.02
    /// The one EDR glint at the landing: peak multiple of SDR white, and its length.
    public static let glintPeak = 3.0, glintSeconds = 0.15
    /// The landed card takes clicks and drags this long after the release,
    /// under grains still flying (it shows only with the handoff).
    public static let interactiveAt = 0.4
    /// Release to the Mac card's landing: hold, the launch spread and the longest flight.
    public static var macFlight: Double { holdSeconds + launchSpread + flight.upperBound }

    /// The phone: when a grain lets go, 0 to 1 (times `sweepSeconds`). `x` is
    /// 0 at the card's left edge, `shape` the two-octave noise and `scatter`
    /// the grain's own hash, both 0 to 1.
    public static func release(x: Double, shape: Double, scatter: Double) -> Double {
        0.5 * x + 0.2 * shape + 0.3 * scatter
    }

    /// The Mac: the same front read as an arrival: the right side, nearest the
    /// incoming stream, forms first.
    public static func arrival(x: Double, shape: Double, scatter: Double) -> Double {
        0.5 * (1 - x) + 0.2 * shape + 0.3 * scatter
    }

    /// Two octaves of smooth value noise over the card (0 to 1), the `shape` of both functions.
    public static func shape(x: Double, y: Double) -> Double {
        (sin(x * 12 + y * 9) + cos(y * 17 - x * 5) + 2) / 4
    }

    /// One Mac grain at `t` seconds after the release: nil before it launches,
    /// else its flight progress (0…1, eased by `decelerate`), its size from
    /// dot (0) to square (1), and how much of the curl offset is left.
    public static func macGrain(x: Double, y: Double, scatter: Double, length: Double, at t: Double)
        -> (progress: Double, size: Double, curl: Double)? {
        let start = holdSeconds + launchSpread * arrival(x: x, shape: shape(x: x, y: y), scatter: scatter)
        guard t >= start else { return nil }
        let d = flight.lowerBound + (flight.upperBound - flight.lowerBound) * length
        let u = min(1, (t - start) / d)
        let e = SkyCurve.decelerate(u)
        return (e, max(0, min(1, (u - growFrom) / (1 - growFrom))), 1 - e)
    }

    /// Grains for a card of `width` × `height` points: one per `step` × `step`
    /// points, step 1 (Mac, newer phones) or 2 (iPhone 11 class), halved again
    /// while the count is over `budget`.
    public static func grid(width: Double, height: Double, step: Double, budget: Int) -> (columns: Int, rows: Int) {
        var s = max(0.5, step)
        while true {
            let c = max(1, Int((width / s).rounded())), r = max(1, Int((height / s).rounded()))
            if c * r <= budget { return (c, r) }
            s *= 2.0.squareRoot()
        }
    }

    /// The glint's multiple of SDR white `t` seconds after the landing: up to
    /// `glintPeak`, never above the screen's headroom, back to 1 by `glintSeconds`.
    public static func glint(at t: Double, headroom: Double) -> Double {
        guard t >= 0, t < glintSeconds else { return 1 }
        let peak = min(max(1, headroom), glintPeak)
        let rise = 0.03
        let k = t < rise ? t / rise : exp(-(t - rise) / 0.035) * (1 - (t - rise) / (glintSeconds - rise))
        return 1 + (peak - 1) * max(0, k)
    }
}

// MARK: - Lightning bolt

/// One bolt from `from` to `to`: a trunk by midpoint displacement and a few
/// branches. Points are in the caller's space; `along` is 0 at `from` and 1
/// at `to` (a branch carries the trunk's value where it leaves, growing a
/// little along its length), for the leader drawing on in steps.
public struct LightningBolt: Sendable {
    public struct Point: Sendable, Equatable {
        public var x: Double, y: Double, along: Double
    }
    public struct Line: Sendable {
        public var points: [Point]
        /// 1 for the trunk, 0.4 to 0.6 for a branch (its width and brightness).
        public var weight: Double
    }

    public let trunk: Line
    public let branches: [Line]
    public var lines: [Line] { [trunk] + branches }

    /// `generations` halvings (5 or 6: 33 or 65 trunk points), `branches` 2 to 4
    /// at about ±30°, each 0.6 to 0.7 of the length left, from the first three
    /// generations' midpoints. `sway` is the first offset, a fraction of the length.
    public init(from: (x: Double, y: Double), to: (x: Double, y: Double), seed: UInt32,
                generations: Int = 5, branches: Int = 3, sway: Double = 0.16) {
        var rng = SkyRandom(seed: seed)
        let dx = to.x - from.x, dy = to.y - from.y, length = max(1, (dx * dx + dy * dy).squareRoot())
        var points = [Point(x: from.x, y: from.y, along: 0), Point(x: to.x, y: to.y, along: 1)]
        var offset = sway * length
        // Where branches may leave: midpoints of the early generations.
        var candidates: [Point] = []
        let gens = min(6, max(5, generations))
        for gen in 0..<gens {
            var next: [Point] = [points[0]]
            next.reserveCapacity(points.count * 2)
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                let sx = b.x - a.x, sy = b.y - a.y, sl = max(1e-6, (sx * sx + sy * sy).squareRoot())
                let o = (rng.next() * 2 - 1) * offset
                // Perpendicular to the segment; the ends stay pinned (the target is a moving card).
                let mid = Point(x: (a.x + b.x) / 2 - sy / sl * o, y: (a.y + b.y) / 2 + sx / sl * o, along: (a.along + b.along) / 2)
                next.append(mid)
                next.append(b)
            }
            points = next
            offset /= 2
            // Points never move once made, so the early midpoints stay on the trunk.
            if gen < 3 { candidates += stride(from: 1, to: points.count - 1, by: 2).map { points[$0] } }
        }
        trunk = Line(points: points, weight: 1)
        // Branches from distinct points in the first two thirds, alternating sides.
        var made: [Line] = []
        let count = min(4, max(2, branches))
        let usable = candidates.filter { $0.along > 0.12 && $0.along < 0.7 }
        var picks: [Point] = []
        var pool = usable
        while picks.count < count, !pool.isEmpty {
            let i = Int(rng.next() * Double(pool.count)) % pool.count
            picks.append(pool.remove(at: i))
        }
        picks.sort { $0.along < $1.along }
        let heading = atan2(dy, dx)
        for (n, start) in picks.enumerated() {
            let side: Double = n % 2 == 0 ? 1 : -1
            let angle = heading + side * (Double.pi / 6) * (0.8 + 0.4 * rng.next())
            let scale = 0.6 + 0.1 * rng.next()
            let reach = length * (1 - start.along) * scale * 0.55
            let end = (x: start.x + cos(angle) * reach, y: start.y + sin(angle) * reach)
            let sub = LightningBolt.branch(from: start, to: end, rng: &rng, generations: 4, sway: sway * 0.8)
            made.append(Line(points: sub, weight: 0.4 + 0.2 * rng.next()))
        }
        self.branches = made
    }

    private static func branch(from a: Point, to end: (x: Double, y: Double), rng: inout SkyRandom, generations: Int, sway: Double) -> [Point] {
        let dx = end.x - a.x, dy = end.y - a.y, length = max(1, (dx * dx + dy * dy).squareRoot())
        var points = [a, Point(x: end.x, y: end.y, along: a.along + 0.25)]
        var offset = sway * length
        for _ in 0..<generations {
            var next: [Point] = [points[0]]
            for i in 0..<(points.count - 1) {
                let p = points[i], q = points[i + 1]
                let sx = q.x - p.x, sy = q.y - p.y, sl = max(1e-6, (sx * sx + sy * sy).squareRoot())
                let o = (rng.next() * 2 - 1) * offset
                next.append(Point(x: (p.x + q.x) / 2 - sy / sl * o, y: (p.y + q.y) / 2 + sx / sl * o, along: (p.along + q.along) / 2))
                next.append(q)
            }
            points = next
            offset /= 2
        }
        return points
    }
}

/// A small deterministic generator (the same seed, the same bolt).
public struct SkyRandom: Sendable {
    private var state: UInt32
    public init(seed: UInt32) { state = seed == 0 ? 0x9E37_79B9 : seed }
    /// 0 ≤ value < 1.
    public mutating func next() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return SkyHash.unit(state)
    }
}

// MARK: - The strike

/// One strike's timeline, seconds since the release: the leader draws on in
/// four steps, the return stroke is the one bright beat, then one weaker
/// re-strike and an afterglow; nothing is left by `end`.
public enum LightningStrike {
    /// The leader: four steps of 15 ms at 35 %.
    public static let leaderSeconds = 0.06, leaderSteps = 4, leaderLevel = 0.35
    /// The return stroke (the flash): from the leader's end, 25 ms (two to three frames at 120 Hz, one to two at 60).
    public static let strokeSeconds = 0.025
    /// The Mac card rides the bolt in and lands as the stroke ends.
    public static var macFlight: Double { leaderSeconds + strokeSeconds }
    /// One re-strike, 90 ms after the stroke starts, at 60 %: two flashes a
    /// strike, so a second send within a second still gets one under the cap.
    public static let restrikes: [(at: Double, level: Double)] = [(0.09, 0.6)]
    /// The afterglow's time constant (about 0.88 a frame at 120 Hz), and the end.
    public static let tau = 0.1, end = 0.45
    /// Everything that may flash in one strike: the stroke and the re-strikes.
    public static var flashesPerStrike: Int { 1 + restrikes.count }

    /// How much of the trunk the leader shows: 1/4, 2/4… in steps, 1 from the stroke.
    public static func reveal(at t: Double) -> Double {
        guard t < leaderSeconds else { return 1 }
        let step = floor(max(0, t) / (leaderSeconds / Double(leaderSteps))) + 1
        return min(1, step / Double(leaderSteps))
    }

    /// The bolt's brightness at `t` (a multiple of SDR white, 1 is the
    /// stroke's peak before EDR) and which bolt shows (0 the first, 1 the
    /// re-strike's new seed). `allowed[i]` says whether flash `i` (the
    /// stroke, then each re-strike) passed the cap; a refused one stays at
    /// the leader's level so it never swings the screen's luminance.
    public static func level(at t: Double, allowed: [Bool]) -> (level: Double, flash: Bool, bolt: Int) {
        guard t >= 0, t < end else { return (0, false, 0) }
        let fade = t < end - 0.1 ? 1 : max(0, (end - t) / 0.1)
        if t < leaderSeconds { return (leaderLevel * fade, false, 0) }
        let s = t - leaderSeconds
        var bolt = 0
        var flash = false
        var level = 0.0
        // The stroke, then its afterglow.
        if s < strokeSeconds {
            if allowed.first ?? false { level = 1; flash = true } else { level = leaderLevel }
        } else {
            level = (allowed.first ?? false ? 0.7 : leaderLevel) * exp(-(s - strokeSeconds) / tau)
        }
        for (i, r) in restrikes.enumerated() where s >= r.at {
            bolt = i + 1
            let ok = allowed.count > i + 1 ? allowed[i + 1] : false
            guard ok else { continue }
            let since = s - r.at
            if since < strokeSeconds { level = max(level, r.level); flash = true } else {
                level = max(level, 0.7 * r.level * exp(-(since - strokeSeconds) / tau))
            }
        }
        return (min(1, level) * fade, flash, bolt)
    }
}

// MARK: - The flash cap

/// WCAG 2.3.1: at most three general flashes in any one second. Every strike
/// asks before each flash, and a refused flash is drawn at the leader's dim
/// level. Shared by every strike in the process.
public struct FlashLimiter: Sendable {
    public static let maxPerSecond = 3
    private var times: [Double] = []
    public init() {}

    /// Whether a flash may start at `now` (seconds, any monotonic clock); records it when yes.
    /// Strikes book their flashes ahead, so a flash is refused while three
    /// others lie within a second of it on either side: then no one-second
    /// window that holds it can hold four.
    public mutating func allow(at now: Double) -> Bool {
        let latest = max(now, times.max() ?? now)
        times.removeAll { latest - $0 >= 2 }
        guard times.filter({ abs($0 - now) < 1 }).count < Self.maxPerSecond else { return false }
        times.append(now)
        return true
    }

    /// The flashes counted in the second before `now`.
    public func count(at now: Double) -> Int { times.filter { now - $0 < 1 && $0 <= now }.count }

    /// One strike starting at `start`: asks for each of its flashes at the moment it would start.
    public mutating func plan(strikeAt start: Double) -> [Bool] {
        let at = [LightningStrike.leaderSeconds] + LightningStrike.restrikes.map { LightningStrike.leaderSeconds + $0.at }
        return at.map { allow(at: start + $0) }
    }
}

// MARK: - Colour

public enum SkyColor {
    /// Lightning's halo from the effect's colour: never red (hue kept 25° or
    /// more from it) and desaturated toward ice-blue/lavender (0.9, 0.8, 1.0),
    /// saturation at most 0.45. Rainbow's hues pass through the same rule.
    public static func lightningSafe(_ c: PortalRGB) -> PortalRGB {
        var (h, s, v) = hsv(c)
        let deg = h * 360
        // Red sits at 0°/360°; push it out to 25° (orange-amber) or 335° (pink-violet).
        if deg < 25 { h = deg < 12 ? 335 / 360 : 25 / 360 } else if deg > 335 { h = 335 / 360 }
        s = min(s, 0.45)
        v = max(v, 0.9)
        let safe = PortalRGB(hue: h, saturation: s, value: v)
        return safe.mixed(with: PortalRGB(red: 0.9, green: 0.8, blue: 1.0), 0.35)
    }

    /// Whether a colour reads as saturated red (the case WCAG treats strictest).
    public static func isSaturatedRed(_ c: PortalRGB) -> Bool {
        let (h, s, _) = hsv(c)
        let deg = h * 360
        return (deg < 20 || deg > 340) && s > 0.5
    }

    static func hsv(_ c: PortalRGB) -> (Double, Double, Double) {
        let mx = max(c.red, c.green, c.blue), mn = min(c.red, c.green, c.blue), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.red { h = (c.green - c.blue) / d } else if mx == c.green { h = 2 + (c.blue - c.red) / d } else { h = 4 + (c.red - c.green) / d }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}
