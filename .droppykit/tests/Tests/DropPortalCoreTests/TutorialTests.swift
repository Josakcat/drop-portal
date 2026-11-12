@testable import DropPortalCore
import XCTest

/// The phone page's first-visit tour and the "?" button that shows it again.
final class TutorialTests: XCTestCase {
    func testPageHasTourAndHelpButton() {
        let html = WebPage.html(effect: .portal)
        XCTAssertTrue(html.contains(#"<button class="help" id="help" aria-label="How it works">?</button>"#))
        XCTAssertTrue(html.contains(#"id="tour""#))
        XCTAssertTrue(html.contains(#"role="dialog""#))
        for line in ["Pick photos or files", "Flick them off the left edge", "They land on your Mac",
                     "To send from Mac, drag to the right edge of your Mac screen.",
                     ">Skip<", ">Next<", "\"Done\""] {
            XCTAssertTrue(html.contains(line), line)
        }
    }

    func testTourIsRememberedSafely() {
        let html = WebPage.html(effect: .portal)
        // Private mode can throw on localStorage: both the read and the write are wrapped.
        XCTAssertTrue(html.contains(#"var TOUR_KEY = "dropportal.tour.v2";"#))
        XCTAssertTrue(html.contains(#"try { localStorage.setItem(TOUR_KEY, "1"); } catch (_) {}"#))
        XCTAssertTrue(html.contains(#"try { tourSeen = localStorage.getItem(TOUR_KEY) === "1"; } catch (_) {}"#))
        // A phone that dismissed the old hint, or saw the first tour, still gets this one once.
        XCTAssertFalse(html.contains(#"getItem("dropportal.tip")"#))
        XCTAssertFalse(html.contains(#"getItem("dropportal.tour")"#))
        XCTAssertFalse(html.contains(#"id="tip""#), "the old one-line hint is replaced by the tour")
    }
}
