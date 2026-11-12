//
//  SettingsPane.swift
//  DropPortal
//
//  Drop Portal's page in Droppy's Settings, ordered by what people do most:
//  connect the phone, send to it, choose the look, find a recent transfer,
//  add the iPhone shortcuts; everything else waits under More, closed. Every
//  value comes from the droplet, which in Droppy's settings process mirrors
//  the main process through `host.preferences`; every action goes back the
//  same way. Only layout lives here: no setting key, default or behaviour.
//

import AppKit
import DroppyKit
import DropPortalCore
import SwiftUI

struct DropPortalSettings: View {
    @ObservedObject var droplet: DropPortalDroplet
    /// The phone shortcut whose QR code is showing.
    @State private var shownShortcut: PhoneShortcut?
    @State private var allShortcuts: Bool
    @State private var moreOpen: Bool
    @State private var troubleOpen: Bool

    init(droplet: DropPortalDroplet, expanded: Bool = false) {
        self.droplet = droplet
        _allShortcuts = State(initialValue: expanded)
        _moreOpen = State(initialValue: expanded)
        _troubleOpen = State(initialValue: expanded)
    }

    /// Shortcuts shown before "more".
    private static let firstShortcuts = 2

    var body: some View {
        DropletSettingsPane {
            if droplet.showsGuide { gettingStarted }
            connect
            send
            look
            RecentSection(droplet: droplet)
            shortcuts
            more
        }
    }

    // MARK: Getting started

    /// Three steps for a Mac no phone has used yet; gone after the first connection or Hide.
    private var gettingStarted: some View {
        DropletSettingsSection {
            HStack(alignment: .firstTextBaseline) {
                settingsSectionHeader("Getting started")
                Spacer(minLength: DroppySpacing.md)
                Button("Hide") { droplet.hideGuide() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Hide Getting started")
            }
        } content: {
            DropletSettingsCard {
                DropletControlRow(title: "Scan the QR with your phone camera", icon: "1.circle") { EmptyView() }
                DropletControlRow(title: "Flick a photo off the left edge", icon: "2.circle") { EmptyView() }
                DropletControlRow(title: droplet.edgeSend ? "Send back by dragging to the right edge" : "Send back with ⌃⌥→ in Finder",
                                  icon: "3.circle") { EmptyView() }
            }
        }
    }

    // MARK: Connect your phone

    /// A phone has used this Mac before: it said hello once, or something crossed either way.
    private var hasPhone: Bool { droplet.phoneSeen || !droplet.recent.isEmpty }

    private var status: (title: String, icon: String) {
        if droplet.problem != nil { return ("Not ready", "exclamationmark.triangle") }
        // The live status is the dot line under it (`liveStatus`), not the title.
        return ("Scan with your phone's camera", "qrcode.viewfinder")
    }

    /// Live: green while a phone page is open, grey otherwise (`phoneConnected`).
    private var liveStatus: some View {
        let connected = droplet.phoneConnected && droplet.problem == nil
        return HStack(spacing: DroppySpacing.xs) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(connected ? "Phone connected" : "Not connected")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(connected ? AdaptiveColors.primaryTextAuto : AdaptiveColors.secondaryTextAuto)
        }
        .accessibilityElement(children: .combine)
    }

    private var connect: some View {
        DropletSettingsSection {
            settingsSectionHeader("Connect your phone")
        } content: {
            DropletSettingsCard {
                DropletStackedRow(title: status.title, icon: status.icon) {
                    HStack(alignment: .top, spacing: DroppySpacing.lg) {
                        if let url = droplet.pageURL, let qr = QRCode.image(for: url) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .padding(DroppySpacing.sm)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                                .accessibilityLabel("QR code that opens Drop Portal on your phone")
                        }
                        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                            liveStatus
                            ForEach(connectLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var connectLines: [String] {
        if let problem = droplet.problem { return [problem] }
        if droplet.phoneConnected {
            return ["Flick a photo off the phone's left edge. To add another phone, scan the code."]
        }
        if hasPhone {
            return ["Open Drop Portal on your phone to send. To add another phone, scan the code."]
        }
        return ["Point your phone's camera at the code and tap the link.",
                "Phone and Mac need the same Wi-Fi, or use your phone's Personal Hotspot."]
    }

    // MARK: Send to phone

    private var otherWays: String {
        droplet.edgeSend
            ? "Or drag files to the screen's right edge, press ⌃⌥→ in Finder, or right-click › Quick Actions."
            : "Or press ⌃⌥→ in Finder, or right-click › Quick Actions."
    }

    private var send: some View {
        DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Send to phone")
                Text(otherWays)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            DropletSettingsCard {
                SendDropArea(droplet: droplet)
                DropletControlRow(title: "Clipboard", icon: "doc.on.clipboard",
                                  infoTip: "The text shows on the open phone page with a Copy button.") {
                    Button("Send clipboard") { droplet.sendClipboard() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Look & sound

    private var look: some View {
        DropletSettingsSection {
            settingsSectionHeader("Look & sound")
        } content: {
            DropletSettingsCard {
                DropletGroupedPickerRow(title: "Effect", icon: "sparkles") {
                    Picker("Effect", selection: Binding(get: { droplet.effect }, set: { droplet.setEffect($0) })) {
                        ForEach(PortalEffect.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                DropletStackedRow(title: "Preview", icon: "play.rectangle") {
                    HStack(alignment: .top, spacing: DroppySpacing.md) {
                        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                            // The picture is the button: a click plays the effect on this Mac.
                            Button { droplet.previewEffect() } label: {
                                EffectThumbnail(effect: droplet.effect, tint: droplet.tint(for: droplet.effect))
                            }
                            .buttonStyle(.plain)
                            .help("Play on this Mac")
                            .accessibilityLabel("Play \(droplet.effect.title) on this Mac")
                            Text("Preview of \(droplet.effect.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                        }
                        Text(Self.blurb(droplet.effect))
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DropletStackedRow(title: "Color", icon: "paintpalette",
                                  infoTip: "Each effect keeps its own color, here and on the phone.") {
                    TintPicker(tint: Binding(get: { droplet.tint(for: droplet.effect) },
                                             set: { droplet.setTint($0, for: droplet.effect) }))
                }
                DropletToggleRow(title: "Sound", icon: "speaker.wave.2",
                                 subtitle: "A soft sound when a file lands.",
                                 isOn: Binding(get: { droplet.sound }, set: { droplet.setSound($0) }))
            }
        }
    }

    /// What each effect does, one sentence.
    static func blurb(_ effect: PortalEffect) -> String {
        switch effect {
        case .portal: "A tall rift of light opens on the edge and the card bursts out of it."
        case .liquid: "The card pours through as water and lands in a splash with ripples."
        case .wormhole: "A vortex pulls in stars and spins the card out where it lands."
        case .beam: "Scanlines fill the edge, the card glitches across and is rebuilt by light."
        case .plane: "The card folds into a paper plane that loops in and lands in a puff."
        }
    }

    // MARK: Phone shortcuts

    /// One sentence per shortcut for its ⓘ (the phone page keeps the longer hint).
    static func tip(_ kind: PhoneShortcut) -> String {
        switch kind {
        case .share: "Pick Drop Portal when you share from Photos, Files or Safari."
        case .latestPhoto: "Sends your newest photo or screenshot, handy on the Action button or Back Tap."
        case .clipboard: "Sends the iPhone's clipboard: text, a link or a picture."
        case .pick: "Choose several photos or files and send them at once."
        case .open: "Opens Drop Portal; add it to the Home Screen or Control Center."
        }
    }

    private var shortcuts: some View {
        let kinds = PhoneShortcut.allCases
        let shown = allShortcuts ? kinds : Array(kinds.prefix(Self.firstShortcuts))
        return DropletSettingsSection {
            VStack(alignment: .leading, spacing: 2) {
                settingsSectionHeader("Phone shortcuts")
                Text("For iPhone: click Add, then scan the code with the camera.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        } content: {
            DropletSettingsCard {
                ForEach(shown, id: \.self) { kind in
                    if shownShortcut == kind, let url = droplet.shortcutURL(kind), let qr = QRCode.image(for: url) {
                        DropletStackedRow(title: kind.title, icon: kind.symbol) {
                            HStack(alignment: .top, spacing: DroppySpacing.lg) {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 112, height: 112)
                                    .padding(DroppySpacing.sm)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                                    .accessibilityLabel("QR code that adds \(kind.name) to the iPhone")
                                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                                    Text("Scan with the iPhone camera, then tap Add Shortcut.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Done") { shownShortcut = nil }
                                        .buttonStyle(.bordered)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        DropletControlRow(title: kind.title, icon: kind.symbol, infoTip: Self.tip(kind)) {
                            Button("Add") { shownShortcut = kind }
                                .buttonStyle(.bordered)
                                .disabled(droplet.shortcutURL(kind) == nil)
                                .accessibilityLabel("Add \(kind.name)")
                        }
                    }
                }
                if kinds.count > Self.firstShortcuts {
                    DisclosureRow(title: allShortcuts ? "Fewer shortcuts" : "\(kinds.count - Self.firstShortcuts) more shortcuts",
                                  icon: "ellipsis.circle", isOpen: $allShortcuts)
                }
            }
        }
    }

    // MARK: More

    private var more: some View {
        DropletSettingsSection {
            settingsSectionHeader("More")
        } content: {
            DropletSettingsCard {
                DisclosureRow(title: "Options", icon: "slider.horizontal.3", isOpen: $moreOpen)
                if moreOpen {
                    DropletToggleRow(title: "Add received files to File Tray", icon: "tray.and.arrow.down",
                                     subtitle: "Files also appear in Droppy's File Tray.",
                                     isOn: Binding(get: { droplet.addToTray }, set: { droplet.setAddToTray($0) }))
                    DropletToggleRow(title: "Open links from your phone", icon: "safari",
                                     subtitle: "A link you send from the phone opens in your browser.",
                                     isOn: Binding(get: { droplet.openLinks }, set: { droplet.setOpenLinks($0) }))
                    DropletToggleRow(title: "Drag to the right edge", icon: "arrow.right.to.line",
                                     subtitle: "Dragging files to the screen's right edge sends them.",
                                     isOn: Binding(get: { droplet.edgeSend }, set: { droplet.setEdgeSend($0) }))
                    DropletControlRow(title: "Keyboard shortcut", icon: "keyboard",
                                      infoTip: "Select files in Finder and press ⌃⌥→ to send them.") {
                        Button("Change…") { droplet.openShortcuts() }
                            .buttonStyle(.bordered)
                    }
                    DropletControlRow(title: "Finder Quick Action", icon: "contextualmenu.and.cursorarrow",
                                      infoTip: "Adds Send to phone to Finder's right-click menu, for files and folders.") {
                        Button("Add…") { droplet.requestQuickAction() }
                            .buttonStyle(.bordered)
                    }
                    DropletControlRow(title: "Smaller files", icon: "arrow.down.right.and.arrow.up.left",
                                      infoTip: "Tick Smaller files on the phone page to shrink photos before they are sent.") {
                        Text("On the phone page")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                    }
                    DropletControlRow(title: "Received files", icon: "folder",
                                      infoTip: "Files from your phone are saved in Downloads › Drop Portal.") {
                        Button("Open Drop Portal folder") { droplet.openFolder() }
                            .buttonStyle(.bordered)
                    }
                    DisclosureRow(title: "Troubleshooting", icon: "wrench.and.screwdriver", isOpen: $troubleOpen)
                    if troubleOpen {
                        DropletStackedRow(title: "Status", icon: droplet.problem == nil ? "info.circle" : "exclamationmark.triangle") {
                            Text(statusDetail)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        DropletControlRow(title: "Pairing", icon: "key",
                                          infoTip: "A new code disconnects every phone; add the shortcuts and Quick Action again after it.") {
                            Button("Reset pairing") { droplet.resetPairing() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    /// Where the phone finds this Mac, without the pairing code; or what is wrong.
    private var statusDetail: String {
        if let problem = droplet.problem { return problem }
        let address = droplet.address ?? "no network"
        return "Running on \(address), port \(DropPortalDroplet.port)."
    }
}

/// A row that opens or closes the rows under it.
private struct DisclosureRow: View {
    let title: String
    let icon: String
    @Binding var isOpen: Bool

    var body: some View {
        DropletControlRow(title: title, icon: icon) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: DroppySpacing.xs) {
                    Text(isOpen ? "Hide" : "Show")
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isOpen ? "Hide \(title)" : "Show \(title)")
        }
    }
}

/// The chosen effect in its colour, mid-crossing, drawn once per effect and colour.
private struct EffectThumbnail: View {
    let effect: PortalEffect
    let tint: PortalTint
    @State private var image: NSImage?
    @State private var shownKey = ""
    @State private var hovering = false

    private var key: String { "\(effect.rawValue) \(tint.stored)" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(Color.black)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            // A play button, so the still never reads as a screenshot.
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 1)
                .frame(width: 38, height: 38)
                .background(.black.opacity(hovering ? 0.65 : 0.45), in: Circle())
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .frame(width: 176, height: 110)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
        .task(id: key) {
            guard shownKey != key else { return }
            // Let the picker close first; the drawing takes a moment on the main actor.
            await Task.yield()
            image = PortalPreview.thumbnail(effect, tint: tint)
            shownKey = key
        }
    }
}

/// Pictures of the settings page for the harness (`--settings-shots <dir>`):
/// closed and open, light and dark, a new Mac and one a phone has used.
public enum SettingsPreview {
    @MainActor
    public static func writeShots(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let samples = [
            TransferRecord(name: "IMG_4821.HEIC", path: "/sample/IMG_4821.HEIC", size: 3_481_000, direction: .fromPhone, date: now.addingTimeInterval(-20)),
            TransferRecord(name: "Quarterly report final v3.pdf", path: NSTemporaryDirectory(), size: 812_000, direction: .toPhone, date: now.addingTimeInterval(-3_700)),
        ]
        var urls: [URL] = []
        for (name, recent, expanded, dark, height) in [
            ("settings-new-dark", [TransferRecord](), false, true, 1820.0),
            ("settings-new-light", [], false, false, 1820),
            ("settings-used-dark", samples, false, true, 1640),
            ("settings-used-light", samples, false, false, 1640),
            ("settings-connected-dark", samples, false, true, 1640),
            ("settings-connected-light", samples, false, false, 1640),
            ("settings-open-dark", samples, true, true, 2240),
            ("settings-open-light", samples, true, false, 2240),
        ] as [(String, [TransferRecord], Bool, Bool, Double)] {
            let droplet = DropPortalDroplet()
            droplet.showSample(address: "192.168.1.24", recent: recent, connected: name.contains("connected"))
            let view = NSHostingView(rootView:
                Form { DropPortalSettings(droplet: droplet, expanded: expanded) }
                    .formStyle(.grouped)
                    .frame(width: 640, height: height))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 640, height: height)
            view.layoutSubtreeIfNeeded()
            // Two passes: the effect's thumbnail arrives on the next turn of the run loop.
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = folder.appendingPathComponent("\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            urls.append(url)
        }
        return urls
    }
}
