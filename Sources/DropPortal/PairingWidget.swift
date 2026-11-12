//
//  PairingWidget.swift
//  DropPortal
//
//  Drop Portal in the notch: a shelf widget. Until a phone page is open it is
//  the pairing QR code, so opening the shelf is enough to scan it; while one is
//  open the code folds into a button and the widget shows the phone's status
//  and the newest file it sent (click opens, drag takes the file out). It
//  follows the droplet's address and token, so a new Wi-Fi or Reset pairing
//  redraws the code at once. Nothing to choose here: settings stay in Settings.
//

import DroppyKit
import DropPortalCore
import SwiftUI
import UniformTypeIdentifiers

extension DropPortalDroplet: ShelfWidgetCompositionProviding {
    static let pairingWidgetID: ShelfWidgetID = "pairing-qr"

    /// Tune here: the code's side with its white border, in points (scannable from a phone at arm's length).
    enum PairingLook {
        static let tile: CGFloat = 156
        /// The newest file's picture alone and in a row.
        static let thumb: CGFloat = 44
        static let splitThumb: CGFloat = 56
    }

    /// The code is the widget until a phone page is open, or while it was tapped open for another phone.
    var widgetShowsQR: Bool { !phoneConnected || widgetShowsCode }

    /// Content heights alone and in a row. Connected: a status row and the newest file, much shorter than the code.
    var widgetHeights: (single: CGFloat, split: CGFloat) {
        let tile = PairingLook.tile
        let item = latestReceived != nil
        return widgetShowsQR ? (tile, tile + 66) : (item ? 92 : 72, item ? 156 : 92)
    }

    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        let (single, split) = widgetHeights
        return [
            ShelfWidgetDescriptor(
                id: Self.pairingWidgetID,
                title: "Drop Portal",
                systemImage: "drop.circle",
                layoutTraits: ShelfWidgetLayoutTraits(
                    single: ShelfWidgetModeSize(width: 360, contentHeight: single),
                    split: ShelfWidgetModeSize(width: 190, contentHeight: split)
                ),
                searchKeywords: ["qr", "iphone", "phone", "pair", "scan", "connect"]
            )
        ]
    }

    public func makeWidgetContent(_ id: ShelfWidgetID, layout: ShelfWidgetLayout) -> AnyView {
        AnyView(PairingWidget(droplet: self))
    }
}

/// Alone: the code with the lines beside it, or the status row over the newest file.
/// In a row: the same, stacked. Files dropped on it go to the phone.
struct PairingWidget: View {
    @ObservedObject var droplet: DropPortalDroplet
    @State private var targeted = false

    var body: some View {
        DropletWidgetComposition {
            if droplet.widgetShowsQR {
                HStack(alignment: .top, spacing: DroppySpacing.md) {
                    code
                    VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                        status
                        words(compact: false)
                        Spacer(minLength: 0)
                        if droplet.phoneConnected {
                            Button("Hide code") { droplet.widgetShowsCode = false }
                        } else if let item = droplet.latestReceived {
                            LatestItem(droplet: droplet, item: item, side: 32, stacked: false)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                    HStack(spacing: DroppySpacing.sm) {
                        status
                        Spacer(minLength: DroppySpacing.sm)
                        codeButton
                        clipboardButton
                    }
                    newest(stacked: false)
                    Spacer(minLength: 0)
                }
            }
        } split: {
            VStack(spacing: DroppySpacing.xs) {
                if droplet.widgetShowsQR {
                    code
                    if droplet.phoneConnected {
                        Text("Scan to add another phone")
                            .droppyWidgetText(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        codeButton
                    } else {
                        status
                        words(compact: true)
                    }
                } else {
                    status
                    newest(stacked: true)
                    Spacer(minLength: 0)
                    HStack(spacing: DroppySpacing.sm) {
                        codeButton
                        clipboardButton
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let file = URL(dataRepresentation: url, relativeTo: nil) { urls.append(file) }
                }
                droplet.send(files: urls)
            }
            return true
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var code: some View {
        let side = DropPortalDroplet.PairingLook.tile
        if let url = droplet.pageURL, let qr = QRCode.image(for: url, quietZone: true) {
            // The white quiet zone is part of the picture: a scanner needs it on the shelf's black.
            Image(nsImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .accessibilityLabel("QR code to pair your phone")
        } else {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                .frame(width: side, height: side)
        }
    }

    /// Green dot and "Phone connected" while a page is open, grey and "Not connected"
    /// otherwise; while something is being sent or dropped, that line instead.
    private var status: some View {
        let connected = droplet.phoneConnected && droplet.problem == nil
        let line = targeted ? "Drop to send to your phone"
            : droplet.outgoingLine ?? (connected ? "Phone connected" : "Not connected")
        return HStack(spacing: DroppySpacing.xs) {
            Circle()
                .fill(connected ? Color.green : AdaptiveColors.secondaryTextAuto.opacity(0.6))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(line)
                .droppyWidgetText(.caption)
                .foregroundStyle(connected ? AdaptiveColors.primaryTextAuto : AdaptiveColors.secondaryTextAuto)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    /// Shows the full code again, for a second phone.
    private var codeButton: some View {
        Button { droplet.widgetShowsCode.toggle() } label: { Image(systemName: "qrcode") }
            .help(droplet.widgetShowsCode ? "Hide the code" : "Show the code to add another phone")
            .accessibilityLabel(droplet.widgetShowsCode ? "Hide QR code" : "Show QR code")
    }

    private var clipboardButton: some View {
        Button { droplet.sendClipboard() } label: { Image(systemName: "doc.on.clipboard") }
            .help("Send clipboard to phone")
            .accessibilityLabel("Send clipboard to phone")
    }

    /// The newest file from the phone, or one line on what to do while there is none.
    @ViewBuilder
    private func newest(stacked: Bool) -> some View {
        if let item = droplet.latestReceived {
            LatestItem(droplet: droplet, item: item,
                       side: stacked ? DropPortalDroplet.PairingLook.splitThumb : DropPortalDroplet.PairingLook.thumb,
                       stacked: stacked)
        } else {
            Text("Flick a photo off your phone's left edge.")
                .droppyWidgetText(.caption)
                .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                .multilineTextAlignment(stacked ? .center : .leading)
                .lineLimit(2)
        }
    }

    /// The scan line, and the problem under it only while the phone cannot reach this Mac.
    /// In a row there is room for one of them: the problem wins.
    @ViewBuilder
    private func words(compact: Bool) -> some View {
        let problem = droplet.problem
        VStack(alignment: compact ? .center : .leading, spacing: DroppySpacing.xs) {
            if !(compact && problem != nil) {
                // Until a phone has connected, the line also says what comes after the scan.
                Text(droplet.phoneConnected ? "Scan to add another phone"
                     : compact && droplet.showsGuide ? "Scan, then flick left" : "Scan with your phone camera")
                    .droppyWidgetText(compact ? .caption : .title)
                    .lineLimit(2)
                if !compact && problem == nil && droplet.showsGuide {
                    Text("Then flick a photo off the left edge.")
                        .droppyWidgetText(.caption)
                        .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                        .lineLimit(2)
                }
            }
            if let problem {
                Text(problem)
                    .droppyWidgetText(.caption)
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                    .lineLimit(compact ? 2 : 3)
            }
        }
        .multilineTextAlignment(compact ? .center : .leading)
    }
}

/// The newest file from the phone: its picture or icon, its name and how long ago.
/// A click opens it (an app or script is revealed instead); dragging it hands the file out.
private struct LatestItem: View {
    @ObservedObject var droplet: DropPortalDroplet
    let item: TransferRecord
    let side: CGFloat
    /// In a row: picture over the words, centred.
    let stacked: Bool
    @ObservedObject private var thumbnails = RecentThumbnails.shared

    var body: some View {
        Button { droplet.recentAction(.open, id: item.id) } label: {
            let picture = Image(nsImage: thumbnails.image(for: item))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous))
            if stacked {
                VStack(spacing: DroppySpacing.xs) {
                    picture
                    words(alignment: .center)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: DroppySpacing.sm) {
                    picture
                    words(alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
        // The file is the widget's content, not a control: no wash behind it.
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help("Open, or drag it out")
        .accessibilityLabel("Open \(item.name), received from your phone")
    }

    private func words(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(item.name)
                .droppyWidgetText(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            DroppyWidgetTimeline(every: 30) { now in
                Text(TransferRecord.shortAge(of: item.date, now: now))
                    .droppyWidgetText(.caption)
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Harness

/// Pictures of the widget for the harness (`--widget-shots <dir>`): not connected,
/// connected without and with a newest file, the code shown again, alone and in a row,
/// light and dark, at half size like the other shots.
public enum WidgetPreview {
    @MainActor
    public static func writeShots(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = TransferRecord(name: "IMG_4821.HEIC", path: "/sample/IMG_4821.HEIC", size: 3_481_000,
                                   direction: .fromPhone, date: Date().addingTimeInterval(-130))
        RecentThumbnails.shared.samples[photo.path] = samplePicture()
        var urls: [URL] = []
        let states: [(String, Bool, Bool, [TransferRecord])] = [
            ("not-connected", false, false, []),
            ("not-connected-item", false, false, [photo]),
            ("connected", true, false, []),
            ("connected-item", true, false, [photo]),
            ("connected-code", true, true, [photo]),
        ]
        for (name, connected, showsCode, recent) in states {
            for split in [false, true] {
                for dark in [true, false] {
                    let droplet = DropPortalDroplet()
                    droplet.showSample(address: "192.168.1.24", recent: recent, connected: connected)
                    droplet.widgetShowsCode = showsCode
                    let heights = droplet.widgetHeights
                    // Under a notch alone the host insets 8 on every edge; in a row, none.
                    let content = split ? CGSize(width: 190, height: heights.split)
                                        : CGSize(width: 360 - 16, height: heights.single)
                    let layout = ShelfWidgetLayout(
                        mode: split ? .split(.leading) : .single,
                        density: split ? .compact : .regular, contentSize: content, surface: .builtInNotch,
                        isInteractive: true, isPreview: true, isVisible: true,
                        usesAdaptiveForegrounds: !dark, foreground: dark ? .white : .black)
                    let pad: CGFloat = 8
                    let root = PairingWidget(droplet: droplet)
                        .droppyWidgetMount(layout)
                        .frame(width: content.width, height: content.height)
                        .padding(pad)
                        .background(dark ? Color.black : Color(white: 0.93))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let view = NSHostingView(rootView: root)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    view.frame = NSRect(x: 0, y: 0, width: content.width + pad * 2, height: content.height + pad * 2)
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let url = folder.appendingPathComponent("widget-\(name)-\(split ? "row" : "solo")-\(dark ? "dark" : "light").png")
                    try rep.representation(using: .png, properties: [:])?.write(to: url)
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func samplePicture() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(colors: [NSColor.systemOrange, NSColor.systemPink, NSColor.systemPurple])?.draw(in: rect, angle: 60)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 38, y: 38, width: 14, height: 14)).fill()
            return true
        }
    }
}
