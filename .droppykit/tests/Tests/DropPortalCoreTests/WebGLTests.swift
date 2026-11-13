@testable import DropPortalCore
import XCTest

/// The phone page's WebGL edge light: in the page once, with its fallbacks and its budget.
final class WebGLTests: XCTestCase {
    func testBlockIsInThePageOnceAndHooked() {
        let html = WebPage.html(effect: .wormhole)
        XCTAssertEqual(html.components(separatedBy: "window.DropPortalGL = {").count, 2)
        XCTAssertFalse(html.contains("<!--webgl-->"))
        for hook in ["DropPortalGL.hold(p, cardY)", "DropPortalGL.off()", "DropPortalGL.send()", "DropPortalGL.flash()"] {
            XCTAssertTrue(html.contains(hook), hook)
        }
        // Before the page's own script, which calls it.
        XCTAssertLessThan(html.range(of: "window.DropPortalGL = {")!.lowerBound, html.range(of: "var token = new URLSearchParams")!.lowerBound)
    }

    func testFallsBackAndStaysCheap() {
        let block = WebGLEffect.block
        // The CSS edge is hidden only while the GL canvas owns it.
        XCTAssertTrue(block.contains("html.gl .portal{visibility:hidden}"))
        XCTAssertTrue(block.contains("prefers-reduced-motion: reduce"))
        XCTAssertTrue(block.contains("webglcontextlost"))
        XCTAssertTrue(block.contains("WEBGL_lose_context"))
        XCTAssertTrue(block.contains("visibilitychange"))
        XCTAssertTrue(block.contains("Math.min(window.devicePixelRatio || 1, 1.5)"))
        XCTAssertTrue(block.contains("MAXPX = 520000"))
        // Nothing from the network, nothing new for the CSP.
        XCTAssertFalse(block.contains("http"))
        XCTAssertFalse(block.contains("src="))
        // Size budget: the block stays under 12 KB (11.2 KB on 2026-11-13, 4.9 KB gzipped; the page is 81 KB, 24 KB gzipped).
        XCTAssertLessThan(block.utf8.count, 12_000)
    }
}
