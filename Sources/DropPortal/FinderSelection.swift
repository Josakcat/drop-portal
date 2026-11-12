//
//  FinderSelection.swift
//  DropPortal
//
//  The files selected in Finder, for the Send to iPhone shortcut. Asked with
//  an Apple Event (the `apple-events` capability; macOS asks the user once
//  whether Droppy may control Finder). It runs out of process in
//  /usr/bin/osascript, like FileTray, so a busy Finder or the consent prompt
//  never holds Droppy's main thread: a termination handler, output read while
//  it runs, a 10 s deadline and SIGTERM to its process group, `cancelAll()` in
//  deactivate().
//

import Foundation

enum FinderSelection {
    enum Result: Sendable {
        case files([URL])
        /// The user said no to Droppy controlling Finder (error -1743).
        case denied
        case failed
    }

    private static let timeout: TimeInterval = 10
    private static let queue = DispatchQueue(label: "portal.finder", qos: .userInitiated)
    nonisolated(unsafe) private static var running: [pid_t: Process] = [:]

    private static let script = """
    tell application "Finder"
      set picked to selection as alias list
    end tell
    set out to ""
    repeat with f in picked
      set out to out & POSIX path of f & linefeed
    end repeat
    return out
    """

    /// `done` runs on the main queue.
    static func read(done: @escaping @Sendable (Result) -> Void) {
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            var output = Data(), errors = Data()
            let reader = DispatchGroup()
            for (pipe, isError) in [(out, false), (err, true)] {
                reader.enter()
                DispatchQueue(label: "portal.finder.read").async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    queue.async {
                        if isError { errors = data } else { output = data }
                        reader.leave()
                    }
                }
            }
            var deadline: DispatchWorkItem?
            process.terminationHandler = { finished in
                queue.async {
                    deadline?.cancel()
                    running[finished.processIdentifier] = nil
                    reader.notify(queue: queue) {
                        let result = parse(status: finished.terminationStatus, output: output, errors: errors)
                        DispatchQueue.main.async { done(result) }
                    }
                }
            }
            do { try process.run() } catch {
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                PortalLog.write("finder selection: helper failed to start: \(error.localizedDescription)")
                return DispatchQueue.main.async { done(.failed) }
            }
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            let pid = process.processIdentifier
            running[pid] = process
            let item = DispatchWorkItem {
                guard running[pid] != nil else { return }
                PortalLog.write("finder selection: timed out")
                if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
            }
            deadline = item
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    static func parse(status: Int32, output: Data, errors: Data) -> Result {
        guard status == 0 else {
            let message = String(decoding: errors, as: UTF8.self)
            PortalLog.write("finder selection: status \(status) \(message.prefix(160))")
            return message.contains("-1743") || message.contains("-10004") ? .denied : .failed
        }
        let paths = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .files(paths.map { URL(fileURLWithPath: $0) })
    }

    static func cancelAll() {
        queue.async {
            for pid in running.keys where kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        }
    }
}
