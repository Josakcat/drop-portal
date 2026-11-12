//
//  PhoneLink.swift
//  DropPortalCore
//
//  Text from the phone that is one web link, and nothing else, opens in the
//  Mac's default browser. Only http and https: never file:, javascript:,
//  data: or an app's own scheme, and never a link with a user name in it
//  (`https://bank.com@evil.example` reads as one site and goes to another).
//

import Foundation

public enum PhoneLink {
    /// The longest link that is opened; longer text is only copied.
    public static let maxLength = 4096

    /// The web link `text` is, trimmed; nil when it is anything more or less.
    public static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLength,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }
}
