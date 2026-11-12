//
//  QuickActionShortcut.swift
//  DropPortalCore
//
//  The macOS Shortcut behind Finder's right-click › Quick Actions › Send to
//  iPhone. A droplet cannot register a Service, so Drop Portal builds this
//  shortcut (pairing token baked in), signs it with `shortcuts sign` and opens
//  it for the user to add. Each selected file or folder goes to this Mac's own
//  `POST /send-to-iphone` on 127.0.0.1 by its path (`X-DropPortal-Path`; a
//  folder cannot be a request body), which the server takes only from
//  loopback and only with the token; the droplet then offers it to the phone,
//  a folder as a .zip. The server still takes the first version's uploads.
//

import Foundation

public enum QuickActionShortcut {
    /// What Shortcuts names it, and so the Quick Action's title in Finder.
    public static let fileName = "Send to phone.shortcut"

    public static func unsigned(port: UInt16, token: String) throws -> Data {
        let pathID = UUID().uuidString, loop = UUID().uuidString
        let item = ShareShortcut.repeatItem
        let actions: [[String: Any]] = [
            ShareShortcut.action("repeat.each", ["GroupingIdentifier": loop, "WFControlFlowMode": 0,
                                                 "WFInput": ShareShortcut.attachment(["Type": "ExtensionInput"])]),
            ShareShortcut.action("urlencode", ["UUID": pathID,
                                               "WFInput": ShareShortcut.tokens("\u{FFFC}", [0: ShareShortcut.property(item, "File Path")])]),
            ShareShortcut.action("downloadurl", [
                "WFURL": "http://127.0.0.1:\(port)\(DropPortalServer.sendPath)",
                "WFHTTPMethod": "POST",
                "ShowHeaders": true,
                "WFHTTPHeaders": ["Value": ["WFDictionaryFieldValueItems": [
                    ["WFItemType": 0, "WFKey": ShareShortcut.tokens("X-DropPortal-Token", [:]), "WFValue": ShareShortcut.tokens(token, [:])],
                    ["WFItemType": 0, "WFKey": ShareShortcut.tokens("X-DropPortal-Path", [:]),
                     "WFValue": ShareShortcut.tokens("\u{FFFC}", [0: ShareShortcut.output(pathID, "URL Encoded Text")])],
                ]], "WFSerializationType": "WFDictionaryFieldValue"],
            ]),
            ShareShortcut.action("repeat.each", ["GroupingIdentifier": loop, "WFControlFlowMode": 2]),
        ]
        let workflow: [String: Any] = [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2302.0.4",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": ["QuickActions"],
            "WFQuickActionSurfaces": ["Finder"],
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowInputContentItemClasses": [
                "WFGenericFileContentItem", "WFFolderContentItem", "WFImageContentItem", "WFAVAssetContentItem", "WFPDFContentItem",
            ],
            "WFWorkflowOutputContentItemClasses": [Any](),
        ]
        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }
}
