import XCTest
@testable import DropPortalCore

final class CouriersTests: XCTestCase {
    // MARK: Effects

    func testFourCourierEffectsAndTheirNames() {
        let couriers = PortalEffect.allCases.filter(\.isCourier)
        XCTAssertEqual(couriers, [.cheek, .pounce, .mole, .ducks])
        XCTAssertEqual(couriers.map { $0.courier?.who }, ["Pip", "Tofu", "Digby", "Matcha Trio"])
        for c in Courier.allCases {
            XCTAssertEqual(c.effect.courier, c)
            XCTAssertTrue(c.effect.title.contains(c.who))
            XCTAssertEqual(PortalEffect(stored: c.rawValue), c.effect)
        }
        // The light effects are not couriers, and stay as they were.
        for e in [PortalEffect.portal, .liquid, .wormhole, .beam, .plane, .stardust, .lightning] {
            XCTAssertNil(e.courier)
            XCTAssertFalse(e.isCourier)
        }
    }

    func testBeatsFollowTheSpec() {
        for c in Courier.allCases {
            // Landing about half a second in; the courier gone 0.55 s after it.
            XCTAssertTrue((480...560).contains(c.landingMS))
            XCTAssertEqual(c.goneMS - c.landingMS, 550, accuracy: 0.5)
            XCTAssertGreaterThan(c.exitMS, c.landingMS)
            XCTAssertLessThan(c.exitMS, c.goneMS)
            // The file is usable before the card lands.
            XCTAssertLessThan(Courier.interactiveAt * 1000, c.landingMS)
        }
    }

    // MARK: Seed

    func testRandomMatchesThePage() {
        // From the page's rng(): Math.imul(seed, 2654435761) then xorshift32.
        let expected: [UInt32: [Double]] = [
            1: [0.317097131396, 0.750677419361, 0.866621796740, 0.560080099618],
            42: [0.706581843551, 0.288634181954, 0.688689631643, 0.866965232417],
            4_000_000_000: [0.871700741118, 0.864543606760, 0.793024417246, 0.281351078069],
        ]
        for (seed, values) in expected {
            var r = CourierRandom(seed: seed)
            for v in values { XCTAssertEqual(r.next(), v, accuracy: 1e-11) }
        }
    }

    func testSameSeedSameVariant() {
        for c in Courier.allCases {
            for seed: UInt32 in [1, 7, 99, 123_456, 4_000_000_000] {
                let a = CourierPlan(courier: c, seed: seed, files: 4), b = CourierPlan(courier: c, seed: seed, files: 4)
                XCTAssertEqual(a, b)
                XCTAssertEqual(a.blinkTimes(), b.blinkTimes())
            }
        }
        // Different seeds give different variants.
        let jitters = Set((1...50).map { CourierPlan(courier: .cheek, seed: UInt32($0)).jitter })
        XCTAssertGreaterThan(jitters.count, 40)
    }

    func testJitterStaysWithinFifteenPercent() {
        var lo = 2.0, hi = 0.0
        for seed in 1...2000 {
            let j = CourierPlan(courier: .pounce, seed: UInt32(seed)).jitter
            lo = min(lo, j); hi = max(hi, j)
        }
        XCTAssertGreaterThanOrEqual(lo, 0.85)
        XCTAssertLessThanOrEqual(hi, 1.15)
        XCTAssertLessThan(lo, 0.87)
        XCTAssertGreaterThan(hi, 1.13)
    }

    func testGagsAtTheSpecsRates() {
        func rate(_ c: Courier) -> Double {
            Double((1...8000).filter { CourierPlan(courier: c, seed: UInt32($0)).gag }.count) / 8000
        }
        XCTAssertEqual(rate(.cheek), 1.0 / 8, accuracy: 0.015)
        XCTAssertEqual(rate(.ducks), 1.0 / 4, accuracy: 0.02)
        XCTAssertEqual(rate(.pounce), 0)
        XCTAssertEqual(rate(.mole), 0)
    }

    func testBlinksAreSpacedLikeAPerson() {
        let times = CourierPlan(courier: .mole, seed: 31).blinkTimes(until: 60_000)
        XCTAssertGreaterThan(times.count, 8)
        XCTAssertTrue((400...1800).contains(times[0]))
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 1500 - 1e-9)
            XCTAssertLessThanOrEqual(b - a, 7000 + 1e-9)
        }
        // Close 50 ms, hold 30, open 70.
        XCTAssertEqual(CourierPlan.lid(-1), 0)
        XCTAssertEqual(CourierPlan.lid(60), 1)
        XCTAssertEqual(CourierPlan.lid(151), 0)
        XCTAssertGreaterThan(CourierPlan.lid(100), 0)
    }

    // MARK: Short version

    func testShortVersionAfterAQuickSecondFlick() {
        let now = Date()
        XCTAssertFalse(CourierPlan.isShort(lastFlick: nil, now: now))
        XCTAssertTrue(CourierPlan.isShort(lastFlick: now.addingTimeInterval(-3), now: now))
        XCTAssertTrue(CourierPlan.isShort(lastFlick: now.addingTimeInterval(-9.9), now: now))
        XCTAssertFalse(CourierPlan.isShort(lastFlick: now.addingTimeInterval(-10), now: now))
        XCTAssertFalse(CourierPlan.isShort(lastFlick: now.addingTimeInterval(5), now: now))
    }

    func testShortVersionTiming() {
        for c in Courier.allCases {
            let long = CourierPlan(courier: c, seed: 5), short = CourierPlan(courier: c, seed: 5, short: true)
            // Same until the landing.
            for ms in stride(from: 0.0, through: c.landingMS, by: 20) {
                XCTAssertEqual(long.clock(ms), ms)
                XCTAssertEqual(short.clock(ms), ms)
            }
            // The moment after L is squeezed into 150 ms, then the walk out runs at its pace.
            XCTAssertEqual(short.clock(c.landingMS + 150), c.exitMS, accuracy: 1e-9)
            XCTAssertEqual(short.clock(c.landingMS + 150 + 100), c.exitMS + 100, accuracy: 1e-9)
            XCTAssertEqual(short.clock(short.goneMS), c.goneMS, accuracy: 1e-9)
            XCTAssertEqual(short.goneMS, c.landingMS + 150 + (c.goneMS - c.exitMS), accuracy: 1e-9)
            XCTAssertLessThan(short.goneMS, long.goneMS)
            XCTAssertEqual(long.goneMS, c.goneMS)
            // Monotone.
            var last = -1.0
            for ms in stride(from: 0.0, through: long.goneMS, by: 5) {
                XCTAssertGreaterThanOrEqual(short.clock(ms), last)
                last = short.clock(ms)
            }
        }
    }

    // MARK: Ducklings

    func testOneDucklingPerFileFromTheTrioUpToFive() {
        XCTAssertEqual(Courier.ducklings(files: 1), 3)
        XCTAssertEqual(Courier.ducklings(files: 3), 3)
        XCTAssertEqual(Courier.ducklings(files: 4), 4)
        XCTAssertEqual(Courier.ducklings(files: 5), 5)
        XCTAssertEqual(Courier.ducklings(files: 40), 5)
        XCTAssertEqual(CourierPlan(courier: .ducks, seed: 1, files: 4).actors, 4)
        // One courier per batch for the others.
        XCTAssertEqual(CourierPlan(courier: .cheek, seed: 1, files: 4).actors, 1)
        // The trio pops in at the mockup's p; five spread over the same span.
        XCTAssertEqual((0..<3).map { Courier.ducklingStart($0, of: 3) }, [0.2, 0.45, 0.7])
        XCTAssertEqual(Courier.ducklingStart(4, of: 5), 0.7, accuracy: 1e-12)
        // Two more ducklings leave 60 ms apart.
        XCTAssertEqual(CourierPlan(courier: .ducks, seed: 1, files: 5).goneMS, Courier.ducks.goneMS + 120)
    }

    // MARK: Peek message

    func testPeekStartCarriesTheSeedAndShort() throws {
        let m = try PeekMessage.parse(Data(#"{"type":"peek-start","id":"p1","name":"a.jpg","kind":"image","size":1,"seed":123456789,"short":true}"#.utf8))
        guard case .start(let info) = m else { return XCTFail() }
        XCTAssertEqual(info.seed, 123_456_789)
        XCTAssertTrue(info.short)
        // An older page: no seed, not short.
        let old = try PeekMessage.parse(Data(#"{"type":"peek-start","id":"p1","name":"a.jpg","kind":"image","size":1}"#.utf8))
        guard case .start(let o) = old else { return XCTFail() }
        XCTAssertNil(o.seed)
        XCTAssertFalse(o.short)
        // Junk is no seed.
        for bad in ["0", "-3", "1.5", "true", "\"7\"", "4294967296", "1e300"] {
            let b = try PeekMessage.parse(Data(#"{"type":"peek-start","id":"p1","name":"a","size":1,"seed":\#(bad),"short":1}"#.utf8))
            guard case .start(let i) = b else { return XCTFail() }
            XCTAssertNil(i.seed, bad)
            XCTAssertFalse(i.short)
        }
    }
}
