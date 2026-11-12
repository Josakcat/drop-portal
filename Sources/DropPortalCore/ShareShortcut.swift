//
//  ShareShortcut.swift
//  DropPortalCore
//
//  The iOS Shortcut that puts Drop Portal in the iPhone's share sheet. It is
//  built per Mac (address and pairing token baked in), signed on the Mac with
//  `shortcuts sign` and served only to a request that carries the token.
//

import Foundation

public enum ShareShortcut {
    /// The unsigned shortcut, a binary plist. Each shared item goes to the
    /// Mac: text and links to `/text` (the clipboard), anything else to
    /// `/upload` with its name.
    public static func unsigned(host: String, port: UInt16, token: String) throws -> Data {
        let actions = sendEach(attachment(["Type": "ExtensionInput"]), base: "http://\(host):\(port)", token: token)
        let workflow: [String: Any] = [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2302.0.4",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowTypes": ["ActionExtension"],
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowInputContentItemClasses": [
                "WFImageContentItem", "WFAVAssetContentItem", "WFPhotoMediaContentItem",
                "WFGenericFileContentItem", "WFPDFContentItem", "WFStringContentItem",
                "WFRichTextContentItem", "WFURLContentItem",
            ],
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFQuickActionSurfaces": [Any](),
        ]
        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0)
    }

    /// One Repeat over `input`: text and links to `/text` (the clipboard, or
    /// the browser for a link when the Mac opens links), anything else to
    /// `/upload` with its name. Shared by every phone shortcut that sends.
    static func sendEach(_ input: [String: Any], base: String, token: String) -> [[String: Any]] {
        let typeID = UUID().uuidString, listID = UUID().uuidString
        let textID = UUID().uuidString, nameID = UUID().uuidString, encodedID = UUID().uuidString
        let loop = UUID().uuidString, branch = UUID().uuidString
        return [
            action("repeat.each", ["GroupingIdentifier": loop, "WFControlFlowMode": 0, "WFInput": input]),
            action("getitemtype", ["UUID": typeID, "WFInput": attachment(repeatItem)]),
            // Get Type names the item ("Text", "URL", "Image"...). One If can only
            // test one thing, so ask whether the list of text kinds contains it.
            // shortcut: Get Type may answer in the phone's language; then text
            // arrives as a .txt file instead of the clipboard, which still lands.
            action("gettext", ["UUID": listID, "WFTextActionText": tokens("|Text|URL|Rich Text|", [:])]),
            action("conditional", ["GroupingIdentifier": branch, "WFControlFlowMode": 0,
                                   "WFInput": ["Type": "Variable",
                                               "Variable": attachment(output(listID, "Text"))],
                                   "WFCondition": 99,
                                   "WFConditionalActionString": tokens("|\u{FFFC}|", [1: output(typeID, "Type")])]),
            action("gettext", ["UUID": textID, "WFTextActionText": tokens("\u{FFFC}", [0: repeatItem])]),
            post("\(base)/text", body: output(textID, "Text"), headers: [("X-DropPortal-Token", tokens(token, [:]))]),
            action("conditional", ["GroupingIdentifier": branch, "WFControlFlowMode": 1]),
            action("gettext", ["UUID": nameID, "WFTextActionText": tokens("\u{FFFC}.\u{FFFC}", [
                0: property(repeatItem, "Name"), 2: property(repeatItem, "File Extension"),
            ])]),
            action("urlencode", ["UUID": encodedID, "WFInput": tokens("\u{FFFC}", [0: output(nameID, "Text")])]),
            post("\(base)/upload", body: repeatItem, headers: [
                ("X-DropPortal-Token", tokens(token, [:])),
                ("X-DropPortal-Name", tokens("\u{FFFC}", [0: output(encodedID, "URL Encoded Text")])),
            ]),
            action("conditional", ["GroupingIdentifier": branch, "WFControlFlowMode": 2]),
            action("repeat.each", ["GroupingIdentifier": loop, "WFControlFlowMode": 2]),
        ]
    }

    // MARK: Plist pieces

    static let repeatItem: [String: Any] = ["Type": "Variable", "VariableName": "Repeat Item"]

    static func action(_ id: String, _ parameters: [String: Any]) -> [String: Any] {
        ["WFWorkflowActionIdentifier": "is.workflow.actions.\(id)", "WFWorkflowActionParameters": parameters]
    }

    static func output(_ uuid: String, _ name: String) -> [String: Any] {
        ["Type": "ActionOutput", "OutputUUID": uuid, "OutputName": name]
    }

    static func property(_ variable: [String: Any], _ name: String) -> [String: Any] {
        var v = variable
        v["Aggrandizements"] = [["Type": "WFPropertyVariableAggrandizement", "PropertyName": name]]
        return v
    }

    static func attachment(_ value: [String: Any]) -> [String: Any] {
        ["Value": value, "WFSerializationType": "WFTextTokenAttachment"]
    }

    /// A text field; each U+FFFC at the given UTF-16 offset is a variable.
    static func tokens(_ string: String, _ variables: [Int: [String: Any]]) -> [String: Any] {
        var ranges: [String: Any] = [:]
        for (offset, value) in variables { ranges["{\(offset), 1}"] = value }
        return ["Value": ["string": string, "attachmentsByRange": ranges], "WFSerializationType": "WFTextTokenString"]
    }

    static func post(_ url: String, body: [String: Any], headers: [(String, [String: Any])]) -> [String: Any] {
        let items: [[String: Any]] = headers.map { key, value in
            ["WFItemType": 0, "WFKey": tokens(key, [:]), "WFValue": value]
        }
        return action("downloadurl", [
            "WFURL": url,
            "WFHTTPMethod": "POST",
            "ShowHeaders": true,
            "WFHTTPHeaders": ["Value": ["WFDictionaryFieldValueItems": items],
                              "WFSerializationType": "WFDictionaryFieldValue"],
            "WFHTTPBodyType": "File",
            "WFRequestVariable": attachment(body),
        ])
    }
}
