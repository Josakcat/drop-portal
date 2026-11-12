@testable import DropPortalCore
import XCTest

/// Text from the phone that opens in the browser: one http(s) link and nothing else.
final class PhoneLinkTests: XCTestCase {
    func testAcceptsOneWebLink() {
        for text in ["https://example.com", "http://example.com/a?b=c#d", "  https://example.com/path\n",
                     "HTTPS://Example.com/x", "https://192.168.1.4:8080/", "https://ตัวอย่าง.ไทย/หน้า"] {
            XCTAssertNotNil(PhoneLink.webURL(in: text), text)
        }
        XCTAssertEqual(PhoneLink.webURL(in: " https://example.com/a \n")?.absoluteString, "https://example.com/a")
    }

    func testRejectsEverythingElse() {
        for text in ["", "   ", "example.com", "www.example.com", "file:///etc/passwd", "javascript:alert(1)",
                     "JavaScript://example.com/%0Aalert(1)", "data:text/html,hi", "ftp://example.com", "mailto:a@b.c",
                     "slack://open", "x-apple.systempreferences:", "https://", "https:///path", "http:example.com",
                     "https://example.com and more", "see https://example.com", "https://a.com\nhttps://b.com",
                     "https://user:pass@example.com", "https://bank.com@evil.example/",
                     "https://example.com/\u{0007}", "https://" + String(repeating: "a", count: 5000) + ".com"] {
            XCTAssertNil(PhoneLink.webURL(in: text), text)
        }
    }
}
