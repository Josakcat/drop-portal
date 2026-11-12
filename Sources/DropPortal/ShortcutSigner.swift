//
//  ShortcutSigner.swift
//  DropPortal
//
//  Signs the phone shortcuts with macOS's own `shortcuts sign`, which iOS
//  requires before it imports a shortcut file. "people-who-know-me" signs on
//  this Mac with the user's Apple ID, so the token never leaves the Mac, and
//  the file imports on the user's own iPhone.
//

import DropPortalCore
import Foundation

final class ShortcutSigner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "portal.shortcut", qos: .utility)
    private var process: Process?
    private var generation = 0

    /// Builds and signs whatever `build` makes (a phone shortcut or the Finder
    /// Quick Action's) off the main actor; `done` gets the signed file on the
    /// main queue, or `nil` when signing failed. A newer call or `cancel()`
    /// drops an older result.
    func sign(build: @escaping @Sendable () throws -> Data, done: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            stopProcess()
            generation += 1
            let mine = generation
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("dropportal-shortcut-\(UUID().uuidString)", isDirectory: true)
            let input = folder.appendingPathComponent("in.shortcut")
            let output = folder.appendingPathComponent("out.shortcut")
            // The token is in both files: remove them whatever happens.
            let finish: @Sendable (Data?) -> Void = { data in
                try? FileManager.default.removeItem(at: folder)
                DispatchQueue.main.async { done(data) }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try build().write(to: input)
            } catch {
                PortalLog.write("shortcut build failed: \(error)")
                return finish(nil)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["sign", "--mode", "people-who-know-me", "--input", input.path, "--output", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] ended in
                self?.queue.async {
                    guard let self, self.generation == mine else {
                        try? FileManager.default.removeItem(at: folder)
                        return
                    }
                    self.process = nil
                    let data = ended.terminationStatus == 0 ? try? Data(contentsOf: output) : nil
                    PortalLog.write(data == nil ? "shortcut signing failed (\(ended.terminationStatus))" : "shortcut signed")
                    finish(data)
                }
            }
            do {
                try process.run()
            } catch {
                PortalLog.write("shortcut signing could not start: \(error)")
                return finish(nil)
            }
            self.process = process
            // It takes well under a second; a hung signer must not linger.
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.generation == mine else { return }
                self.stopProcess()
            }
        }
    }

    /// Stops a signing in flight; its result is dropped.
    func cancel() {
        queue.async { [self] in
            generation += 1
            stopProcess()
        }
    }

    /// On `queue` only.
    private func stopProcess() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
