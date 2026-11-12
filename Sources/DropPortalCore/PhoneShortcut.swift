//
//  PhoneShortcut.swift
//  DropPortalCore
//
//  The iPhone Shortcuts Drop Portal offers: the share sheet's and four that
//  run on their own (Action button, Back Tap, Siri, Home Screen, Control
//  Center). Each is built per Mac (its .local name and the pairing token baked
//  in), signed on the Mac with `shortcuts sign` and served only to a request
//  that carries the token, at `path`.
//

import Foundation

public enum PhoneShortcut: String, CaseIterable, Sendable {
    case share
    case latestPhoto = "latest-photo"
    case clipboard
    case pick
    case open

    /// The shortcut's name on the phone; Shortcuts takes it from the file name.
    public var name: String {
        switch self {
        case .share: "Drop Portal"
        case .latestPhoto: "Send latest photo"
        case .clipboard: "Send clipboard"
        case .pick: "Pick and send"
        case .open: "Open Drop Portal"
        }
    }

    /// Its line in the lists on the phone page and in Settings.
    public var title: String { self == .share ? "Share sheet" : name }

    /// One line on what it does and where to put it.
    public var hint: String {
        switch self {
        case .share: "Pick Drop Portal when you share from Photos, Files or Safari."
        case .latestPhoto: "Sends your newest photo or screenshot. Tip: set it on the Action button or Back Tap in Settings › Accessibility › Touch."
        case .clipboard: "Text lands on the Mac's clipboard, a link opens, a picture arrives as a file. Tip: Back Tap or the Action button."
        case .pick: "Choose Photos or Files, then send several at once."
        case .open: "Opens this page. Add it to the Home Screen, Lock Screen or Control Center."
        }
    }

    /// An SF Symbol for the Settings row.
    public var symbol: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .latestPhoto: "photo"
        case .clipboard: "doc.on.clipboard"
        case .pick: "photo.on.rectangle"
        case .open: "safari"
        }
    }

    public var fileName: String { name + ".shortcut" }

    /// Where the signed file is served (with `?t=`).
    public var path: String { self == .share ? "/shortcut" : "/shortcut/\(rawValue)" }

    /// The shortcut a request path asks for, `nil` for any other path.
    public init?(path: String) {
        guard let kind = Self.allCases.first(where: { $0.path == path }) else { return nil }
        self = kind
    }

    /// The unsigned shortcut, a binary plist.
    public func unsigned(host: String, port: UInt16, token: String) throws -> Data {
        if self == .share { return try ShareShortcut.unsigned(host: host, port: port, token: token) }
        let base = "http://\(host):\(port)"
        typealias S = ShareShortcut
        var actions: [[String: Any]] = []
        switch self {
        case .share:
            break
        case .latestPhoto:
            let photo = UUID().uuidString
            actions.append(S.action("getlastphoto", ["UUID": photo, "WFGetLatestPhotoCount": 1,
                                                     "WFGetLatestPhotosActionIncludeScreenshots": true]))
            actions += S.sendEach(S.attachment(S.output(photo, "Latest Photos")), base: base, token: token)
            actions.append(Self.notify("Photo sent to your Mac."))
        case .clipboard:
            // Text and links go to `/text`; the Mac opens a link when it is set to.
            let clip = UUID().uuidString
            actions.append(S.action("getclipboard", ["UUID": clip]))
            actions += S.sendEach(S.attachment(S.output(clip, "Clipboard")), base: base, token: token)
            actions.append(Self.notify("Clipboard sent to your Mac."))
        case .pick:
            let menu = UUID().uuidString, photos = UUID().uuidString, files = UUID().uuidString
            actions.append(S.action("choosefrommenu", ["GroupingIdentifier": menu, "WFControlFlowMode": 0,
                                                       "WFMenuPrompt": "Send to your Mac",
                                                       "WFMenuItems": ["Photos", "Files"]]))
            actions.append(S.action("choosefrommenu", ["GroupingIdentifier": menu, "WFControlFlowMode": 1,
                                                       "WFMenuItemTitle": "Photos"]))
            actions.append(S.action("selectphoto", ["UUID": photos, "WFSelectMultiplePhotos": true]))
            actions += S.sendEach(S.attachment(S.output(photos, "Photos")), base: base, token: token)
            actions.append(S.action("choosefrommenu", ["GroupingIdentifier": menu, "WFControlFlowMode": 1,
                                                       "WFMenuItemTitle": "Files"]))
            actions.append(S.action("documentpicker.open", ["UUID": files, "WFShowFilePicker": true,
                                                            "SelectMultiple": true]))
            actions += S.sendEach(S.attachment(S.output(files, "File")), base: base, token: token)
            actions.append(S.action("choosefrommenu", ["GroupingIdentifier": menu, "WFControlFlowMode": 2]))
            actions.append(Self.notify("Sent to your Mac."))
        case .open:
            let url = UUID().uuidString
            actions.append(S.action("url", ["UUID": url, "WFURLActionURL": LocalAddress.pageURL(host: host, port: port, token: token)]))
            actions.append(S.action("openurl", ["WFInput": S.attachment(S.output(url, "URL"))]))
        }

        let workflow: [String: Any] = [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2302.0.4",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFQuickActionSurfaces": [Any](),
        ]
        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }

    /// A quiet banner on the phone once everything went; a failed send stops the shortcut first.
    private static func notify(_ body: String) -> [String: Any] {
        ShareShortcut.action("notification", ["WFNotificationActionTitle": "Drop Portal",
                                               "WFNotificationActionBody": ShareShortcut.tokens(body, [:]),
                                               "WFNotificationActionSound": false])
    }
}
