//
//  DropPortalServer.swift
//  DropPortalCore
//
//  A tiny HTTP server on the local network, built on NWListener. Serves the
//  phone page and takes uploads, which stream to disk and never sit in memory.
//

import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

public final class DropPortalServer: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxUpload: Int64 = 2 * 1024 * 1024 * 1024
        public var maxText = 1024 * 1024
        public var maxConnections = 8
        /// Seconds without a byte before a connection is dropped.
        public var idleTimeout: TimeInterval = 30
        public init() {}
    }

    public enum State: Equatable, Sendable {
        case stopped, starting, ready, waiting(String), failed(String)

        /// A flat string for the shared preference and the file log.
        public var encoded: String {
            switch self {
            case .stopped: "stopped"
            case .starting: "starting"
            case .ready: "ready"
            case .waiting(let reason): "waiting:\(reason)"
            case .failed(let reason): "failed:\(reason)"
            }
        }

        public init(encoded: String) {
            let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
            let reason = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "starting": self = .starting
            case "ready": self = .ready
            case "waiting": self = .waiting(reason)
            case "failed": self = .failed(reason)
            default: self = .stopped
            }
        }
    }

    public let port: UInt16
    public let limits: Limits
    /// Where finished files go. Created on demand.
    public let destination: URL

    /// Called on the main queue.
    public var onState: (@Sendable (State) -> Void)?
    /// The saved file and the peek id the phone sent with it, if any.
    public var onFile: (@Sendable (URL, String?) -> Void)?
    public var onText: (@Sendable (String) -> Void)?
    /// A file the Mac's own Finder Quick Action handed over (`POST /send-to-iphone`,
    /// localhost only), staged in `outbox`: the droplet offers it to the phone.
    public var onOutgoing: (@Sendable (URL) -> Void)?
    /// An offered file the phone downloaded to the last byte (the droplet removes a zipped folder after a while).
    public var onDownloaded: (@Sendable (URL) -> Void)?
    /// The phone asked for a Recent entry again (`POST /history/<id>/send`): the droplet offers it afresh.
    public var onResend: (@Sendable (URL) -> Void)?
    /// Where `/send-to-iphone` stages its copies; `nil` refuses that route.
    public let outbox: URL?
    /// The Mac's own path for files headed to the phone.
    public static let sendPath = "/send-to-iphone"

    private let queue = DispatchQueue(label: "portal.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let tokenLock = NSLock()
    private var _token = ""
    /// Files the Mac offered to the phone, by id, newest last. Under `tokenLock`.
    private var offers: [Offer] = []
    static let maxOffers = 50

    /// A file on this Mac the phone may download as `GET /download/<id>?t=<token>`.
    public struct Offer: Equatable, Sendable {
        public let id: String
        public let url: URL
        public let name: String
        public let size: Int64
        public var kind: String {
            let type = UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video" : "file"
        }
    }

    public init(port: UInt16 = 8787, destination: URL, outbox: URL? = nil, limits: Limits = Limits()) {
        self.port = port
        self.destination = destination
        self.outbox = outbox
        self.limits = limits
    }

    /// True for 127.0.0.0/8, ::1 and ::ffff:127.x: a request from this Mac itself.
    public static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || (address.asIPv4?.isLoopback ?? false)
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private var _effect = PortalEffect.default
    private var _tint = PortalTint.defaultTint(for: .default)
    /// The crossing effect written into the page. Safe from any thread.
    public var effect: PortalEffect {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _effect }
        set { tokenLock.lock(); _effect = newValue; tokenLock.unlock() }
    }
    /// The effect's colour written into the page. Safe from any thread.
    public var tint: PortalTint {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _tint }
        set { tokenLock.lock(); _tint = newValue; tokenLock.unlock() }
    }

    public func setEffect(_ effect: PortalEffect, tint: PortalTint) {
        tokenLock.lock(); _effect = effect; _tint = tint; tokenLock.unlock()
    }

    private var _opensLinks = true
    /// Text that is one web link opens on the Mac; the page is told so in the reply. Safe from any thread.
    public var opensLinks: Bool {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _opensLinks }
        set { tokenLock.lock(); _opensLinks = newValue; tokenLock.unlock() }
    }

    private var _history: [TransferRecord] = []
    /// The Recent list the phone may see and download from; only these paths are served. Safe from any thread.
    public var history: [TransferRecord] {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _history }
        set { tokenLock.lock(); _history = newValue; tokenLock.unlock() }
    }
    /// Small JPEGs of Recent photos, by path. On `queue` only.
    private var thumbs: [String: Data] = [:]

    private var _shortcuts: [PhoneShortcut: Data] = [:]
    /// The signed phone shortcuts, served at each one's `path`; a missing one is not ready yet. Safe from any thread.
    public func shortcut(_ kind: PhoneShortcut) -> Data? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return _shortcuts[kind]
    }

    public func setShortcut(_ data: Data?, for kind: PhoneShortcut) {
        tokenLock.lock(); _shortcuts[kind] = data; tokenLock.unlock()
    }

    /// Drops every signed shortcut (a new token or address is coming).
    public func clearShortcuts() {
        tokenLock.lock(); _shortcuts.removeAll(); tokenLock.unlock()
    }

    /// The pairing token every request must carry. Safe from any thread.
    public var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }

    /// Makes `url` downloadable by a paired phone; nil when it is not a readable regular file.
    public func offer(_ url: URL) -> Offer? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let offer = Offer(id: id, url: url, name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0))
        tokenLock.lock()
        offers.append(offer)
        if offers.count > Self.maxOffers { offers.removeFirst(offers.count - Self.maxOffers) }
        tokenLock.unlock()
        return offer
    }

    private func offer(id: String) -> Offer? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return offers.first { $0.id == id }
    }

    /// Starts listening on `port`. No Bonjour advertisement: Droppy's
    /// Info.plist declares only its own `NSBonjourServices`, so advertising
    /// `_http._tcp` from inside Droppy fails with `DNS Error: NoAuth` and takes
    /// the whole listener down with it. The phone finds the Mac by the QR code.
    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            report(.starting)
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.report(.ready)
                    case .waiting(let error): self?.report(.waiting(Self.describe(error)))
                    case .failed(let error):
                        // Report the failure and keep it: tearing down must not
                        // overwrite it with `.stopped`.
                        self?.tearDown()
                        self?.report(.failed(Self.describe(error)))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                report(.failed("\(error)"))
            }
        }
    }

    /// Closes the listener and every open connection, removing partial files.
    public func stop() {
        tokenLock.lock(); offers.removeAll(); tokenLock.unlock()
        queue.async { [self] in
            tearDown()
            report(.stopped)
        }
    }

    /// On `queue` only.
    private func tearDown() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func report(_ state: State) {
        let handler = onState
        DispatchQueue.main.async { handler?(state) }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port in use by another app"
        }
        return error.localizedDescription
    }

    private func accept(_ nw: NWConnection) {
        guard connections.count < limits.maxConnections else {
            nw.cancel()
            return
        }
        let connection = Connection(nw, server: self)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.onClose = { [weak self] in self?.connections[id] = nil }
        connection.start(on: queue)
    }

    // MARK: Routing, on `queue`

    fileprivate enum Route {
        case respond(HTTPResponse)
        case upload(name: String, length: Int64, peek: String?)
        /// A file from this Mac for the phone, staged in `outbox`.
        case stage(name: String, length: Int64, folder: URL)
        case text(length: Int)
        case download(Offer)
    }

    fileprivate func route(_ head: HTTPRequestHead, local: Bool) -> Route {
        switch (head.method, head.path) {
        case ("POST", Self.sendPath):
            // The Finder Quick Action on this Mac; the phone never reaches it.
            guard local else { return .respond(.text(404, "Not found")) }
            guard PairingToken.matches(head.headers["x-dropportal-token"], expected: token) else {
                return .respond(.json(403, ["error": "pairing"]))
            }
            // The Quick Action names the item by its path (a folder cannot be a request body):
            // the droplet offers it as it offers Finder's selection, zipping a folder.
            if let raw = head.headers["x-dropportal-path"] {
                guard let item = Self.localItem(raw) else { return .respond(.json(404, ["error": "missing"])) }
                deliver(outgoing: item)
                return .respond(.json(200, ["ok": "1"]))
            }
            guard let outbox else { return .respond(.json(503, ["error": "unavailable"])) }
            guard let length = head.contentLength else { return .respond(.json(411, ["error": "length"])) }
            guard length <= limits.maxUpload else { return .respond(.json(413, ["error": "too large"])) }
            let raw = head.headers["x-dropportal-name"].flatMap { $0.removingPercentEncoding } ?? "file"
            return .stage(name: FileNames.sanitize(raw), length: length, folder: outbox)
        case ("GET", "/"):
            guard PairingToken.matches(head.query["t"], expected: token) else {
                return .respond(.text(403, "Scan the QR code in Drop Portal's settings on your Mac."))
            }
            return .respond(HTTPResponse(
                status: 200,
                contentType: "text/html; charset=utf-8",
                body: Data(WebPage.html(effect: effect, tint: tint).utf8),
                extraHeaders: [("Content-Security-Policy",
                                WebPage.contentSecurityPolicy(socketHost: WebPage.socketHost(head.headers["host"])))]
            ))
        case ("GET", TouchIcon.path):
            return .respond(HTTPResponse(status: 200, contentType: "image/png", body: TouchIcon.png,
                                         extraHeaders: [("Cache-Control", "max-age=86400")]))
        case ("GET", WebManifest.path):
            // Static data, like the icon: no token, nothing of the pairing in it.
            return .respond(HTTPResponse(status: 200, contentType: "application/manifest+json", body: WebManifest.json,
                                         extraHeaders: [("Cache-Control", "max-age=86400")]))
        case ("GET", let path) where PhoneShortcut(path: path) != nil:
            // It carries the token, so it goes only to someone who has it already.
            guard PairingToken.matches(head.query["t"], expected: token) else {
                return .respond(.text(403, "Scan the QR code in Drop Portal's settings on your Mac."))
            }
            let kind = PhoneShortcut(path: path) ?? .share
            guard let data = shortcut(kind) else {
                return .respond(.text(503, "Getting the shortcut ready. Try again in a moment."))
            }
            return .respond(HTTPResponse(
                status: 200,
                contentType: "application/octet-stream",
                body: data,
                extraHeaders: [("Content-Disposition", "attachment; filename=\"\(kind.fileName)\"")]
            ))
        case ("POST", "/upload"), ("POST", "/text"):
            guard PairingToken.matches(head.headers["x-dropportal-token"], expected: token) else {
                return .respond(.json(403, ["error": "pairing"]))
            }
            guard let length = head.contentLength else { return .respond(.json(411, ["error": "length"])) }
            if head.path == "/text" {
                guard length <= limits.maxText else { return .respond(.json(413, ["error": "too large"])) }
                return .text(length: Int(length))
            }
            guard length <= limits.maxUpload else { return .respond(.json(413, ["error": "too large"])) }
            let raw = head.headers["x-dropportal-name"].flatMap { $0.removingPercentEncoding } ?? "file"
            let peek = head.headers["x-dropportal-peek"].flatMap { PeekMessage.isValidID($0) ? $0 : nil }
            return .upload(name: FileNames.sanitize(raw), length: length, peek: peek)
        case ("GET", let path) where path.hasPrefix("/download/"):
            guard PairingToken.matches(head.query["t"], expected: token) else {
                return .respond(.text(403, "Pairing changed. Scan the QR code on your Mac again."))
            }
            guard let offer = offer(id: String(path.dropFirst("/download/".count))) else {
                return .respond(.text(404, "This file is no longer offered. Send it again from your Mac."))
            }
            return .download(offer)
        case (_, "/history"):
            return historyRoute(head)
        case (_, let path) where path.hasPrefix("/history/"):
            return historyRoute(head)
        case (_, Self.sendPath) where local:
            return .respond(.text(405, "Method not allowed"))
        case (_, "/"), (_, "/upload"), (_, "/text"):
            return .respond(.text(405, "Method not allowed"))
        case (_, let path) where PhoneShortcut(path: path) != nil:
            return .respond(.text(405, "Method not allowed"))
        default:
            return .respond(.text(404, "Not found"))
        }
    }

    /// `GET /history`, `GET /history/<id>`, `GET /history/<id>/thumb` (token in `?t=`) and
    /// `POST /history/<id>/send` (token in `X-DropPortal-Token`). Only paths in `history` are served.
    private func historyRoute(_ head: HTTPRequestHead) -> Route {
        let parts = head.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2).map(String.init)
        let post = head.method == "POST"
        guard (post && parts.count == 2 && parts[1] == "send") || (head.method == "GET" && (parts.count < 2 || (parts.count == 2 && parts[1] == "thumb"))) else {
            return .respond(.text(405, "Method not allowed"))
        }
        let given = post ? head.headers["x-dropportal-token"] : head.query["t"]
        guard PairingToken.matches(given, expected: token) else {
            return .respond(post ? .json(403, ["error": "pairing"]) : .text(403, "Pairing changed. Scan the QR code on your Mac again."))
        }
        let items = history.filter { TransferHistory.exists($0.path) }
        guard let id = parts.first else {
            let list: [[String: Any]] = items.map {
                ["id": $0.id, "name": $0.name, "size": $0.size, "dir": $0.direction.rawValue, "kind": $0.kind,
                 "time": Int64($0.date.timeIntervalSince1970 * 1000)]
            }
            let body = (try? JSONSerialization.data(withJSONObject: ["items": list])) ?? Data("{\"items\":[]}".utf8)
            return .respond(HTTPResponse(status: 200, contentType: "application/json", body: body))
        }
        guard TransferRecord.isValidID(id), let record = items.first(where: { $0.id == id }) else {
            return .respond(.text(404, "This file is no longer on your Mac."))
        }
        if post {
            deliver(resend: record.url)
            return .respond(.json(200, ["ok": "1"]))
        }
        let values = try? record.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return .respond(.text(404, "A folder: use Send again.")) }
        if parts.count == 2 {
            guard parts[1] == "thumb", record.kind == "image", let jpeg = thumbnail(record.path) else {
                return .respond(.text(404, "Not found"))
            }
            return .respond(HTTPResponse(status: 200, contentType: "image/jpeg", body: jpeg))
        }
        return .download(Offer(id: record.id, url: record.url, name: record.name, size: Int64(values?.fileSize ?? 0)))
    }

    /// A JPEG at most 160 px, from the file's own embedded thumbnail when it has one.
    private func thumbnail(_ path: String) -> Data? {
        if let hit = thumbs[path] { return hit }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 160]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { return nil }
        if thumbs.count >= TransferHistory.maxItems { thumbs.removeAll() }
        thumbs[path] = data as Data
        return data as Data
    }

    fileprivate func deliver(resend file: URL) {
        let handler = onResend
        DispatchQueue.main.async { handler?(file) }
    }

    fileprivate func deliver(file: URL, peek: String?) {
        let handler = onFile
        DispatchQueue.main.async { handler?(file, peek) }
    }

    /// A percent-encoded absolute path from `X-DropPortal-Path`, if it names an
    /// existing regular file or folder (symlinks resolved).
    static func localItem(_ raw: String) -> URL? {
        guard let path = raw.removingPercentEncoding, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
              values.isRegularFile == true || values.isDirectory == true else { return nil }
        return url
    }

    fileprivate func deliver(outgoing file: URL) {
        let handler = onOutgoing
        DispatchQueue.main.async { handler?(file) }
    }

    fileprivate func deliver(downloaded file: URL) {
        let handler = onDownloaded
        DispatchQueue.main.async { handler?(file) }
    }

    fileprivate func deliver(text: String) {
        let handler = onText
        DispatchQueue.main.async { handler?(text) }
    }
}

// MARK: - One connection

/// One request and its response. All methods run on the server's queue.
private final class Connection {
    private let nw: NWConnection
    private unowned let server: DropPortalServer
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var closed = false
    /// A response is on its way; nothing more is read.
    private var responded = false

    // The body being read.
    private enum Body {
        case none
        case file(handle: FileHandle, partial: URL, name: String, peek: String?, remaining: Int64, staged: URL? = nil)
        case text(data: Data, remaining: Int)
    }
    private var body = Body.none
    /// The file being sent to the phone.
    private var download: FileHandle?
    private var downloadURL: URL?

    init(_ nw: NWConnection, server: DropPortalServer) {
        self.nw = nw
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastActivity) > self.server.limits.idleTimeout { self.close() }
        }
        timer.resume()
        self.timer = timer
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, !self.responded else { return }
            self.lastActivity = Date()
            if let data, !data.isEmpty { self.consume(data) }
            if self.closed || self.responded { return }
            if error != nil || isComplete {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        switch body {
        case .none:
            buffer.append(data)
            let parsed: (head: HTTPRequestHead, consumed: Int)?
            do {
                parsed = try HTTPRequestHead.parse(buffer)
            } catch HTTPRequestHead.ParseError.tooLarge {
                return respond(.text(431, "Header too large"))
            } catch {
                return respond(.text(400, "Bad request"))
            }
            guard let (head, consumed) = parsed else { return }
            let rest = buffer.subdata(in: buffer.startIndex + consumed..<buffer.endIndex)
            buffer = Data()
            begin(server.route(head, local: DropPortalServer.isLoopback(nw.endpoint)), rest: rest)
        case .file, .text:
            take(data)
        }
    }

    private func begin(_ route: DropPortalServer.Route, rest: Data) {
        switch route {
        case .respond(let response):
            respond(response)
        case .text(let length):
            body = .text(data: Data(), remaining: length)
            finishIfDone()
            if !rest.isEmpty { take(rest) }
        case .download(let offer):
            send(offer)
        case .upload(let name, let length, let peek):
            beginFile(in: server.destination, name: name, peek: peek, length: length, staged: nil, rest: rest)
        case .stage(let name, let length, let folder):
            beginFile(in: folder, name: name, peek: nil, length: length, staged: folder, rest: rest)
        }
    }

    /// `staged` set: the Quick Action's copy, which goes to the phone, not to Downloads.
    private func beginFile(in folder: URL, name: String, peek: String?, length: Int64, staged: URL?, rest: Data) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Partial files live next to the destination, so the final
            // move is a rename on the same volume.
            let partial = folder.appendingPathComponent(".dropportal-\(UUID().uuidString).part")
            guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: partial)
            body = .file(handle: handle, partial: partial, name: name, peek: peek, remaining: length, staged: staged)
        } catch {
            return respond(.json(500, ["error": "disk"]))
        }
        finishIfDone()
        if !rest.isEmpty { take(rest) }
    }

    private func take(_ data: Data) {
        switch body {
        case .none:
            return
        case .text(var collected, let remaining):
            let chunk = data.prefix(remaining)
            collected.append(chunk)
            body = .text(data: collected, remaining: remaining - chunk.count)
        case .file(let handle, let partial, let name, let peek, let remaining, let staged):
            let chunk = data.prefix(Int(min(Int64(data.count), remaining)))
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                return respond(.json(500, ["error": "disk"]))
            }
            body = .file(handle: handle, partial: partial, name: name, peek: peek,
                         remaining: remaining - Int64(chunk.count), staged: staged)
        }
        finishIfDone()
    }

    private func finishIfDone() {
        switch body {
        case .text(let data, 0):
            body = .none
            guard let text = String(data: data, encoding: .utf8) else {
                return respond(.json(400, ["error": "encoding"]))
            }
            server.deliver(text: text)
            let opens = server.opensLinks && PhoneLink.webURL(in: text) != nil
            respond(.json(200, opens ? ["ok": "1", "link": "1"] : ["ok": "1"]))
        case .file(let handle, let partial, let name, _, 0, let staged?):
            body = .none
            try? handle.close()
            // Each staged copy in a folder of its own, so the phone sees the original name.
            let final = staged.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: partial, to: final)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                return respond(.json(500, ["error": "disk"]))
            }
            server.deliver(outgoing: final)
            respond(.json(200, ["ok": "1"]))
        case .file(let handle, let partial, let name, let peek, 0, nil):
            body = .none
            try? handle.close()
            ReceivedFile.quarantine(partial)
            let final = FileNames.unique(name, in: server.destination)
            do {
                try FileManager.default.moveItem(at: partial, to: final)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                return respond(.json(500, ["error": "disk"]))
            }
            server.deliver(file: final, peek: peek)
            respond(.json(200, ["ok": "1", "name": final.lastPathComponent]))
        default:
            break
        }
    }

    /// Streams an offered file in 256 KB pieces, each sent before the next is read.
    private func send(_ offer: DropPortalServer.Offer) {
        guard let handle = try? FileHandle(forReadingFrom: offer.url),
              let size = (try? FileManager.default.attributesOfItem(atPath: offer.url.path)[.size] as? NSNumber)?.int64Value
        else { return respond(.text(404, "This file is no longer on your Mac.")) }
        responded = true
        download = handle
        downloadURL = offer.url
        let type = UTType(filenameExtension: offer.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let head = HTTPResponse.head(status: 200, contentType: type, length: size, extraHeaders: [
            ("Content-Disposition", Self.disposition(offer.name))
        ])
        nw.send(content: head, completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.close(); return }
            self?.pump(remaining: size)
        })
    }

    private func pump(remaining: Int64) {
        guard !closed, let handle = download else { return }
        if remaining <= 0, let url = downloadURL {
            downloadURL = nil
            server.deliver(downloaded: url)
        }
        guard remaining > 0,
              let chunk = try? handle.read(upToCount: Int(min(remaining, 256 * 1024))), !chunk.isEmpty
        else { return close() }
        lastActivity = Date()
        nw.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.close(); return }
            self?.pump(remaining: remaining - Int64(chunk.count))
        })
    }

    /// RFC 5987 attr-chars that need no escape; `.alphanumerics` would let Thai letters through.
    private static let attrChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~")

    /// `attachment` with an ASCII fallback name and the real one in RFC 5987 form.
    static func disposition(_ name: String) -> String {
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
        let encoded = name.addingPercentEncoding(withAllowedCharacters: Self.attrChars) ?? "file"
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    private func respond(_ response: HTTPResponse) {
        guard !closed, !responded else { return }
        responded = true
        discardPartial()
        nw.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func discardPartial() {
        if case .file(let handle, let partial, _, _, _, _) = body {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
        }
        body = .none
    }

    func close() {
        guard !closed else { return }
        closed = true
        discardPartial()
        try? download?.close()
        download = nil
        timer?.cancel()
        timer = nil
        nw.cancel()
        onClose?()
        onClose = nil
    }
}
