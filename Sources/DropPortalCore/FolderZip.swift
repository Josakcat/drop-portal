//
//  FolderZip.swift
//  DropPortalCore
//
//  A folder sent from the Mac goes to the phone as one .zip: `/usr/bin/ditto
//  -c -k --keepParent` writes it to `<staging>/zip-<uuid>/<name>.zip`, the
//  droplet's own folder, never next to the original. The archive is removed a
//  while after the phone downloaded it, or with the other staged copies after
//  a day (`OutgoingQueue.removeStaged`).
//

import Foundation

public enum FolderZip {
    /// The prefix of each archive's own folder in the staging folder.
    public static let folderPrefix = "zip-"
    /// How long an archive stays after its first full download, for a second
    /// phone or a Save after the share sheet's fetch.
    public static let keepAfterDownload: TimeInterval = 600

    /// True for a directory, a package (an .app) included; false for a file or nothing.
    public static func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Where `folder`'s archive is written: its own new folder under `staging`,
    /// named after the folder, so the phone sees "Photos.zip".
    public static func archiveURL(for folder: URL, in staging: URL) -> URL {
        let base = FileNames.sanitize(folder.standardizedFileURL.lastPathComponent)
        let name = base.isEmpty || base == "/" ? "Folder" : base
        return staging.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name + ".zip")
    }

    /// True when `url` is an archive this type wrote under `staging`.
    public static func isArchive(_ url: URL, in staging: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return parent.lastPathComponent.hasPrefix(folderPrefix)
            && parent.deletingLastPathComponent().standardizedFileURL.path == staging.standardizedFileURL.path
            && url.pathExtension == "zip"
    }

    /// Removes an archive and its own folder; anything that is not one of ours is left alone.
    @discardableResult
    public static func remove(_ archive: URL, in staging: URL) -> Bool {
        guard isArchive(archive, in: staging) else { return false }
        return (try? FileManager.default.removeItem(at: archive.standardizedFileURL.deletingLastPathComponent())) != nil
    }

    /// The total size of the files in `folder`, for the "Zipping…" line. Off the main thread.
    public static func size(of folder: URL) -> Int64 {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public enum Failure: Error, Equatable { case notAFolder, failed(Int32), cancelled }

    /// The longest a zip may run.
    public static let timeout: TimeInterval = 600
    private static let queue = DispatchQueue(label: "portal.zip", qos: .userInitiated)
    nonisolated(unsafe) private static var running: [pid_t: Process] = [:]

    /// Zips `folder` into a new archive under `staging` with ditto; `done` on
    /// the main queue with the archive or why not. A failed or cancelled run
    /// leaves nothing behind.
    public static func zip(_ folder: URL, in staging: URL, done: @escaping @Sendable (Result<URL, Failure>) -> Void) {
        let archive = archiveURL(for: folder, in: staging)
        func finish(_ result: Result<URL, Failure>) {
            if case .failure = result { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            DispatchQueue.main.async { done(result) }
        }
        queue.async {
            guard isFolder(folder) else { return finish(.failure(.notAFolder)) }
            do {
                try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return finish(.failure(.failed(-1)))
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archive.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                queue.async {
                    running[finished.processIdentifier] = nil
                    if finished.terminationReason == .uncaughtSignal { return finish(.failure(.cancelled)) }
                    finish(finished.terminationStatus == 0 ? .success(archive) : .failure(.failed(finished.terminationStatus)))
                }
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                running[pid] = process
                // A folder that takes this long is not worth the wait; the caller hears `.cancelled`.
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard running[pid] != nil else { return }
                    if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
                }
            } catch {
                finish(.failure(.failed(-1)))
            }
        }
    }

    /// Stops every running zip (deactivate); their callers hear `.cancelled`.
    public static func cancelAll() {
        queue.async {
            for pid in running.keys where kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        }
    }
}
