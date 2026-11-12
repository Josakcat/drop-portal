//
//  DropPortalDroplet.swift
//  DropPortal
//

import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import DroppyKit
import DropPortalCore
import Network
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(DropPortalPrincipal)
public final class DropPortalPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { DropPortalDroplet() }
}

/// Drop Portal: flick a photo, video, file or text off the phone's left edge and
/// it lands on this Mac's screen.
@MainActor
public final class DropPortalDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "drop-portal"

    static let port: UInt16 = 8787

    private var host: DropletHost?
    private var server: DropPortalServer?
    /// The live channel for previews while a card is dragged on the phone.
    private var peeks: PeekChannel?
    private var pathMonitor: NWPathMonitor?
    private var addressRecheck: DispatchWorkItem?
    private let landing = LandingPresenter()
    private let signer = ShortcutSigner()
    /// Bumped by every `prepareShortcut`, so an older signing chain stops.
    private var shortcutRound = 0
    /// Signs the Finder Quick Action's shortcut, only when the user asks for it.
    private let quickSigner = ShortcutSigner()
    /// Files waiting for a phone page (main process only).
    private var queue: OutgoingQueue?
    /// The right-edge drop zone and its light (main process only).
    private var edgeWatcher: EdgeDragWatcher?
    private lazy var edge = EdgePortal(presenter: landing)
    /// The Quick Action's file, removed a minute after it was opened.
    private var quickActionCleanup: DispatchWorkItem?
    /// Zipped folders the phone downloaded, removed a while later (or in deactivate).
    private var zipRemovals: [URL: DispatchWorkItem] = [:]
    /// Folders being zipped right now.
    private var zipping = 0
    /// Each zipped folder's original, so Recent lists the folder (and Send again zips it afresh).
    private var archiveSources: [URL: URL] = [:]
    /// The last transfers both ways (main process: the store; settings process: `recent` only).
    private var history = TransferHistory()
    /// Recent transfers, newest first, mirrored to the settings process.
    @Published private(set) var recent: [TransferRecord] = []
    /// Files waiting for the phone, mirrored to the settings process.
    @Published private(set) var waiting = 0

    @Published private(set) var state: DropPortalServer.State = .stopped
    @Published private(set) var token = ""
    @Published private(set) var address: String?
    @Published private(set) var effect: PortalEffect = .default
    /// Each effect's colour, the stored ones and the defaults.
    @Published private(set) var tints: [PortalEffect: PortalTint] = [:]
    @Published private(set) var received = 0
    /// A phone page is open right now (main process writes, `PhonePresence`).
    @Published private(set) var phoneConnected = false
    /// A phone page has said hello to this Mac at least once (main process writes).
    @Published private(set) var phoneSeen = false
    /// The widget shows the full QR code while connected (tapped open), so a second phone can scan.
    @Published var widgetShowsCode = false
    /// The Getting started card was hidden by hand.
    @Published private(set) var guideHidden = false
    /// A short line after something was sent to the phone, gone after a few seconds.
    @Published private(set) var outgoing: String?
    private var outgoingClear: DispatchWorkItem?

    private enum Key {
        static let token = "pairingToken"
        static let effect = "effect"
        /// Each effect's colour, `tint.<effect>`: `#RRGGBB` or `rainbow`.
        static func tint(_ effect: PortalEffect) -> String { "tint.\(effect.rawValue)" }
        static let addToTray = "addToFileTray"
        static let sound = "landingSound"
        static let edgeSend = "edgeSend"
        /// Recent transfers, `TransferHistory.encoded` (main process writes).
        static let history = "transferHistory"
        /// Settings process → main process: "<verb>\n<id>\n<unix time>" (open, reveal, send, clear).
        static let historyCommand = "historyCommand"
        /// Text from the phone that is one web link opens in the default browser.
        static let openLinks = "openLinks"
        /// How many files wait for the phone, for the settings process.
        static let waiting = "waitingCount"
        /// The Fly / Fade / Pop landing animation this setting replaced; read once as Portal light.
        static let legacyTransition = "transition"
        /// The main process's server state, `DropPortalServer.State.encoded`,
        /// for the settings pane when Droppy draws it in its settings process.
        static let serverState = "serverState"
        /// Settings process → main process: paths picked or dropped on "Send to phone".
        static let outbox = "sendOutbox"
        /// Main process → settings process: the last send's status, "<unix time>\n<message>".
        static let outgoing = "outgoingStatus"
        /// Main → settings: a phone page is open right now (live, false when Drop Portal stops).
        static let phoneConnected = "phoneConnected"
        /// Getting started: a phone has connected once; the card was hidden.
        static let phoneSeen = "phoneSeen"
        static let guideHidden = "gettingStartedHidden"
        /// Left behind by the relay this droplet once had; removed on start.
        static let retired = ["relayURL", "relayRoom", "relaySecret", "relayMacSecret",
                              "relayOwnerKey", "relayKey", "relayState"]
    }

    /// Darwin notification names: one per shared key that changes.
    private enum Signal {
        static let state = "app.getdroppy.droplet.drop-portal.server-state"
        static let token = "app.getdroppy.droplet.drop-portal.token"
        static let effect = "app.getdroppy.droplet.drop-portal.effect"
        /// Settings process → main process: the Send clipboard button.
        static let sendClipboard = "app.getdroppy.droplet.drop-portal.send-clipboard"
        /// Settings process → main process: files waiting in `Key.outbox`.
        static let sendFiles = "app.getdroppy.droplet.drop-portal.send-files"
        /// Main process → settings process: `Key.outgoing` changed.
        static let outgoing = "app.getdroppy.droplet.drop-portal.outgoing"
        /// Settings → main: build, sign and open the Finder Quick Action.
        static let quickAction = "app.getdroppy.droplet.drop-portal.quick-action"
        /// Settings → main: the right-edge setting changed.
        static let edge = "app.getdroppy.droplet.drop-portal.edge"
        /// Settings → main: Open links from your phone changed.
        static let links = "app.getdroppy.droplet.drop-portal.links"
        /// Main → settings: Recent changed.
        static let history = "app.getdroppy.droplet.drop-portal.history"
        /// Settings → main: a Recent action waits in `Key.historyCommand`.
        static let historyCommand = "app.getdroppy.droplet.drop-portal.history-command"
        /// Main → settings: `Key.phoneConnected` changed.
        static let phone = "app.getdroppy.droplet.drop-portal.phone"
    }

    private var signals: [PortalSignal] = []
    private var prefsWatch: AnyCancellable?

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drop Portal", isDirectory: true)
    }

    public func activate(host: DropletHost) throws {
        self.host = host
        // Each effect's own landing sound (PortalSound); Droppy's single drop cue cannot tell them apart.
        landing.onLanded = { [weak self] effect in if self?.sound == true { PortalSound.play(effect) } }
        PortalLog.write("activate args=\(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))")
        let prefs = host.preferences
        readEffect()
        readGuide()
        token = prefs.value(forKey: Key.token, default: "")
        if token.isEmpty && !PortalLog.isSettingsHost {
            token = PairingToken.generate()
            prefs.setValue(token, forKey: Key.token)
        }
        address = LocalAddress.ipv4()
        // Both processes draw or serve the QR code, so both follow the network.
        watchNetwork()

        if PortalLog.isSettingsHost {
            // Droppy's settings process only draws the pane. The server lives in
            // the main process; this instance mirrors its state and token.
            readShared()
            signals = [Signal.state, Signal.token, Signal.effect, Signal.history, Signal.phone].map {
                PortalSignal($0) { [weak self] in self?.readShared() }
            } + [PortalSignal(Signal.outgoing) { [weak self] in self?.readOutgoing() }]
            prefsWatch = prefs.didChange.sink { [weak self] _ in self?.readShared() }
            PortalLog.write("settings host: mirroring state \(state.encoded)")
            return
        }

        for key in Key.retired where prefs.value(forKey: key, as: String.self) != nil {
            prefs.setValue(String?.none, forKey: key)
        }
        // `phoneConnected` used to mean "once"; it is live now, and "once" is `phoneSeen`.
        if prefs.value(forKey: Key.phoneConnected, default: false), !phoneSeen {
            phoneSeen = true
            prefs.setValue(true, forKey: Key.phoneSeen)
        }
        setPhoneConnected(false)
        // A pairing reset or a new effect chosen in the settings process reaches the main process here.
        signals = [PortalSignal(Signal.token) { [weak self] in self?.reloadToken() },
                   PortalSignal(Signal.effect) { [weak self] in self?.readEffect() },
                   PortalSignal(Signal.sendClipboard) { [weak self] in self?.sendClipboard() },
                   PortalSignal(Signal.sendFiles) { [weak self] in self?.sendOutbox() },
                   PortalSignal(Signal.quickAction) { [weak self] in self?.addQuickAction() },
                   PortalSignal(Signal.edge) { [weak self] in self?.applyEdge() },
                   PortalSignal(Signal.links) { [weak self] in self?.server?.opensLinks = self?.openLinks ?? true },
                   PortalSignal(Signal.historyCommand) { [weak self] in self?.readHistoryCommand() }]
        prefsWatch = prefs.didChange.sink { [weak self] _ in self?.readEffect() }
        // Partial files a crash or a force quit left behind, off the main actor.
        let folder = Self.folder
        Self.cleanup.async { ReceivedFile.removeOrphanPartials(in: folder, olderThan: 3600) }
        // Quick Action copies older than a day were offered long ago.
        let staged = stagingFolder
        Self.cleanup.async { OutgoingQueue.removeStaged(in: staged, olderThan: OutgoingQueue.lifetime) }
        queue = OutgoingQueue(manifest: host.environment.containerDirectory.appendingPathComponent("outgoing-queue.json"))
        history = TransferHistory(encoded: prefs.value(forKey: Key.history, as: String.self))
        publishWaiting()
        startServer()
        edge.onDrop = { [weak self] urls in self?.send(files: urls, announce: true, from: "edge") }
        edge.promiseFolder = stagingFolder
        edge.onSent = { [weak self] effect in if self?.sound == true { PortalSound.play(effect) } }
        applyEdge()
        // Select files in Finder and press it: they go to the phone. Rebound on Droppy's Shortcuts page.
        host.shortcuts.register(id: Self.shortcutID, title: "Send Finder selection to phone",
                                defaultShortcut: DropletKeyboardShortcut(keyCode: 124, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)) {
            [weak self] in self?.sendFinderSelection()
        }
    }

    static let shortcutID = "send-finder-selection"

    /// Quick Action copies wait here until they are offered (and a day after).
    private var stagingFolder: URL {
        (host?.environment.containerDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Outgoing", isDirectory: true)
    }

    private func startServer() {
        guard server == nil else { return }
        let server = DropPortalServer(port: Self.port, destination: Self.folder, outbox: stagingFolder)
        server.token = token
        server.opensLinks = openLinks
        server.setEffect(effect, tint: tint(for: effect))
        server.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.serverChanged(state) }
        }
        server.onFile = { [weak self] url, peekID in
            MainActor.assumeIsolated { self?.landed(file: url, peekID: peekID) }
        }
        server.onText = { [weak self] text in
            MainActor.assumeIsolated { self?.landed(text: text) }
        }
        server.onOutgoing = { [weak self] url in
            MainActor.assumeIsolated { self?.send(files: [url], playEdge: true) }
        }
        server.onDownloaded = { [weak self] url in
            MainActor.assumeIsolated { self?.downloaded(url) }
        }
        server.onResend = { [weak self] url in
            MainActor.assumeIsolated { self?.send(files: [url], from: "phone recent") }
        }
        server.start()
        self.server = server
        saveHistory()
        prepareShortcut()
        host?.log.info("Drop Portal starting on port \(Self.port)")

        // Previews are a nicety: if this port is taken, files still arrive.
        let peeks = PeekChannel()
        peeks.token = token
        peeks.setEffect(effect, tint: tint(for: effect))
        peeks.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                // A peek queued before tearDown does nothing.
                guard let self, self.host != nil else { return }
                self.landing.peek(event)
            }
        }
        peeks.onReady = { ready in PortalLog.write("peek channel \(ready ? "ready" : "down")") }
        peeks.onPaired = { [weak self] in
            MainActor.assumeIsolated {
                self?.notePhoneSeen()
                self?.deliverWaiting()
            }
        }
        peeks.onPresence = { [weak self] connected in
            MainActor.assumeIsolated { self?.setPhoneConnected(connected) }
        }
        peeks.start()
        self.peeks = peeks
    }

    /// Signs every phone shortcut for the current token, one after another,
    /// the share sheet's first. Until one is ready the server answers its path
    /// with "try again".
    private func prepareShortcut() {
        guard let server else { return }
        server.clearShortcuts()
        shortcutRound += 1
        // The Bonjour name survives a new IP address; an installed shortcut cannot be updated.
        guard let host = LocalAddress.bonjourName() ?? address else { return }
        signShortcuts(PhoneShortcut.allCases[...], host: host, token: token, round: shortcutRound)
    }

    private func signShortcuts(_ kinds: ArraySlice<PhoneShortcut>, host: String, token: String, round: Int) {
        guard let kind = kinds.first else { return }
        let port = Self.port
        signer.sign(build: { try kind.unsigned(host: host, port: port, token: token) }) { [weak self] data in
            MainActor.assumeIsolated {
                // A newer token or address started a new round.
                guard let self, self.shortcutRound == round, let server = self.server else { return }
                server.setShortcut(data, for: kind)
                self.signShortcuts(kinds.dropFirst(), host: host, token: token, round: round)
            }
        }
    }

    private func stopServer() {
        guard let server else { return }
        signer.cancel()
        server.onState = nil
        server.onFile = nil
        server.onText = nil
        server.onOutgoing = nil
        server.onDownloaded = nil
        server.onResend = nil
        server.stop()
        self.server = nil
        peeks?.onEvent = nil
        peeks?.onReady = nil
        peeks?.onPaired = nil
        peeks?.onPresence = nil
        peeks?.stop()
        peeks = nil
        setPhoneConnected(false)
        serverChanged(.stopped)
    }

    private static let cleanup = DispatchQueue(label: "portal.cleanup", qos: .utility)
    private static let network = DispatchQueue(label: "portal.network", qos: .utility)

    /// Reads the address again whenever the network changes, so the QR code
    /// follows the Mac to another Wi-Fi without a Refresh button. DHCP can hand
    /// out the new address a moment after the path changes: look twice.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.networkChanged() } }
        }
        monitor.start(queue: Self.network)
        pathMonitor = monitor
    }

    private func networkChanged() {
        guard host != nil else { return }
        refreshAddress()
        addressRecheck?.cancel()
        let recheck = DispatchWorkItem { [weak self] in self?.refreshAddress() }
        addressRecheck = recheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: recheck)
    }

    private func refreshAddress() {
        let new = LocalAddress.ipv4()
        guard new != address else { return }
        address = new
        PortalLog.write("address \(new == nil ? "none" : "changed")")
    }

    public func deactivate() {
        // Everything activate() started is torn down here. Swift cannot unload
        // code, so anything left running keeps running until Droppy relaunches.
        PortalLog.write("deactivate")
        signals.forEach { $0.cancel() }
        signals = []
        prefsWatch = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        addressRecheck?.cancel()
        addressRecheck = nil
        outgoingClear?.cancel()
        outgoingClear = nil
        if !PortalLog.isSettingsHost { host?.preferences.setValue(String?.none, forKey: Key.outgoing) }
        stopServer()
        FileTray.cancelAll()
        FinderSelection.cancelAll()
        FolderZip.cancelAll()
        zipping = 0
        // The offers went with the server: zipped folders already downloaded go now.
        zipRemovals.values.forEach { $0.perform() }
        zipRemovals = [:]
        archiveSources = [:]
        history.clear()
        quickSigner.cancel()
        quickActionCleanup?.perform()
        quickActionCleanup = nil
        edgeWatcher?.stop()
        edgeWatcher = nil
        edge.tearDown()
        queue = nil
        landing.tearDown()
        state = .stopped
        host = nil
    }

    // MARK: Shared state

    private func serverChanged(_ new: DropPortalServer.State) {
        state = new
        PortalLog.write("server \(new.encoded)")
        if case .failed(let reason) = new { host?.log.error("Drop Portal could not start: \(reason)") }
        host?.preferences.setValue(new.encoded, forKey: Key.serverState)
        PortalSignal.post(Signal.state)
    }

    /// Settings process: read the main process's state and token.
    private func readShared() {
        guard let prefs = host?.preferences else { return }
        state = DropPortalServer.State(encoded: prefs.value(forKey: Key.serverState, default: "stopped"))
        token = prefs.value(forKey: Key.token, default: token)
        let count: Int = prefs.value(forKey: Key.waiting, default: 0)
        if waiting != count { waiting = count }
        let stored = TransferHistory.decode(prefs.value(forKey: Key.history, as: String.self))
        if recent != stored { recent = stored }
        readEffect()
        readGuide()
    }

    private func readGuide() {
        guard let prefs = host?.preferences else { return }
        let seen: Bool = prefs.value(forKey: Key.phoneSeen, default: false)
        let hidden: Bool = prefs.value(forKey: Key.guideHidden, default: false)
        if phoneSeen != seen { phoneSeen = seen }
        if guideHidden != hidden { guideHidden = hidden }
        // The main process owns the live value; only the settings process reads it back.
        if PortalLog.isSettingsHost {
            let connected: Bool = prefs.value(forKey: Key.phoneConnected, default: false)
            if phoneConnected != connected { phoneConnected = connected }
        }
    }

    /// Main process, on a phone's hello: Getting started has done its job.
    private func notePhoneSeen() {
        guard !phoneSeen else { return }
        phoneSeen = true
        host?.preferences.setValue(true, forKey: Key.phoneSeen)
        PortalSignal.post(Signal.phone)
    }

    /// Main process: a phone page opened or went away. The widget follows at once,
    /// the settings process through the preference and `Signal.phone`.
    private func setPhoneConnected(_ connected: Bool) {
        guard !PortalLog.isSettingsHost else { return }
        if phoneConnected != connected {
            phoneConnected = connected
            PortalLog.write("phone \(connected ? "connected" : "gone")")
            // The full code was for a second phone; next time start small again.
            if !connected { widgetShowsCode = false }
        }
        guard let prefs = host?.preferences, prefs.value(forKey: Key.phoneConnected, default: !connected) != connected else { return }
        prefs.setValue(connected, forKey: Key.phoneConnected)
        PortalSignal.post(Signal.phone)
    }

    /// Settings: the Getting started card's Hide button.
    func hideGuide() {
        guideHidden = true
        host?.preferences.setValue(true, forKey: Key.guideHidden)
    }

    /// Getting started shows until a phone has connected or something crossed, or it is hidden.
    var showsGuide: Bool { !phoneSeen && !phoneConnected && !guideHidden && recent.isEmpty }

    /// The newest file that came from the phone, for the widget; nil until one has.
    var latestReceived: TransferRecord? { recent.first { $0.direction == .fromPhone } }

    /// The stored effect; an old Fly / Fade / Pop choice reads as Portal light.
    /// The main process hands it to the page and the peek socket, so an open page switches at once.
    private func readEffect() {
        guard let prefs = host?.preferences else { return }
        let stored = prefs.value(forKey: Key.effect, as: String.self)
            ?? prefs.value(forKey: Key.legacyTransition, as: String.self)
        let new = PortalEffect(stored: stored)
        var newTints: [PortalEffect: PortalTint] = [:]
        for e in PortalEffect.allCases {
            newTints[e] = PortalTint(stored: prefs.value(forKey: Key.tint(e), as: String.self)) ?? .defaultTint(for: e)
        }
        let tint = newTints[new] ?? .defaultTint(for: new)
        let warm = landing.effect != new || landing.tints[new] != tint || landing.tints.isEmpty
        landing.effect = new
        landing.tints = newTints
        // A new effect or colour paints its light off the main thread now, not on the crossing.
        if warm { landing.prepareLight(new) }
        server?.setEffect(new, tint: tint)
        peeks?.setEffect(new, tint: tint)
        if effect != new { effect = new }
        if tints != newTints { tints = newTints }
    }

    /// Main process: the token was reset elsewhere.
    private func reloadToken() {
        guard let prefs = host?.preferences else { return }
        let stored: String = prefs.value(forKey: Key.token, default: token)
        guard stored != token, !stored.isEmpty else { return }
        token = stored
        server?.token = stored
        peeks?.token = stored
        prepareShortcut()
        PortalLog.write("token reloaded")
    }

    // MARK: Arrivals

    private func landed(file: URL, peekID: String?) {
        received += 1
        record(file, .fromPhone)
        if let peekID { peeks?.finish(id: peekID) }
        // Off the main thread: FileTray runs a helper process (see FileTray.swift).
        if host?.preferences.value(forKey: Key.addToTray, default: true) ?? true { FileTray.add(file) }
        landing.land(file: file, peekID: peekID) { [weak self] url in
            // Something that runs when opened (an app, a script, an installer)
            // is shown in Finder instead; Gatekeeper still checks it there.
            if ReceivedFile.revealsInsteadOfOpening(url) {
                self?.host?.workspace.revealInFinder(url)
            } else {
                _ = self?.host?.workspace.open(url)
            }
        }
    }

    func setAddToTray(_ on: Bool) {
        host?.preferences.setValue(on, forKey: Key.addToTray)
        objectWillChange.send()
    }

    var addToTray: Bool { host?.preferences.value(forKey: Key.addToTray, default: true) ?? true }

    func setSound(_ on: Bool) {
        host?.preferences.setValue(on, forKey: Key.sound)
        objectWillChange.send()
    }

    var sound: Bool { host?.preferences.value(forKey: Key.sound, default: true) ?? true }

    private func landed(text: String) {
        received += 1
        if host?.workspace.copyToPasteboard(text) != true {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // One web link (http or https only) also opens in the default browser.
        if openLinks, let link = PhoneLink.webURL(in: text), host?.workspace.open(link) == true {
            PortalLog.write("text: opened a link from the phone")
            _ = host?.notifications.post(DropletNotification(
                id: "link-\(UUID().uuidString)", threadID: "clipboard",
                title: "Opened link from your phone", body: String(link.absoluteString.prefix(120)),
                systemImage: "safari"))
            return
        }
        let preview = String(text.prefix(120))
        let posted = host?.notifications.post(DropletNotification(
            id: "clipboard-\(UUID().uuidString)",
            threadID: "clipboard",
            title: "Clipboard received",
            body: preview,
            systemImage: "doc.on.clipboard"
        )) ?? false
        if !posted { landing.show(text: text) }
    }

    var openLinks: Bool { host?.preferences.value(forKey: Key.openLinks, default: true) ?? true }

    func setOpenLinks(_ on: Bool) {
        host?.preferences.setValue(on, forKey: Key.openLinks)
        objectWillChange.send()
        if PortalLog.isSettingsHost { PortalSignal.post(Signal.links) } else { server?.opensLinks = on }
    }

    // MARK: To the phone

    /// Offers each file to the open phone page, which shows it under From your Mac.
    /// From the settings process the paths go to the main process, which holds the server.
    /// With no page open the files wait (`OutgoingQueue`, up to 24 h) and go out when one connects.
    /// `playEdge`: the right-edge portal plays as feedback (the shortcut, the Quick Action).
    func send(files: [URL], playEdge: Bool = false, announce: Bool = false, from source: String = "app") {
        guard !files.isEmpty else { return }
        if PortalLog.isSettingsHost {
            host?.preferences.setValue(files.map(\.path), forKey: Key.outbox)
            return PortalSignal.post(Signal.sendFiles)
        }
        guard let server, let peeks else { return tell("Drop Portal is not running.") }
        let folders = files.filter(FolderZip.isFolder)
        guard folders.isEmpty else {
            return zip(folders) { [weak self] archives in
                self?.send(files: files.filter { !FolderZip.isFolder($0) } + archives,
                           playEdge: playEdge, announce: announce, from: source)
            }
        }
        let offers = files.compactMap { server.offer($0) }
        guard !offers.isEmpty else {
            PortalLog.write("\(source): nothing to offer (\(files.count) not regular or unreadable)")
            return tell("Could not read the file.")
        }
        if playEdge { edge.play(files: offers.map(\.url)) }
        for offer in offers {
            if let folder = archiveSources[offer.url] {
                record(folder, .toPhone, name: folder.lastPathComponent, size: offer.size)
            } else {
                record(offer.url, .toPhone)
            }
        }
        broadcast(offers, peeks: peeks) { [weak self] count in
            guard let self else { return }
            let files = offers.count == 1 ? "1 file" : "\(offers.count) files"
            if count == 0 {
                self.queue?.add(offers.map(\.url))
                self.publishWaiting()
                PortalLog.write("\(source): no phone page paired, queued \(offers.count) file(s), \(self.queue?.count ?? 0) waiting")
                self.tell("Waiting for your phone — open Drop Portal", ok: true,
                          banner: playEdge || announce ? "Waiting for your phone" : nil)
            } else {
                PortalLog.write("\(source): offered \(offers.count) file(s) to \(count) phone page(s)")
                self.tell("Sent \(files) to your phone.", ok: true)
            }
        }
    }

    /// Zips each folder into the staging folder (`FolderZip`), then hands the
    /// archives on. "Zipping…" shows when it takes more than half a second.
    private func zip(_ folders: [URL], then: @escaping @MainActor ([URL]) -> Void) {
        let staging = stagingFolder
        let batch = ZipBatch(left: folders.count)
        zipping += 1
        let name = folders.count == 1 ? "\u{201C}\(folders[0].lastPathComponent)\u{201D}" : "\(folders.count) folders"
        let slow = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tell("Zipping \(name)\u{2026}", ok: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: slow)
        for folder in folders {
            FolderZip.zip(folder, in: staging) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, self.host != nil else { return slow.cancel() }
                    switch result {
                    case .success(let archive):
                        batch.archives.append(archive)
                        self.archiveSources[archive] = folder
                    case .failure(let why): PortalLog.write("zip: \(folder.lastPathComponent) failed \(why)")
                    }
                    batch.left -= 1
                    guard batch.left == 0 else { return }
                    let archives = batch.archives
                    slow.cancel()
                    self.zipping = max(0, self.zipping - 1)
                    guard !archives.isEmpty else { return self.tell("Could not zip \(name).") }
                    PortalLog.write("zip: \(archives.count) folder(s) zipped")
                    then(archives)
                }
            }
        }
    }

    /// The phone has a zipped folder: it goes a while later (a second page, a Save after the share sheet).
    private func downloaded(_ url: URL) {
        let staging = stagingFolder
        guard host != nil, FolderZip.isArchive(url, in: staging), zipRemovals[url] == nil else { return }
        let removal = DispatchWorkItem { [weak self] in
            FolderZip.remove(url, in: staging)
            MainActor.assumeIsolated {
                _ = self?.zipRemovals.removeValue(forKey: url)
                _ = self?.archiveSources.removeValue(forKey: url)
            }
        }
        zipRemovals[url] = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + FolderZip.keepAfterDownload, execute: removal)
    }

    // MARK: Recent

    /// Main process: one transfer at the top of Recent.
    private func record(_ url: URL, _ direction: TransferRecord.Direction, name: String? = nil, size: Int64? = nil) {
        guard !PortalLog.isSettingsHost, host != nil else { return }
        history.add(url, direction: direction, name: name, size: size)
        saveHistory()
    }

    /// Main process: drops entries whose file is gone, then hands the list to
    /// the preferences (for the settings process), the server (for the phone) and the pane.
    private func saveHistory() {
        guard !PortalLog.isSettingsHost, let prefs = host?.preferences else { return }
        history.prune()
        let encoded = history.encoded
        if prefs.value(forKey: Key.history, as: String.self) != encoded {
            prefs.setValue(history.items.isEmpty ? nil : encoded, forKey: Key.history)
            PortalSignal.post(Signal.history)
        }
        server?.history = history.items
        if recent != history.items { recent = history.items }
    }

    enum RecentAction: String { case open, reveal, send, clear }

    /// A click in Recent. The settings process hands it to the main process, which acts.
    func recentAction(_ action: RecentAction, id: String = "") {
        guard !PortalLog.isSettingsHost else {
            host?.preferences.setValue("\(action.rawValue)\n\(id)\n\(Date().timeIntervalSince1970)", forKey: Key.historyCommand)
            return PortalSignal.post(Signal.historyCommand)
        }
        performRecent(action, id: id)
    }

    private func readHistoryCommand() {
        guard let prefs = host?.preferences,
              let stored = prefs.value(forKey: Key.historyCommand, as: String.self) else { return }
        prefs.setValue(String?.none, forKey: Key.historyCommand)
        let parts = stored.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let action = RecentAction(rawValue: parts[0]), let time = Double(parts[2]),
              abs(Date().timeIntervalSince1970 - time) < 10 else { return }
        performRecent(action, id: parts[1])
    }

    private func performRecent(_ action: RecentAction, id: String) {
        guard host != nil else { return }
        if action == .clear {
            history.clear()
            PortalLog.write("recent: cleared")
            return saveHistory()
        }
        guard let item = history.record(id: id) else { return }
        guard TransferHistory.exists(item.path) else {
            saveHistory()
            return tell("\(item.name) is no longer on this Mac.")
        }
        switch action {
        case .open where FolderZip.isFolder(item.url) && !item.url.pathExtension.isEmpty,
             .open where ReceivedFile.revealsInsteadOfOpening(item.url),
             .reveal:
            host?.workspace.revealInFinder(item.url)
        case .open:
            _ = host?.workspace.open(item.url)
        case .send:
            send(files: [item.url], announce: true, from: "recent")
        case .clear:
            break
        }
    }

    /// Each offer to every paired page; `done` hears how many pages got the last one.
    private func broadcast(_ offers: [DropPortalServer.Offer], peeks: PeekChannel, done: @escaping @MainActor (Int) -> Void) {
        for offer in offers {
            peeks.broadcast(["type": "incoming", "id": offer.id, "name": offer.name,
                             "size": offer.size, "kind": offer.kind]) { count in
                guard offer == offers.last else { return }
                MainActor.assumeIsolated { done(count) }
            }
        }
    }

    /// A page said hello: the files that waited for it go out now, offered afresh.
    private func deliverWaiting() {
        guard let queue, !queue.isEmpty, let server, let peeks else { return }
        let offers = queue.take().compactMap { server.offer($0) }
        publishWaiting()
        guard !offers.isEmpty else { return }
        PortalLog.write("delivering \(offers.count) waiting")
        broadcast(offers, peeks: peeks) { [weak self] count in
            guard let self else { return }
            if count == 0 {
                // The page went again before they reached it: they keep waiting.
                self.queue?.add(offers.map(\.url))
                self.publishWaiting()
            } else {
                self.tell(offers.count == 1 ? "Sent 1 waiting file to your phone." : "Sent \(offers.count) waiting files to your phone.", ok: true)
            }
        }
    }

    /// Main process: how many files wait, for the widget and the settings process.
    private func publishWaiting() {
        let count = queue?.count ?? 0
        if waiting != count { waiting = count }
        host?.preferences.setValue(count, forKey: Key.waiting)
    }

    // MARK: Right edge, shortcut, Quick Action

    var edgeSend: Bool { host?.preferences.value(forKey: Key.edgeSend, default: true) ?? true }

    func setEdgeSend(_ on: Bool) {
        host?.preferences.setValue(on, forKey: Key.edgeSend)
        objectWillChange.send()
        if PortalLog.isSettingsHost { PortalSignal.post(Signal.edge) } else { applyEdge() }
    }

    /// Main process: the drag watcher runs only while the setting is on.
    private func applyEdge() {
        guard !PortalLog.isSettingsHost, host != nil else { return }
        if edgeSend {
            guard edgeWatcher == nil else { return }
            let watcher = EdgeDragWatcher()
            watcher.onBegin = { [weak self] types in self?.edge.dragBegan(types: types) }
            watcher.onMove = { [weak self] point in self?.edge.dragMoved(point) }
            watcher.onEnd = { [weak self] in self?.edge.dragEnded() }
            watcher.start()
            edgeWatcher = watcher
            PortalLog.write("edge: drag watcher on")
        } else {
            if edgeWatcher != nil { PortalLog.write("edge: drag watcher off (setting)") }
            edgeWatcher?.stop()
            edgeWatcher = nil
            edge.tearDown()
        }
    }

    /// The shortcut: the files selected in Finder go to the phone.
    private func sendFinderSelection() {
        FinderSelection.read { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.host != nil else { return }
                switch result {
                case .files(let urls) where urls.isEmpty:
                    self.tell("Select files in Finder first.")
                case .files(let urls):
                    self.send(files: urls, playEdge: true)
                case .denied:
                    self.tell("Allow Droppy to control Finder in System Settings › Privacy & Security › Automation.")
                case .failed:
                    self.tell("Could not read the Finder selection.")
                }
            }
        }
    }

    /// Settings: build, sign and open the Finder Quick Action. The main process
    /// does it, so the settings process never holds the token in a file.
    func requestQuickAction() {
        guard !PortalLog.isSettingsHost else { return PortalSignal.post(Signal.quickAction) }
        addQuickAction()
    }

    private func addQuickAction() {
        guard host != nil, !token.isEmpty else { return }
        let port = Self.port, token = token
        let file = stagingFolder.deletingLastPathComponent().appendingPathComponent(QuickActionShortcut.fileName)
        quickSigner.sign(build: { try QuickActionShortcut.unsigned(port: port, token: token) }) { [weak self] data in
            MainActor.assumeIsolated {
                guard let self, self.host != nil else { return }
                guard let data, (try? data.write(to: file, options: .atomic)) != nil else {
                    return self.tell("Could not make the Quick Action. Is Shortcuts on this Mac?")
                }
                _ = self.host?.workspace.open(file)
                self.tell("In Shortcuts, click Add Shortcut. Then right-click files or folders › Quick Actions › Send to phone.", ok: true)
                // It carries the token: gone once Shortcuts has read it.
                self.quickActionCleanup?.cancel()
                let cleanup = DispatchWorkItem { try? FileManager.default.removeItem(at: file) }
                self.quickActionCleanup = cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: cleanup)
            }
        }
    }

    /// Main process: the files the settings pane handed over.
    private func sendOutbox() {
        guard let prefs = host?.preferences,
              let paths = prefs.value(forKey: Key.outbox, as: [String].self), !paths.isEmpty else { return }
        prefs.setValue([String]?.none, forKey: Key.outbox)
        send(files: paths.map { URL(fileURLWithPath: $0) })
    }

    /// Settings process: the main process's last status line, if it is recent.
    private func readOutgoing() {
        let stored: String = host?.preferences.value(forKey: Key.outgoing, default: "") ?? ""
        let parts = stored.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, let time = Double(parts[0]),
              Date().timeIntervalSince1970 - time < 4 else { return outgoing = nil }
        outgoing = parts[1]
        outgoingClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.outgoing = nil } }
        outgoingClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
    }

    /// Pushes the Mac's clipboard text to the open phone page. From the settings
    /// process it asks the main process, which holds the socket.
    func sendClipboard() {
        guard !PortalLog.isSettingsHost else { return PortalSignal.post(Signal.sendClipboard) }
        guard let peeks else { return tell("Drop Portal is not running.") }
        // No DroppyKit call reads the pasteboard; this runs only on the user's click.
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return tell("The clipboard has no text.")
        }
        guard text.utf8.count <= DropPortalServer.Limits().maxText else { return tell("The clipboard is too long (1 MB max).") }
        peeks.broadcast(["type": "clipboard", "text": text]) { [weak self] count in
            MainActor.assumeIsolated {
                self?.tell(count == 0 ? "Open Drop Portal on your phone first." : "Clipboard sent to your phone.",
                           ok: count > 0)
            }
        }
    }

    /// The widget shows `message` for four seconds; a failure is also a banner, for the settings pane.
    private func tell(_ message: String, ok: Bool = false, banner: String? = nil) {
        outgoing = message
        outgoingClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.outgoing = nil } }
        outgoingClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
        if !PortalLog.isSettingsHost {
            host?.preferences.setValue("\(Date().timeIntervalSince1970)\n\(message)", forKey: Key.outgoing)
            PortalSignal.post(Signal.outgoing)
        }
        if let banner {
            _ = host?.notifications.post(DropletNotification(
                id: "outgoing-\(UUID().uuidString)", threadID: "outgoing",
                title: banner, body: "Open Drop Portal on your phone. The files go out as soon as it connects.",
                systemImage: "iphone.and.arrow.forward"))
            return
        }
        guard !ok else { return }
        _ = host?.notifications.post(DropletNotification(
            id: "outgoing-\(UUID().uuidString)", threadID: "outgoing",
            title: "Not sent", body: message, systemImage: "iphone.slash"))
    }

    // MARK: Settings actions

    /// The harness's settings shots: a network address and some Recent rows, without a host.
    func showSample(address: String, recent: [TransferRecord], connected: Bool = false) {
        self.address = address
        state = .ready
        token = PairingToken.generate()
        self.recent = recent
        phoneConnected = connected
        phoneSeen = connected || !recent.isEmpty
    }

    var pageURL: String? {
        address.map { LocalAddress.pageURL(host: $0, port: Self.port, token: token) }
    }

    func shortcutURL(_ kind: PhoneShortcut) -> String? {
        address.map { LocalAddress.shortcutURL(host: $0, port: Self.port, token: token, kind: kind) }
    }

    /// A new token: every phone that scanned the old QR code is locked out.
    func resetPairing() {
        token = PairingToken.generate()
        host?.preferences.setValue(token, forKey: Key.token)
        server?.token = token
        peeks?.token = token
        prepareShortcut()
        PortalSignal.post(Signal.token)
        PortalLog.write("pairing reset")
    }

    func tint(for effect: PortalEffect) -> PortalTint { tints[effect] ?? .defaultTint(for: effect) }

    /// The colour of one effect; the others keep theirs.
    func setTint(_ tint: PortalTint, for effect: PortalEffect) {
        host?.preferences.setValue(tint.stored, forKey: Key.tint(effect))
        PortalSignal.post(Signal.effect)
        readEffect()
    }

    func setEffect(_ value: PortalEffect) {
        host?.preferences.setValue(value.rawValue, forKey: Key.effect)
        PortalSignal.post(Signal.effect)
        readEffect()
    }

    /// Plays an effect (the chosen one by default) on this Mac, in full: a
    /// made-up photo is dragged out of the edge, flicked, lands and is received.
    func previewEffect(_ chosen: PortalEffect? = nil) {
        landing.effect = effect
        landing.prepareLight(chosen ?? effect)
        landing.preview(effect: chosen ?? effect)
    }

    func openShortcuts() {
        _ = host?.workspace.openShortcuts()
    }

    /// The status line under Send to phone and on the widget: the last message, else files waiting.
    var outgoingLine: String? {
        outgoing ?? (waiting > 0 ? "Waiting for your phone — open Drop Portal" : nil)
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        _ = host?.workspace.open(Self.folder)
    }

    /// What is wrong, in plain words; nil while the phone can reach this Mac.
    var problem: String? {
        if address == nil { return "This Mac is not on a network. Connect it to Wi-Fi." }
        return switch state {
        case .ready: nil
        case .starting: "Starting up…"
        case .stopped: "Drop Portal is not running. Switch it off and on in Droppy."
        case .waiting: "Waiting for the network. Check this Mac's Wi-Fi."
        case .failed(let reason) where reason.contains("Port in use"):
            "Another app is using port \(Self.port). Quit it, then switch Drop Portal off and on."
        case .failed(let reason): "Could not start: \(reason)."
        }
    }
}

// MARK: - QR code

@MainActor
enum QRCode {
    private static var cached: [Bool: (text: String, image: NSImage?)] = [:]

    /// The code for `text`, made once per text (the page URL changes only with
    /// the network or the pairing). `quietZone` bakes a white border of three
    /// modules into the picture, for a dark surface such as the shelf.
    static func image(for text: String, quietZone: Bool = false) -> NSImage? {
        if let hit = cached[quietZone], hit.text == text { return hit.image }
        let image = make(text, quietZone: quietZone)
        cached[quietZone] = (text, image)
        return image
    }

    private static func make(_ text: String, quietZone: Bool) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard var output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        if quietZone {
            let pad: CGFloat = 3 * 8
            let extent = output.extent.insetBy(dx: -pad, dy: -pad)
            output = output.composited(over: CIImage(color: .white).cropped(to: extent))
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Settings

extension DropPortalDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        PortalLog.write("settings pane: activated=\(host != nil) state=\(state.encoded)")
        return AnyView(DropPortalSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Connect your phone", keywords: ["iphone", "phone", "qr", "pair", "connect", "scan", "wifi", "hotspot"]),
            SettingsSearchEntry(title: "Send to phone", keywords: ["send", "iphone", "phone", "files", "folders", "drop", "choose", "clipboard", "transfer"]),
            SettingsSearchEntry(title: "Effect", keywords: ["animation", "transition", "portal", "liquid", "wormhole", "beam", "plane", "preview", "look"]),
            SettingsSearchEntry(title: "Color", keywords: ["colour", "color", "tint", "rainbow", "look"]),
            SettingsSearchEntry(title: "Sound", keywords: ["sound", "audio", "chime", "mute", "landing"]),
            SettingsSearchEntry(title: "Recent", keywords: ["history", "recent", "transfers", "sent", "received", "send again", "clear"]),
            SettingsSearchEntry(title: "Phone shortcuts", keywords: ["share", "shortcut", "photos", "files", "safari", "iphone", "clipboard", "latest photo", "action button", "back tap", "siri"]),
            SettingsSearchEntry(title: "Drag to the right edge", keywords: ["edge", "drag", "send", "iphone", "more"]),
            SettingsSearchEntry(title: "Finder Quick Action", keywords: ["finder", "quick action", "right-click", "send", "iphone", "folder", "more"]),
            SettingsSearchEntry(title: "Keyboard shortcut", keywords: ["shortcut", "keys", "finder", "selection", "more"]),
            SettingsSearchEntry(title: "Open links from your phone", keywords: ["link", "url", "browser", "safari", "open", "web", "more"]),
            SettingsSearchEntry(title: "Add received files to File Tray", keywords: ["file tray", "tray", "droppy", "more"]),
            SettingsSearchEntry(title: "Open Drop Portal folder", keywords: ["downloads", "folder", "files", "received", "more"]),
            SettingsSearchEntry(title: "Reset pairing", keywords: ["token", "pair", "security", "reset", "troubleshooting", "status"])
        ]
    }
}

/// The colour row: one swatch per preset, Rainbow last, then the system colour
/// panel for any other colour. Sets the chosen effect's colour.
struct TintPicker: View {
    @Binding var tint: PortalTint

    private static func color(_ rgb: PortalRGB) -> Color { Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue) }

    private var custom: Binding<Color> {
        Binding(get: { Self.color(tint.base()) }, set: { picked in
            guard let c = NSColor(picked).usingColorSpace(.sRGB) else { return }
            tint = .color(PortalRGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent))
        })
    }

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            ForEach(PortalTint.presets, id: \.name) { preset in
                Button { tint = preset.tint } label: { swatch(preset.tint, selected: preset.tint == tint) }
                    .buttonStyle(.borderless)
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(preset.tint == tint ? .isSelected : [])
            }
            ColorPicker("Custom color", selection: custom, supportsOpacity: false)
                .labelsHidden()
                .help("Custom color")
            if tint.presetName == nil {
                Text(tint.stored)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
            }
        }
    }

    @ViewBuilder
    private func swatch(_ value: PortalTint, selected: Bool) -> some View {
        ZStack {
            switch value {
            case .rainbow:
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
            case .color(let rgb):
                Circle().fill(Self.color(rgb))
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
    }
}

/// The folders of one send being zipped; main actor only.
@MainActor
private final class ZipBatch {
    var left: Int
    var archives: [URL] = []
    init(left: Int) { self.left = left }
}
