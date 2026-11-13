//
//  LandingTouches.swift
//  DropPortalCore
//
//  The two landing touches every crossing effect shares, as plain maths
//  (no AppKit), so the Mac, the harness and the tests read the same numbers:
//
//  LandSpring    Apple's spring from a perceptual duration and a bounce
//                (mass 1, k = (2π/d)², c = (1 − bounce)·4π/d), sampled in
//                closed form: the land settle (0.35 s, 0.1) and the cursor
//                tilt (0.25 s, 0).
//  SparkRing     the celebration's ~20 sparks off the card's perimeter, each a
//                pure function of its index and the time.
//  KineticName   the filename's per-letter blur-and-rise: the stagger, each
//                letter's state at a time, and the middle truncation that
//                keeps the extension.
//
//  Spec: .droppykit/design/fx-mockups-2/brief-research.md, "Landing
//  celebration" and "Kinetic filename"; design note in .droppykit/docs/effects.md.
//

import Foundation

// MARK: - Spring

public struct LandSpring: Sendable, Equatable {
    public let duration: Double
    public let bounce: Double

    public init(duration: Double, bounce: Double) {
        self.duration = duration
        self.bounce = bounce
    }

    /// The land settle: not bouncy, a sliver of overshoot for a flicked card (ζ 0.9).
    public static let settle = LandSpring(duration: 0.35, bounce: 0.1)
    /// The cursor tilt: critically damped.
    public static let tilt = LandSpring(duration: 0.25, bounce: 0)

    public var stiffness: Double { pow(2 * .pi / duration, 2) }
    public var damping: Double { (1 - bounce) * 4 * .pi / duration }
    /// ζ = c / (2√k).
    public var dampingRatio: Double { damping / (2 * stiffness.squareRoot()) }

    /// How far from rest at `t`, starting at 1 (and at rest velocity `v0`, in
    /// units of the distance per second): 1 → 0, closed form.
    public func remaining(at t: Double, velocity v0: Double = 0) -> Double {
        guard t > 0 else { return 1 }
        let w0 = stiffness.squareRoot(), z = dampingRatio
        // x(0) = 1, x'(0) = v0 (toward rest is negative).
        if z < 1 {
            let wd = w0 * (1 - z * z).squareRoot()
            let a = 1.0, b = (v0 + z * w0) / wd
            return exp(-z * w0 * t) * (a * cos(wd * t) + b * sin(wd * t))
        }
        return exp(-w0 * t) * (1 + (v0 + w0) * t)
    }

    /// From 0 to 1 over time.
    public func progress(at t: Double) -> Double { 1 - remaining(at: t) }

    /// When it is within 0.1 % of rest for good (what CASpringAnimation calls the settling duration).
    public var settlingDuration: Double {
        let w0 = stiffness.squareRoot(), z = dampingRatio
        // The envelope e^(−ζω₀t)·(1 + ζω₀t·…) below 0.001: a bound with a little room.
        return z < 1 ? log(1000 / (1 - z * z).squareRoot()) / (z * w0) : (log(1000) + 2.2) / w0
    }

    /// One step of the same spring toward `target`, semi-implicit Euler (the
    /// tilt retargets every pointer move, so it is integrated, not keyed).
    public func step(value: inout Double, velocity: inout Double, target: Double, dt: Double) {
        let accel = stiffness * (target - value) - damping * velocity
        velocity += accel * dt
        value += velocity * dt
    }
}

// MARK: - Sparks

/// The celebration's ring: sparks spawned in one frame on the card's
/// perimeter, moving straight out at 180–320 pt/s with drag e^(−4t), no
/// gravity, 2–5 pt in radius (as the approved mockup draws them) shrinking
/// to nothing over 0.45–0.7 s, additive.
public struct SparkRing: Sendable {
    public struct Spark: Sendable, Equatable {
        /// Start on the perimeter, from the card's centre, points, y up.
        public var start: SIMD2<Double>
        /// Unit direction, outward.
        public var direction: SIMD2<Double>
        public var speed: Double
        public var life: Double
        public var size: Double
        /// 0 or 1: the photo's first or second hue.
        public var tone: Int
    }

    public static let drag = 4.0
    public static let lifeRange = 0.45...0.7
    public static let speedRange = 180.0...320.0
    public static let sizeRange = 2.0...5.0
    /// The whole burst is over by then.
    public static var seconds: Double { lifeRange.upperBound }

    public let sparks: [Spark]

    /// `count` sparks around a card of `size` (points), the same for the same seed.
    public init(count: Int = 20, size: CGSize, cornerRadius: Double = 18, seed: UInt64 = 7) {
        var rng = SplitMix(seed)
        let hw = Double(size.width) / 2, hh = Double(size.height) / 2
        var out: [Spark] = []
        out.reserveCapacity(count)
        for i in 0..<max(0, count) {
            // Evenly round the ring with a little jitter, so no gap and no clump.
            let a = (Double(i) + 0.5 + (rng.next() - 0.5) * 0.7) / Double(count) * 2 * .pi
            let d = SIMD2(cos(a), sin(a))
            // Where the ray from the centre leaves the rounded rectangle.
            let start = Self.edge(direction: d, hw: hw, hh: hh, r: cornerRadius)
            out.append(Spark(start: start, direction: d,
                             speed: Self.lerp(Self.speedRange, rng.next()),
                             life: Self.lerp(Self.lifeRange, rng.next()),
                             size: Self.lerp(Self.sizeRange, rng.next()),
                             tone: i % 2))
        }
        sparks = out
    }

    /// One spark at `t` seconds: where (from the card's centre), how big and how bright; nil once gone.
    public static func state(_ s: Spark, at t: Double) -> (position: SIMD2<Double>, size: Double, alpha: Double)? {
        guard t >= 0, t < s.life else { return nil }
        let travel = s.speed * (1 - exp(-drag * t)) / drag
        let u = t / s.life
        return (s.start + s.direction * travel, s.size * (1 - u), (1 - u) * (u < 0.04 ? u / 0.04 : 1))
    }

    /// The furthest any spark gets from the perimeter (v/4 at most): the room it needs.
    public static var reach: Double { speedRange.upperBound / drag + sizeRange.upperBound }

    /// Fewer sparks when the Mac asks to save power; 20 otherwise (the spec's 20 ± 6).
    public static func count(lowPower: Bool) -> Int { lowPower ? 14 : 20 }

    static func edge(direction d: SIMD2<Double>, hw: Double, hh: Double, r: Double) -> SIMD2<Double> {
        let tx = abs(d.x) > 1e-9 ? hw / abs(d.x) : .infinity
        let ty = abs(d.y) > 1e-9 ? hh / abs(d.y) : .infinity
        var p = d * min(tx, ty)
        // In a corner: onto the rounding's arc.
        let r = min(r, hw, hh), cx = hw - r, cy = hh - r
        if abs(p.x) > cx, abs(p.y) > cy {
            let c = SIMD2(cx * (p.x < 0 ? -1 : 1), cy * (p.y < 0 ? -1 : 1))
            // Solve |t·d − c| = r for the far root.
            let b = (d * c).sum(), cc = (c * c).sum() - r * r
            let disc = max(0, b * b - cc)
            p = d * (b + disc.squareRoot())
        }
        return p
    }

    static func lerp(_ r: ClosedRange<Double>, _ u: Double) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * u }
}

/// A tiny seeded generator, so a spark ring is the same in every shot.
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

// MARK: - Kinetic filename

public enum KineticName {
    /// Each letter's own animation.
    public static let element = 0.32
    /// The whole name is in by this.
    public static let cap = 0.65
    /// Blur at the start, points (the spec's 2–4 px at 13 pt).
    public static let blur = 3.0
    /// The rise, points (from about the descent).
    public static let rise = 4.5
    /// Extra spacing at the start, in ems, closing to 0 underneath.
    public static let tracking = 0.08
    /// The rise's spring: bounce at most 0.1.
    public static let spring = LandSpring(duration: 0.32, bounce: 0.08)
    /// Reduce motion: the whole label fades over this.
    public static let calmFade = 0.2
    /// The extension's letters, a little dimmer.
    public static let extensionAlpha = 0.62

    /// The gap between letters: min(25 ms, 300 ms / n).
    public static func stagger(count n: Int) -> Double { min(0.025, 0.3 / Double(max(1, n))) }

    /// When the last letter has finished.
    public static func total(count n: Int) -> Double {
        element + stagger(count: n) * Double(max(0, n - 1))
    }

    public struct Glyph: Sendable, Equatable {
        public var opacity: Double
        /// Points of blur still on it.
        public var blur: Double
        /// Points below its place (y down is positive here: it rises to 0).
        public var drop: Double
        /// The tracking still under it, in ems per letter before it.
        public var spread: Double
    }

    /// Letter `i` of `n` at `t` seconds after the name starts.
    public static func glyph(_ i: Int, of n: Int, at t: Double) -> Glyph {
        let local = t - Double(i) * stagger(count: n)
        let p = min(1, max(0, local / element))
        // easeIn(1.4·p): in by 70 % of its time.
        let o = min(1, 1.4 * p)
        let rest = local <= 0 ? 1 : spring.remaining(at: local)
        return Glyph(opacity: o * o, blur: blur * (1 - easeOut(p)), drop: rise * rest,
                     spread: tracking * (1 - easeOut(p)))
    }

    /// The label as a whole under Reduce motion: opacity only.
    public static func calmOpacity(at t: Double) -> Double { min(1, max(0, t / calmFade)) }

    static func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }

    /// The extension a name keeps when it is cut: ".heic", ".tar.gz" counts
    /// as ".gz"; nothing for a dot file, a name ending in a dot, or a "dot"
    /// more than 9 characters from the end (that is not an extension).
    public static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[dot...])
        guard ext.count >= 2, ext.count <= 9, !ext.contains(" ") else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    /// Cuts `name` in the middle, keeping its extension, until `width(s)` fits
    /// `maxWidth`: "IMG_4821 summer trip….HEIC". The result is what gets split
    /// into letters, so the ellipsis is one letter of it.
    public static func truncate(_ name: String, maxWidth: Double, width: (String) -> Double) -> String {
        guard width(name) > maxWidth else { return name }
        let (base, ext) = splitExtension(name)
        let letters = Array(base)
        // Head and tail of the base around the ellipsis; the head keeps a little more.
        var keep = letters.count
        while keep > 0 {
            keep -= 1
            let head = (keep + 1) / 2 + (keep > 6 ? 1 : 0), tail = max(0, keep - head)
            // No space hugs the ellipsis.
            let front = String(letters.prefix(min(head, keep))).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let back = String(letters.suffix(tail)).replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
            let cut = front + "…" + back + ext
            if width(cut) <= maxWidth { return cut }
        }
        // Even "….ext" is too wide: the extension goes too, tail first.
        var short = Array("…" + ext)
        while short.count > 1, width(String(short)) > maxWidth { short.removeLast() }
        return String(short)
    }

    /// Where the extension starts in a (possibly cut) label, as a letter index; nil without one.
    public static func extensionStart(in label: String) -> Int? {
        let (_, ext) = splitExtension(label)
        guard !ext.isEmpty else { return nil }
        return label.count - ext.count
    }
}
