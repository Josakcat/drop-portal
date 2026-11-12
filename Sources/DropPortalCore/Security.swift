//
//  Security.swift
//  DropPortalCore
//
//  The trust boundary: the pairing token and what a sender may call a file.
//

import Foundation

public enum PairingToken {
    /// A new token: 24 random bytes as base64url, 32 characters.
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether `given` is the token, compared in constant time. An empty
    /// expected token never matches.
    public static func matches(_ given: String?, expected: String) -> Bool {
        guard let given, !expected.isEmpty else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<b.count { diff |= b[i] ^ (i < a.count ? a[i] : 0) }
        return diff == 0
    }
}

public enum FileNames {
    /// The longest name `sanitize` returns, in UTF-8 bytes. APFS allows 255;
    /// the rest leaves room for `unique`'s " 2", " 3"...
    public static let maxBytes = 240

    /// A name safe to create inside one folder: no directories, no hidden
    /// file, no control characters, at most `maxBytes` UTF-8 bytes (a Thai or
    /// emoji name is cut by bytes, never mid-character), never empty.
    public static func sanitize(_ raw: String) -> String {
        // Both separators, so "..\\..\\x" and "../../x" both end at "x".
        let last = raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? ""
        var name = String(last.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != ":"
        }.map(Character.init))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return "file" }
        if name.utf8.count > maxBytes {
            let ext = (name as NSString).pathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
            let base = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
            var kept = "", bytes = 0
            for character in base {
                let size = character.utf8.count
                if bytes + size + suffix.utf8.count > maxBytes { break }
                kept.append(character)
                bytes += size
            }
            kept = kept.trimmingCharacters(in: .whitespaces)
            name = (kept.isEmpty ? "file" : kept) + suffix
        }
        return name
    }

    /// `name` inside `folder`, or "name 2.ext", "name 3.ext"... when taken.
    public static func unique(_ name: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        let first = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

/// What happens to a file once it has landed.
public enum ReceivedFile {
    /// Types that run something when opened. A click on their landing card
    /// shows them in Finder instead of opening them.
    public static let revealOnlyExtensions: Set<String> = [
        "app", "command", "terminal", "sh", "tool", "pkg", "dmg", "workflow", "scpt", "jar",
    ]

    /// Whether a click should reveal the file rather than open it: a type
    /// from `revealOnlyExtensions` or a file with an executable bit.
    public static func revealsInsteadOfOpening(_ url: URL, fileManager: FileManager = .default) -> Bool {
        if revealOnlyExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        else { return true }
        return mode & 0o111 != 0
    }

    public static let quarantineAttribute = "com.apple.quarantine"

    /// Marks a received file the way a browser marks a download, so
    /// Gatekeeper checks it before anything in it runs.
    @discardableResult
    public static func quarantine(_ url: URL, agent: String = "Drop Portal", now: Date = Date()) -> Bool {
        let value = String(format: "0081;%08x;%@;", UInt32(now.timeIntervalSince1970), agent)
        return value.withCString { bytes in
            setxattr(url.path, quarantineAttribute, bytes, strlen(bytes), 0, 0) == 0
        }
    }

    /// The quarantine value on a file, or nil.
    public static func quarantineValue(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = getxattr(url.path, quarantineAttribute, &buffer, buffer.count - 1, 0, 0)
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Partial files a crash or a force quit left behind (`.dropportal-*.part`,
    /// from the server) older than `age`. Returns how many went.
    @discardableResult
    public static func removeOrphanPartials(in folder: URL, olderThan age: TimeInterval = 3600,
                                            now: Date = Date(), fileManager: FileManager = .default) -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(".dropportal-") && name.hasSuffix(".part") {
            let url = folder.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age
            else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
