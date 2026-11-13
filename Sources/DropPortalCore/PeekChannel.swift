//
//  PeekChannel.swift
//  DropPortalCore
//
//  The live channel for peeks: a WebSocket listener on its own port
//  (Network's NWProtocolWebSocket does the framing). The first message must be
//  {"type":"hello","t":<token>}; anything else, or a wrong token, closes the
//  socket. Uploads never depend on it: when it is down there is no preview.
//

import Foundation
import Network

public final class PeekChannel: @unchecked Sendable {
    /// The page connects to this port on the host it was loaded from.
    public static let defaultPort: UInt16 = 8788

    public let port: UInt16
    /// Open sockets at most; a phone needs one.
    public var maxConnections = 4
    /// Seconds a socket may stay open without saying hello.
    public var helloTimeout: TimeInterval = 5
    /// Seconds an authenticated socket may stay silent. The page beats every
    /// second while a card is dragged and pings every 10 s otherwise, so a
    /// phone that left without closing counts as gone within half a minute.
    public var idleTimeout: TimeInterval = 30

    /// Called on the main queue.
    public var onEvent: (@Sendable (PeekEvent) -> Void)?
    /// Called on the main queue: whether the listener is up.
    public var onReady: (@Sendable (Bool) -> Void)?
    /// A page said hello with the right token (on the main queue): files queued
    /// while no page was open go out now.
    public var onPaired: (@Sendable () -> Void)?
    /// Whether a phone page is open right now (`PhonePresence`), on the main
    /// queue, each time it changes.
    public var onPresence: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "portal.peek")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var tracker: PeekTracker
    private var presence = PhonePresence()
    private var ticker: DispatchSourceTimer?
    private let tokenLock = NSLock()
    private var _token = ""
    private var stopped = false
    private var retryDelay: TimeInterval = 1

    public init(port: UInt16 = PeekChannel.defaultPort, timeout: TimeInterval = PeekTracker.defaultTimeout) {
        self.port = port
        self.tracker = PeekTracker(timeout: timeout)
    }

    public var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set {
            tokenLock.lock()
            let changed = _token != newValue
            _token = newValue
            tokenLock.unlock()
            // A new pairing token (Reset pairing) must not leave the old phone connected.
            if changed { queue.async { [self] in closeAllClients() } }
        }
    }

    private var _effect = PortalEffect.default
    private var _tint = PortalTint.defaultTint(for: .default)
    /// The crossing effect: sent with "ready", and again to every open page when it changes.
    public var effect: PortalEffect {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _effect }
        set { setEffect(newValue, tint: tint) }
    }
    /// The effect's colour, sent with the effect.
    public var tint: PortalTint {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _tint }
        set { setEffect(effect, tint: newValue) }
    }

    private var _kinetic = true
    /// The kinetic filename on the page's "Sent" line (LandingTouches.swift): sent with the effect.
    public var kineticName: Bool {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _kinetic }
        set { setEffect(effect, tint: tint, kinetic: newValue) }
    }

    /// Sets both and tells every open page once when either changed.
    public func setEffect(_ effect: PortalEffect, tint: PortalTint, kinetic: Bool? = nil) {
        tokenLock.lock()
        let kinetic = kinetic ?? _kinetic
        let changed = _effect != effect || _tint != tint || _kinetic != kinetic
        _effect = effect
        _tint = tint
        _kinetic = kinetic
        tokenLock.unlock()
        if changed {
            let message = Self.effectMessage("effect", effect, tint, kinetic: kinetic)
            queue.async { [self] in
                for client in clients.values where client.authenticated { client.send(message) }
            }
        }
    }

    /// `{"type":<type>,"effect":<raw value>,"tint":<#RRGGBB or rainbow>}`; both are plain words.
    /// `"kinetic":false` is added only when the kinetic filename is off (the page's default is on).
    static func effectMessage(_ type: String, _ effect: PortalEffect, _ tint: PortalTint, kinetic: Bool = true) -> String {
        #"{"type":"\#(type)","effect":"\#(effect.rawValue)","tint":"\#(tint.stored)"\#(kinetic ? "" : #","kinetic":false"#)}"#
    }

    public func start() {
        queue.async { [self] in
            stopped = false
            guard listener == nil else { return }
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.maximumMessageSize = PeekMessage.maxMessageBytes
            // Keepalive: a phone that left the Wi-Fi without a FIN is noticed in about a minute.
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 3
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            guard let port = NWEndpoint.Port(rawValue: port),
                  let listener = try? NWListener(using: params, on: port) else {
                listenerFailed()
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.retryDelay = 1; self?.report(true)
                case .failed: self?.listenerFailed()
                case .cancelled: self?.report(false)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
            listener.start(queue: queue)
            self.listener = listener

            guard ticker == nil else { return }
            let ticker = DispatchSource.makeTimerSource(queue: queue)
            ticker.schedule(deadline: .now() + 0.5, repeating: 0.5)
            ticker.setEventHandler { [weak self] in self?.tick() }
            ticker.resume()
            self.ticker = ticker
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            retryDelay = 1
            ticker?.cancel()
            ticker = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            closeAllClients()
            tracker = PeekTracker(timeout: tracker.timeout)
            if presence.reset() { reportPresence() }
        }
    }

    /// Sends `object` as JSON to every paired page (a file offered from the Mac,
    /// the Mac's clipboard); `done` hears on the main queue how many got it.
    public func broadcast(_ object: [String: Any], done: (@Sendable (Int) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            DispatchQueue.main.async { done?(0) }
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        queue.async { [self] in
            let paired = clients.values.filter(\.authenticated)
            for client in paired { client.send(text) }
            let count = paired.count
            DispatchQueue.main.async { done?(count) }
        }
    }

    /// The file for peek `id` arrived; the peek needs no cancel.
    public func finish(id: String) {
        queue.async { [self] in tracker.finish(id: id) }
    }

    // MARK: On `queue`

    private func report(_ ready: Bool) {
        let handler = onReady
        DispatchQueue.main.async { handler?(ready) }
    }

    private func reportPresence() {
        let handler = onPresence, connected = presence.isConnected
        DispatchQueue.main.async { handler?(connected) }
    }

    private func emit(_ event: PeekEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    private func closeAllClients() {
        for client in Array(clients.values) { client.close() }
        clients.removeAll()
    }

    /// The listener died (for example the network stack reset): try again with
    /// a growing pause, 1 s up to 30 s, until it is up or `stop()` is called.
    private func listenerFailed() {
        report(false)
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        guard !stopped else { return }
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.listener == nil else { return }
            self.start()
        }
    }

    private func tick() {
        if let event = tracker.expire() { emit(event) }
        if presence.tick() { reportPresence() }
        let now = Date()
        for client in Array(clients.values) {
            let limit = client.authenticated ? idleTimeout : helloTimeout
            let since = client.authenticated ? client.lastMessage : client.opened
            if now.timeIntervalSince(since) > limit { client.close() }
        }
    }

    private func accept(_ nw: NWConnection) {
        guard clients.count < maxConnections else {
            nw.cancel()
            return
        }
        let client = Client(nw)
        let id = ObjectIdentifier(client)
        clients[id] = client
        client.onClose = { [weak self, weak client] in
            guard let self else { return }
            self.clients[id] = nil
            if client?.authenticated == true { self.presence.closed() }
        }
        client.onMessage = { [weak self, weak client] data in
            guard let self, let client else { return }
            self.received(data, from: client)
        }
        client.start(on: queue)
    }

    private func received(_ data: Data, from client: Client) {
        client.lastMessage = Date()
        let message: PeekMessage
        do {
            message = try PeekMessage.parse(data)
        } catch {
            // Before hello, any garbage closes; after it, one bad message is dropped.
            if !client.authenticated { client.close(policy: true) }
            return
        }
        if !client.authenticated {
            guard case .hello(let given) = message, PairingToken.matches(given, expected: token) else {
                return client.close(policy: true)
            }
            client.authenticated = true
            client.send(Self.effectMessage("ready", effect, tint, kinetic: kineticName))
            if presence.opened() { reportPresence() }
            let handler = onPaired
            DispatchQueue.main.async { handler?() }
            return
        }
        if let event = tracker.handle(message) { emit(event) }
    }
}

// MARK: - One socket

private final class Client {
    private let nw: NWConnection
    let opened = Date()
    var lastMessage = Date()
    var authenticated = false
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(_ nw: NWConnection) { self.nw = nw }

    func start(on queue: DispatchQueue) {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    private func receive() {
        nw.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.closed else { return }
            if error != nil { return self.close() }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                if let data { self.onMessage?(data) }
            case .close?:
                return self.close()
            case .binary?:
                // Only JSON text is spoken here.
                return self.close(policy: true)
            default:
                break
            }
            if !self.closed { self.receive() }
        }
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        nw.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Closes the socket; `policy` sends close code 1008 first (a wrong token).
    func close(policy: Bool = false) {
        guard !closed else { return }
        closed = true
        onMessage = nil
        if policy {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.policyViolation)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            nw.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [nw] _ in
                nw.cancel()
            })
        } else {
            nw.cancel()
        }
        onClose?()
        onClose = nil
    }
}
