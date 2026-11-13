//
//  Couriers.swift
//  DropPortalCore
//
//  What the four courier effects share between the phone and the Mac, free
//  of AppKit so the tests can check it: each courier's beats (the approved
//  mockup's, `.droppykit/design/fx-mockups-cute-v2/`), the variant a seed
//  picks (jitter, the rare gag, the blinks), the short version for a quick
//  second flick, and how many ducklings march.
//
//  The phone makes the seed when a drag starts and sends it in `peek-start`
//  (`seed`, `short`); the Mac plays the same variant from it. The page has
//  the same generator in `WebCourierEffect.swift` (`Math.imul`, so both
//  sides wrap the same 32-bit product).
//

import Foundation

/// The four characters, one per courier effect.
public enum Courier: String, CaseIterable, Sendable {
    /// Pip the hamster: stuffs the card into a cheek, tumbles in, "ptoo".
    case cheek
    /// Tofu the cat: leaps through a cat flap with the card in its mouth.
    case pounce
    /// Digby the mole: tunnels across with the card on his helmet.
    case mole
    /// The Matcha Trio: ducklings march the card across on their caps.
    case ducks

    public var effect: PortalEffect {
        switch self {
        case .cheek: .cheek
        case .pounce: .pounce
        case .mole: .mole
        case .ducks: .ducks
        }
    }

    /// The character's name, for the picker.
    public var who: String {
        switch self {
        case .cheek: "Pip"
        case .pounce: "Tofu"
        case .mole: "Digby"
        case .ducks: "Matcha Trio"
        }
    }

    /// The stem of the character's own files: `Sources/DropPortal/Couriers/<stem>Courier.swift`
    /// and `Sources/DropPortalCore/WebCourier<stem>.swift`.
    public var stem: String {
        switch self {
        case .cheek: "Pip"
        case .pounce: "Tofu"
        case .mole: "Digby"
        case .ducks: "Matcha"
        }
    }

    /// The character's main colour, for the placeholder and the sticker's rim.
    public var color: UInt32 {
        switch self {
        case .cheek: 0xF2A65A
        case .pounce: 0xF2A03D
        case .mole: 0x7A5A48
        case .ducks: 0xA8D08D
        }
    }

    // MARK: Beats (milliseconds after the bytes arrive on the Mac, T = 0)

    /// L: the card reaches its spot and pops.
    public var landingMS: Double {
        switch self {
        case .cheek: 520
        case .pounce: 480
        case .mole: 500
        case .ducks: 560
        }
    }

    /// The courier's little moment after L ends here and it starts to leave.
    public var exitMS: Double {
        switch self {
        case .cheek: 760
        case .pounce: 680
        case .mole: 700
        case .ducks: 760
        }
    }

    /// The courier is gone: L + 0.55 s (the mockup's END).
    public var goneMS: Double {
        switch self {
        case .cheek: 1070
        case .pounce: 1030
        case .mole: 1050
        case .ducks: 1110
        }
    }

    /// The phone's edge is clear this long after the release.
    public var phoneClearMS: Double {
        switch self {
        case .cheek: 420
        case .pounce: 520
        case .mole: 450
        case .ducks: 420
        }
    }

    /// One in this many crossings plays the rare gag; 0 = none. Only the two
    /// gags the user approved in the mockup: a seed drops from Pip's cheek
    /// (1 in 8) and the last duckling trips (1 in 4).
    public var gagOneIn: Int {
        switch self {
        case .cheek: 8
        case .ducks: 4
        case .pounce, .mole: 0
        }
    }

    // MARK: Shared numbers

    /// The landed card takes clicks and drags this long after the bytes arrive.
    public static let interactiveAt = 0.4
    /// A flick this soon after the last one plays the short version.
    public static let shortWindow: TimeInterval = 10
    /// The short version: the courier skips its moment and leaves this long after L.
    public static let shortIdleMS = 150.0
    /// A click on the courier: the card snaps to its spot and the courier fades this fast.
    public static let skipMS = 120.0
    /// Each beat's time is scaled by a random 1 ± this (arc heights and wobbles).
    public static let jitter = 0.15
    /// Reduce motion: the courier is a sticker on the landed card. It fades in
    /// and out this fast, blinks once this long after it shows, and starts
    /// to fade out this long after it shows.
    public static let stickerFadeMS = 160.0
    public static let stickerBlinkMS = 320.0
    public static let stickerHoldMS = 1100.0
    /// The phone's courier fades this fast when the drag is cancelled.
    public static let cancelFadeMS = 140.0
    /// Ducklings: one per file, at least the trio and at most five.
    public static let ducklingRange = 3...5

    /// Ducklings that march for `files` files.
    public static func ducklings(files: Int) -> Int {
        min(ducklingRange.upperBound, max(ducklingRange.lowerBound, files))
    }

    /// When duckling `index` of `count` pops in under the card while held (p).
    /// The trio's are the mockup's .2, .45 and .7; more spread over the same span.
    public static func ducklingStart(_ index: Int, of count: Int) -> Double {
        guard count > 1 else { return 0.2 }
        return 0.2 + 0.5 * Double(index) / Double(count - 1)
    }
}

extension PortalEffect {
    /// The courier this effect is, or nil for the light effects.
    public var courier: Courier? {
        switch self {
        case .cheek: .cheek
        case .pounce: .pounce
        case .mole: .mole
        case .ducks: .ducks
        default: nil
        }
    }

    /// The four cartoon couriers: their own timeline on both sides, no throw,
    /// no edge light, and the Mac waits at the edge until the bytes arrive.
    public var isCourier: Bool { courier != nil }
}

// MARK: - Random

/// xorshift32 from a seed, the same numbers as `rng()` in the page.
public struct CourierRandom: Sendable {
    private var state: UInt32

    public init(seed: UInt32) {
        let mixed = seed &* 2_654_435_761
        state = mixed == 0 ? 1 : mixed
    }

    /// 0 ≤ value < 1.
    public mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(state) / 4_294_967_296
    }
}

// MARK: - The variant

/// One crossing's variant: the same on both screens when they share `seed`.
public struct CourierPlan: Equatable, Sendable {
    public let courier: Courier
    public let seed: UInt32
    /// A quick second flick: no moment after L, the courier leaves at once.
    public let short: Bool
    /// Ducklings marching (Duckling Parade), else 1.
    public let actors: Int
    /// 1 ± `Courier.jitter`: arc heights and wobbles.
    public let jitter: Double
    /// The rare gag plays this time.
    public let gag: Bool
    /// The blinks' own seed.
    public let blinkSeed: UInt32

    public init(courier: Courier, seed: UInt32, short: Bool = false, files: Int = 1) {
        self.courier = courier
        self.seed = seed
        self.short = short
        actors = courier == .ducks ? Courier.ducklings(files: files) : 1
        var r = CourierRandom(seed: seed)
        jitter = 1 - Courier.jitter + 2 * Courier.jitter * r.next()
        let roll = r.next()
        gag = courier.gagOneIn > 0 && roll < 1 / Double(courier.gagOneIn)
        blinkSeed = UInt32(r.next() * 4_294_967_296) | 1
    }

    /// A seed for a crossing the phone did not seed (an older page, a file with no peek).
    public static func randomSeed() -> UInt32 { UInt32.random(in: 1...UInt32.max) }

    /// Whether a flick at `now` follows the last one closely enough for the short version.
    public static func isShort(lastFlick: Date?, now: Date = Date()) -> Bool {
        guard let lastFlick else { return false }
        let gap = now.timeIntervalSince(lastFlick)
        return gap >= 0 && gap < Courier.shortWindow
    }

    // MARK: Clock

    /// L in milliseconds after the bytes arrive.
    public var landingMS: Double { courier.landingMS }

    /// The courier is gone, ms after the bytes arrive: L + 0.55 s, or for the
    /// short version L + 150 ms plus the walk out. Duckling Parade's extra
    /// ducklings leave 60 ms apart.
    public var goneMS: Double {
        let extra = courier == .ducks ? 60 * Double(max(0, actors - 3)) : 0
        return (short ? courier.landingMS + Courier.shortIdleMS + (courier.goneMS - courier.exitMS) : courier.goneMS) + extra
    }

    /// The mockup's clock for real time `ms` after the bytes arrive. Up to L
    /// they are the same; the short version squeezes the moment after L
    /// (L … exit) into 150 ms and then walks out at the normal pace.
    public func clock(_ ms: Double) -> Double {
        guard short, ms > courier.landingMS else { return ms }
        let L = courier.landingMS, idle = courier.exitMS - L
        if ms < L + Courier.shortIdleMS { return L + (ms - L) * idle / Courier.shortIdleMS }
        return courier.exitMS + (ms - L - Courier.shortIdleMS)
    }

    // MARK: Blinks

    /// The blinks' start times in ms (from the clock's 0, the hold's start
    /// 600 ms before the release): a first at 0.4–1.8 s, then 2.5 s plus an
    /// exponential with a 2 s mean, kept within 1.5–7 s.
    public func blinkTimes(until end: Double = 6000) -> [Double] {
        var r = CourierRandom(seed: blinkSeed)
        var times: [Double] = []
        var t = 400 + r.next() * 1400
        while t < end {
            times.append(t)
            t += min(7000, max(1500, 2500 - log(1 - r.next()) * 2000))
        }
        return times
    }

    /// How closed the eyes are at `ms` (0 open, 1 shut): close 50 ms, hold 30, open 70.
    public static func lid(_ age: Double) -> Double {
        if age < 0 || age > 150 { return 0 }
        if age < 50 { return pow(pow(age / 50, 3), 0.6) }
        if age < 80 { return 1 }
        let u = (age - 80) / 70
        return 1 - (1 - pow(1 - u, 3))
    }
}
