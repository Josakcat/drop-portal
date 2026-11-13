import JavaScriptCore
import XCTest
@testable import DropPortalCore

/// The courier foundation: both registries cover every `Courier`, the stubs
/// build and register, and every number of the flow comes from Couriers.swift.
final class CourierFoundationTests: XCTestCase {
    /// The droplet's folder (this file is in .droppykit/tests/Tests/DropPortalCoreTests).
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The page's courier script in JavaScriptCore (no DOM: only the registry and the maths run at load).
    private func page() throws -> JSContext {
        let js = try XCTUnwrap(JSContext())
        var failure: String?
        js.exceptionHandler = { _, e in failure = e?.toString() }
        js.evaluateScript("var window = this;")
        js.evaluateScript(WebCourierEffect.script)
        XCTAssertNil(failure)
        return js
    }

    // MARK: Registries

    func testJSRegistryCoversEveryCourier() throws {
        let js = try page()
        XCTAssertEqual(js.evaluateScript("DPCourier.names.join(',')").toString(), Courier.allCases.map(\.rawValue).joined(separator: ","))
        for c in Courier.allCases {
            XCTAssertTrue(js.evaluateScript("DPCourier.has('\(c.rawValue)')").toBool(), c.rawValue)
            for f in ["hold", "leap", "sticker", "draw"] {
                XCTAssertEqual(js.evaluateScript("typeof DPCourier['\(c.rawValue)'].\(f)").toString(), "function", "\(c.rawValue).\(f)")
            }
            // Its own file, registering itself by the effect's name.
            let file = try source("Sources/DropPortalCore/WebCourier\(c.stem).swift")
            XCTAssertTrue(file.contains(#"DP.register("\#(c.rawValue)""#), c.stem)
            XCTAssertNotNil(WebCourierEffect.characters[c])
        }
        XCTAssertFalse(js.evaluateScript("DPCourier.has('portal')").toBool())
    }

    func testMacRegistryCoversEveryCourier() throws {
        let crossing = try source("Sources/DropPortal/Couriers/CourierCrossing.swift")
        for c in Courier.allCases {
            let file = try source("Sources/DropPortal/Couriers/\(c.stem)Courier.swift")
            XCTAssertTrue(file.contains("final class \(c.stem)Courier: CourierCharacter"), c.stem)
            XCTAssertTrue(file.contains("let courier: Courier = .\(c.rawValue)"), c.stem)
            XCTAssertTrue(crossing.contains("case .\(c.rawValue): return \(c.stem)Courier()"), c.stem)
        }
    }

    func testThePageCarriesTheCouriersOnce() {
        let html = WebPage.html(effect: .cheek)
        XCTAssertEqual(html.components(separatedBy: "W.DPCourier = DP;").count, 2)
        for c in Courier.allCases {
            XCTAssertEqual(html.components(separatedBy: #"DP.register("\#(c.rawValue)""#).count, 2, c.rawValue)
            XCTAssertTrue(html.contains("html[data-effect=\(c.rawValue)] .portal"))
        }
        // peek-start carries the seed and the short version for the Mac's CourierPlan.
        XCTAssertTrue(WebPage.template.contains("start.seed = courier.seed; start.short = courier.short;"))
    }

    // MARK: Timings from Couriers.swift

    func testJSTimingsAreCouriersSwift() throws {
        let js = try page()
        func n(_ s: String) -> Double { js.evaluateScript(s).toDouble() }
        for c in Courier.allCases {
            let t = "DPCourier.T.\(c.rawValue)"
            XCTAssertEqual(n("\(t).L"), c.landingMS)
            XCTAssertEqual(n("\(t).exit"), c.exitMS)
            XCTAssertEqual(n("\(t).gone"), c.goneMS)
            XCTAssertEqual(n("\(t).clear"), c.phoneClearMS)
            XCTAssertEqual(n("\(t).gagOneIn"), Double(c.gagOneIn))
        }
        XCTAssertEqual(n("DPCourier.T._.shortWindow"), Courier.shortWindow)
        XCTAssertEqual(n("DPCourier.T._.skip"), Courier.skipMS)
        XCTAssertEqual(n("DPCourier.T._.stickerFade"), Courier.stickerFadeMS)
        XCTAssertEqual(n("DPCourier.T._.stickerBlink"), Courier.stickerBlinkMS)
        XCTAssertEqual(n("DPCourier.T._.stickerHold"), Courier.stickerHoldMS)
        XCTAssertEqual(n("DPCourier.T._.cancelFade"), Courier.cancelFadeMS)
    }

    func testSharedFlowFilesRepeatNoBeat() throws {
        let shared = try source("Sources/DropPortal/Couriers/CourierCrossing.swift") + WebCourierEffect.toolkit
        var beats = Set<Int>()
        for c in Courier.allCases { beats.formUnion([c.landingMS, c.exitMS, c.goneMS, c.phoneClearMS].map { Int($0) }) }
        beats.formUnion([Courier.stickerBlinkMS, Courier.stickerHoldMS].map { Int($0) })
        for beat in beats {
            let pattern = "(?<![0-9.])\(beat)(?![0-9])"
            XCTAssertNil(shared.range(of: pattern, options: .regularExpression), "\(beat) ms is written out in a shared flow file")
        }
    }

    func testJSPlanIsCourierPlan() throws {
        let js = try page()
        for c in Courier.allCases {
            for seed: UInt32 in [1, 2, 42, 7, 123_456_789, 3_000_000_000, .max] {
                let swift = CourierPlan(courier: c, seed: seed, files: 4)
                let p = "DPCourier.plan('\(c.rawValue)', \(seed), false, 4)"
                XCTAssertEqual(js.evaluateScript("\(p).jitter").toDouble(), swift.jitter, accuracy: 1e-12)
                XCTAssertEqual(js.evaluateScript("\(p).gag").toBool(), swift.gag, "\(c) \(seed)")
                XCTAssertEqual(js.evaluateScript("\(p).blinkSeed").toDouble(), Double(swift.blinkSeed))
                XCTAssertEqual(js.evaluateScript("\(p).actors").toInt32(), Int32(swift.actors))
                let times = js.evaluateScript("\(p).blinks.filter(function (t) { return t < 6000; }).join(',')").toString()
                let jsTimes = (times ?? "").split(separator: ",").compactMap { Double($0) }
                XCTAssertEqual(jsTimes.count, swift.blinkTimes().count)
                for (a, b) in zip(jsTimes, swift.blinkTimes()) { XCTAssertEqual(a, b, accuracy: 1e-6) }
                for ms in [0.0, 450, 1200, 3333] {
                    let lid = js.evaluateScript("DPCourier.kit.lid(\(ms) - 420)").toDouble()
                    XCTAssertEqual(lid, CourierPlan.lid(ms - 420), accuracy: 1e-9)
                }
            }
        }
    }

    func testPlaceholderPlaysTheWholeFlowOnBothSides() throws {
        // The JS stubs' poses need no DOM: each phase gives a pose until the edge is clear.
        let js = try page()
        js.evaluateScript("""
            var e = function (n) { return { T: DPCourier.T[n], all: DPCourier.T._, kit: DPCourier.kit, plan: DPCourier.plan(n, 7, false, 3),
              rect: { left: 120, top: 300, width: 160, height: 200, cx: 200, cy: 400, bottom: 500, right: 280 }, W: 393, H: 852, k: 0.85, ground: 530 }; };
            """)
        for c in Courier.allCases {
            let n = c.rawValue
            XCTAssertTrue(js.evaluateScript("!!DPCourier['\(n)'].hold(0.6, e('\(n)'))").toBool(), n)
            XCTAssertTrue(js.evaluateScript("!!DPCourier['\(n)'].leap(100, e('\(n)')).card").toBool(), n)
            XCTAssertTrue(js.evaluateScript("DPCourier['\(n)'].leap(\(c.phoneClearMS + 1), e('\(n)')) === null").toBool(), n)
            XCTAssertTrue(js.evaluateScript("!!DPCourier['\(n)'].sticker(400, e('\(n)'))").toBool(), n)
        }
    }
}
