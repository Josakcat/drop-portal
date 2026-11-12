//
//  PortalLog.swift
//  DropPortal
//

import Foundation

/// A tiny append-only log at ~/Library/Logs/DropPortal.log, so an install in
/// Droppy shows which process did what. One line per event, written off the
/// main thread; the file starts over past 256 KB.
enum PortalLog {
    /// Droppy also runs a separate settings process with this argument.
    static let isSettingsHost = ProcessInfo.processInfo.arguments.contains("--droppy-settings-host")

    private static let queue = DispatchQueue(label: "portal.log", qos: .utility)
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DropPortal.log")
    private static let prefix = "pid=\(ProcessInfo.processInfo.processIdentifier) role=\(isSettingsHost ? "settings-host" : "main")"

    /// The harness's drop test reads the lines on standard error instead.
    nonisolated(unsafe) static var mirrorToStandardError = false

    static func write(_ message: String) {
        // The harness's tests write there only, never into the real log.
        if mirrorToStandardError { return FileHandle.standardError.write(Data("[log] \(message)\n".utf8)) }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let line = Data("\(stamp) \(prefix) \(message)\n".utf8)
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 * 1024 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }
}

/// A Darwin notification between the main Droppy process and its settings
/// process: "the shared preferences changed, read them again". Public API,
/// no payload; the value itself travels in `host.preferences`.
final class PortalSignal {
    let name: String
    private let action: () -> Void

    init(_ name: String, action: @escaping () -> Void) {
        self.name = name
        self.action = action
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let signal = Unmanaged<PortalSignal>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { signal.action() }
        }, name as CFString, nil, .deliverImmediately)
    }

    func cancel() {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name as CFString), nil)
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
