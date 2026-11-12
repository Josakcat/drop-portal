//
//  FileTray.swift
//  DropPortal
//

import Foundation

/// Hands a received file to Droppy's File Tray through the macOS Service
/// "Add to Droppy Shelf".
///
/// DroppyKit has no host call that adds a file to the shelf, so this goes
/// through Droppy's own Service. The droplet runs inside Droppy's process, and
/// a Service call is a synchronous round trip to the app that provides it, so
/// calling it in-process can wait on the very main thread that has to answer.
/// It runs out of process instead: /usr/bin/osascript (JavaScript for
/// Automation) puts the file URL on a private named pasteboard and calls
/// NSPerformService there.
///
/// Bounded the way Good citizen asks: one helper per received file, started
/// only when the "Add received files to File Tray" setting is on; a
/// termination handler instead of a wait; its output read while it runs; a
/// 10 s deadline after which its whole process group gets SIGTERM, then
/// SIGKILL 2 s later; and `cancelAll()` from `deactivate()` does the same to
/// every helper still running. Nothing here touches the main thread.
enum FileTray {
    static let serviceName = "Add to Droppy Shelf"
    private static let timeout: TimeInterval = 10
    private static let killGrace: TimeInterval = 2
    private static let queue = DispatchQueue(label: "portal.filetray", qos: .utility)

    /// Helpers still running, by pid. Touched only on `queue`.
    nonisolated(unsafe) private static var running: [pid_t: Process] = [:]

    /// argv: service name, file path.
    private static let script = """
    ObjC.import('AppKit');
    function run(argv) {
      var pb = $.NSPasteboard.pasteboardWithName('app.getdroppy.droplet.drop-portal.tray.' + $.NSUUID.UUID.UUIDString);
      pb.clearContents;
      var url = $.NSURL.fileURLWithPath(argv[1]);
      if (!pb.writeObjects($([url]))) { pb.releaseGlobally; return 'pasteboard'; }
      var ok = $.NSPerformService($(argv[0]), pb);
      pb.releaseGlobally;
      return ok ? 'ok' : 'service';
    }
    """

    static func add(_ file: URL) {
        let path = file.path
        queue.async {
            let started = Date()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script, "--", serviceName, path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            process.standardInput = FileHandle.nullDevice
            process.qualityOfService = .utility

            // Output is read while the helper runs, so a full pipe never stalls it.
            var output = Data()
            let reader = DispatchGroup()
            reader.enter()
            DispatchQueue(label: "portal.filetray.read").async {
                output = out.fileHandleForReading.readDataToEndOfFile()
                reader.leave()
            }

            var deadline: DispatchWorkItem?
            process.terminationHandler = { finished in
                queue.async {
                    deadline?.cancel()
                    running[finished.processIdentifier] = nil
                    reader.notify(queue: queue) {
                        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        if finished.terminationReason == .exit && finished.terminationStatus == 0 && text == "ok" {
                            PortalLog.write("file tray: added \(file.lastPathComponent) (\(ms) ms)")
                        } else {
                            PortalLog.write("file tray: failed for \(file.lastPathComponent): status \(finished.terminationStatus) \(text.prefix(120))")
                        }
                    }
                }
            }
            do { try process.run() } catch {
                try? out.fileHandleForWriting.close()
                PortalLog.write("file tray: helper failed to start: \(error.localizedDescription)")
                return
            }
            // The parent's copy of the write end, so the reader sees end of file.
            try? out.fileHandleForWriting.close()

            let pid = process.processIdentifier
            running[pid] = process
            let item = DispatchWorkItem {
                guard running[pid] != nil else { return }
                PortalLog.write("file tray: helper timed out after \(Int(timeout)) s, stopping it")
                stop(pid)
            }
            deadline = item
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    /// Stops every helper still running. Called from `deactivate()`.
    static func cancelAll() {
        queue.async {
            for pid in running.keys { stop(pid) }
        }
    }

    /// SIGTERM to the helper's whole process group (Process starts it in a
    /// group of its own, so a negative pid never reaches Droppy), SIGKILL after
    /// a short grace if it is still there. Runs on `queue`.
    private static func stop(_ pid: pid_t) {
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        queue.asyncAfter(deadline: .now() + killGrace) {
            if running[pid] != nil, kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
    }
}
