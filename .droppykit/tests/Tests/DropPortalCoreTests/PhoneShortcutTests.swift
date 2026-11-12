import XCTest
@testable import DropPortalCore

final class PhoneShortcutTests: XCTestCase {
    private func plist(_ kind: PhoneShortcut) throws -> (root: [String: Any], actions: [[String: Any]], raw: Data) {
        let data = try kind.unsigned(host: "mac.local", port: 8787, token: "good-token")
        var format = PropertyListSerialization.PropertyListFormat.xml
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any])
        XCTAssertEqual(format, .binary)
        let actions = try XCTUnwrap(root["WFWorkflowActions"] as? [[String: Any]])
        return (root, actions, data)
    }

    private func ids(_ actions: [[String: Any]]) -> [String] {
        actions.compactMap { ($0["WFWorkflowActionIdentifier"] as? String)?.replacingOccurrences(of: "is.workflow.actions.", with: "") }
    }

    private func params(_ actions: [[String: Any]], _ id: String) -> [[String: Any]] {
        actions.filter { $0["WFWorkflowActionIdentifier"] as? String == "is.workflow.actions.\(id)" }
            .compactMap { $0["WFWorkflowActionParameters"] as? [String: Any] }
    }

    private func occurrences(_ data: Data, _ needle: String) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: needle).count - 1
    }

    /// Every block (Repeat, If, Menu) opens once and closes once, in order.
    private func assertBalanced(_ actions: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        var open: [String] = []
        for action in actions {
            guard let p = action["WFWorkflowActionParameters"] as? [String: Any],
                  let mode = p["WFControlFlowMode"] as? Int, let group = p["GroupingIdentifier"] as? String else { continue }
            switch mode {
            case 0: open.append(group)
            case 1: XCTAssertEqual(open.last, group, file: file, line: line)
            default: XCTAssertEqual(open.popLast(), group, file: file, line: line)
            }
        }
        XCTAssertTrue(open.isEmpty, file: file, line: line)
    }

    func testPathsNamesAndLookup() {
        XCTAssertEqual(PhoneShortcut.allCases.map(\.path),
                       ["/shortcut", "/shortcut/latest-photo", "/shortcut/clipboard", "/shortcut/pick", "/shortcut/open"])
        XCTAssertEqual(PhoneShortcut.share.fileName, "Drop Portal.shortcut")
        XCTAssertEqual(PhoneShortcut.latestPhoto.fileName, "Send latest photo.shortcut")
        for kind in PhoneShortcut.allCases { XCTAssertEqual(PhoneShortcut(path: kind.path), kind) }
        XCTAssertNil(PhoneShortcut(path: "/shortcut/"))
        XCTAssertNil(PhoneShortcut(path: "/shortcut/nope"))
        XCTAssertEqual(LocalAddress.shortcutURL(host: "mac.local", port: 8787, token: "t", kind: .clipboard),
                       "http://mac.local:8787/shortcut/clipboard?t=t")
        XCTAssertEqual(Set(PhoneShortcut.allCases.map(\.name)).count, PhoneShortcut.allCases.count)
    }

    func testShareSheetShortcutIsUnchanged() throws {
        let (root, actions, data) = try plist(.share)
        XCTAssertEqual(root["WFWorkflowTypes"] as? [String], ["ActionExtension"])
        XCTAssertEqual(params(actions, "downloadurl").compactMap { $0["WFURL"] as? String },
                       ["http://mac.local:8787/text", "http://mac.local:8787/upload"])
        assertBalanced(actions)
        XCTAssertEqual(occurrences(data, "good-token"), 2)
    }

    func testLatestPhotoSendsOneNewestPhotoOrScreenshot() throws {
        let (root, actions, data) = try plist(.latestPhoto)
        XCTAssertEqual(root["WFWorkflowHasShortcutInputVariables"] as? Bool, false)
        XCTAssertEqual(ids(actions).first, "getlastphoto")
        let photo = try XCTUnwrap(params(actions, "getlastphoto").first)
        XCTAssertEqual(photo["WFGetLatestPhotoCount"] as? Int, 1)
        XCTAssertEqual(photo["WFGetLatestPhotosActionIncludeScreenshots"] as? Bool, true)
        // The loop runs over the photo action's output.
        let loop = try XCTUnwrap(params(actions, "repeat.each").first)
        let input = try XCTUnwrap((loop["WFInput"] as? [String: Any])?["Value"] as? [String: Any])
        XCTAssertEqual(input["OutputUUID"] as? String, photo["UUID"] as? String)
        XCTAssertEqual(params(actions, "downloadurl").compactMap { $0["WFURL"] as? String },
                       ["http://mac.local:8787/text", "http://mac.local:8787/upload"])
        XCTAssertEqual(ids(actions).last, "notification")
        assertBalanced(actions)
        XCTAssertEqual(occurrences(data, "good-token"), 2)
    }

    func testClipboardSendsTextToTextAndFilesToUpload() throws {
        let (_, actions, data) = try plist(.clipboard)
        XCTAssertEqual(ids(actions).first, "getclipboard")
        let clip = try XCTUnwrap(params(actions, "getclipboard").first?["UUID"] as? String)
        let loop = try XCTUnwrap(params(actions, "repeat.each").first)
        XCTAssertEqual(((loop["WFInput"] as? [String: Any])?["Value"] as? [String: Any])?["OutputUUID"] as? String, clip)
        // Text and links (the Mac opens links per its setting) go to /text, the rest to /upload.
        let posts = params(actions, "downloadurl")
        XCTAssertEqual(posts.compactMap { $0["WFURL"] as? String },
                       ["http://mac.local:8787/text", "http://mac.local:8787/upload"])
        XCTAssertTrue(posts.allSatisfy { $0["WFHTTPMethod"] as? String == "POST" })
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("|Text|URL|Rich Text|"))
        assertBalanced(actions)
        XCTAssertEqual(occurrences(data, "good-token"), 2)
    }

    func testPickOffersPhotosAndFilesAndSendsEach() throws {
        let (_, actions, data) = try plist(.pick)
        let menu = params(actions, "choosefrommenu")
        XCTAssertEqual(menu.compactMap { $0["WFControlFlowMode"] as? Int }, [0, 1, 1, 2])
        XCTAssertEqual(menu.first?["WFMenuItems"] as? [String], ["Photos", "Files"])
        XCTAssertEqual(menu.compactMap { $0["WFMenuItemTitle"] as? String }, ["Photos", "Files"])
        XCTAssertEqual(params(actions, "selectphoto").first?["WFSelectMultiplePhotos"] as? Bool, true)
        let files = try XCTUnwrap(params(actions, "documentpicker.open").first)
        XCTAssertEqual(files["WFShowFilePicker"] as? Bool, true)
        XCTAssertEqual(files["SelectMultiple"] as? Bool, true)
        // One send loop per branch.
        XCTAssertEqual(params(actions, "downloadurl").count, 4)
        XCTAssertEqual(params(actions, "repeat.each").count, 4)
        assertBalanced(actions)
        XCTAssertEqual(occurrences(data, "good-token"), 4)
    }

    func testOpenOpensThePageOnThisMacWithTheToken() throws {
        let (_, actions, data) = try plist(.open)
        XCTAssertEqual(ids(actions), ["url", "openurl"])
        let url = try XCTUnwrap(params(actions, "url").first)
        XCTAssertEqual(url["WFURLActionURL"] as? String, "http://mac.local:8787/?t=good-token")
        let open = try XCTUnwrap(params(actions, "openurl").first)
        XCTAssertEqual(((open["WFInput"] as? [String: Any])?["Value"] as? [String: Any])?["OutputUUID"] as? String,
                       url["UUID"] as? String)
        XCTAssertEqual(occurrences(data, "good-token"), 1)
        XCTAssertTrue(params(actions, "downloadurl").isEmpty)
    }

    func testEveryShortcutReachesOnlyThisMac() throws {
        for kind in PhoneShortcut.allCases {
            let (_, actions, _) = try plist(kind)
            for post in params(actions, "downloadurl") {
                XCTAssertTrue((post["WFURL"] as? String)?.hasPrefix("http://mac.local:8787/") == true, kind.rawValue)
            }
        }
    }
}
