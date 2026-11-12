//
//  RecentSection.swift
//  DropPortal
//
//  Settings › Recent: the last transfers both ways, newest first. Click a row
//  to open it; Reveal in Finder and Send again on each row; Clear history in
//  the header. Every click goes through `recentAction`, so in Droppy's
//  settings process the main process acts. Entries whose file is gone are not
//  shown (the main process drops them from the store).
//

import AppKit
import DroppyKit
import DropPortalCore
import QuickLookThumbnailing
import SwiftUI

struct RecentSection: View {
    @ObservedObject var droplet: DropPortalDroplet
    @State private var showAll = false

    /// Rows shown before "Show all".
    static let folded = 5

    var body: some View {
        let items = droplet.recent.filter { TransferHistory.exists($0.path) }
        DropletSettingsSection {
            HStack {
                settingsSectionHeader("Recent")
                Spacer()
                if !items.isEmpty {
                    Button("Clear history") { droplet.recentAction(.clear) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
        } content: {
            DropletSettingsCard {
                RecentList(items: items, showAll: $showAll) { action, item in
                    droplet.recentAction(action, id: item.id)
                }
            }
        }
    }
}

/// The rows themselves, apart from the droplet so the harness can draw them with sample entries.
struct RecentList: View {
    let items: [TransferRecord]
    @Binding var showAll: Bool
    var thumbnails: RecentThumbnails = .shared
    let act: (DropPortalDroplet.RecentAction, TransferRecord) -> Void

    var body: some View {
        if items.isEmpty {
            Text("Files you send either way show up here.")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                ForEach(showAll ? items : Array(items.prefix(RecentSection.folded))) { item in
                    RecentRow(item: item, thumbnails: thumbnails) { act($0, item) }
                }
                if items.count > RecentSection.folded {
                    Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
        }
    }
}

struct RecentRow: View {
    let item: TransferRecord
    @ObservedObject var thumbnails: RecentThumbnails
    let act: (DropPortalDroplet.RecentAction) -> Void

    private static let sizes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let times: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// "From your phone · 2.1 MB · 5 min. ago"
    static func detail(_ item: TransferRecord, now: Date = Date()) -> String {
        let way = item.direction == .fromPhone ? "From your phone" : "To your phone"
        let when = now.timeIntervalSince(item.date) < 60 ? "just now" : times.localizedString(for: item.date, relativeTo: now)
        return "\(way) · \(sizes.string(fromByteCount: item.size)) · \(when)"
    }

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Button { act(.open) } label: {
                HStack(spacing: DroppySpacing.sm) {
                    Image(nsImage: thumbnails.image(for: item))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.detail(item))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open")
            .accessibilityLabel("Open \(item.name)")
            Button { act(.reveal) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(item.name) in Finder")
            Button { act(.send) } label: { Image(systemName: "iphone.and.arrow.forward") }
                .buttonStyle(.borderless)
                .help("Send again")
                .accessibilityLabel("Send \(item.name) to your phone again")
        }
    }
}

/// Quick Look thumbnails for Recent, made off the main thread and kept by path;
/// the file's icon until one is ready (and for anything Quick Look cannot draw).
@MainActor
final class RecentThumbnails: ObservableObject {
    static let shared = RecentThumbnails()

    private var cache: [String: NSImage] = [:]
    private var asked: Set<String> = []
    /// Fixed pictures by path, for the harness's shots.
    var samples: [String: NSImage] = [:]

    func image(for item: TransferRecord) -> NSImage {
        if let sample = samples[item.path] { return sample }
        if let hit = cache[item.path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: item.path)
        guard item.kind == "image" || item.kind == "video", !asked.contains(item.path) else { return icon }
        asked.insert(item.path)
        let path = item.path
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.cache.count > 60 { self.cache.removeAll() }
                    self.cache[path] = NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
                    self.objectWillChange.send()
                }
            }
        }
        return icon
    }
}

/// Pictures of Recent for the harness (`--history-shots <dir>`): sample rows,
/// folded and empty, dark and light, without a server or a droplet.
public enum RecentPreview {
    @MainActor
    public static func writeShots(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let tmp = FileManager.default.temporaryDirectory.path
        func item(_ name: String, _ size: Int64, _ way: TransferRecord.Direction, _ ago: TimeInterval, path: String? = nil) -> TransferRecord {
            TransferRecord(name: name, path: path ?? "/sample/\(name)", size: size, direction: way, date: now.addingTimeInterval(-ago))
        }
        let items = [
            item("IMG_4821.HEIC", 3_481_000, .fromPhone, 20),
            item("Trip photos", 48_200_000, .toPhone, 260, path: tmp),
            item("Quarterly report final v3.pdf", 812_000, .toPhone, 3_700),
            item("IMG_4799.MOV", 61_300_000, .fromPhone, 7_400),
            item("Boarding pass.pkpass", 92_000, .fromPhone, 90_000),
            item("Screenshot 2026-11-10 at 09.12.44.png", 1_240_000, .toPhone, 180_000),
            item("Notes.txt", 2_100, .fromPhone, 200_000),
        ]
        let thumbs = RecentThumbnails()
        thumbs.samples[items[0].path] = samplePicture(hue: 0.58)
        thumbs.samples[items[3].path] = samplePicture(hue: 0.08)
        thumbs.samples[items[5].path] = samplePicture(hue: 0.75)
        for (index, kind) in [(2, "pdf"), (4, "pkpass"), (6, "txt")] {
            thumbs.samples[items[index].path] = NSWorkspace.shared.icon(for: .init(filenameExtension: kind) ?? .data)
        }
        var urls: [URL] = []
        for (name, list, all, dark) in [("recent-dark", items, false, true), ("recent-light", items, false, false),
                                        ("recent-all-dark", items, true, true), ("recent-empty-dark", [], false, true)]
            as [(String, [TransferRecord], Bool, Bool)] {
            let view = NSHostingView(rootView: SectionPreview(items: list, showAll: all, thumbnails: thumbs))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = folder.appendingPathComponent("\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// A soft two-tone square standing in for a photo.
    @MainActor
    private static func samplePicture(hue: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                       ending: NSColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.45, alpha: 1))?.draw(in: rect, angle: -60)
            NSColor(white: 1, alpha: 0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: 40, y: 40, width: 12, height: 12)).fill()
            return true
        }
    }

    /// The section as the settings page draws it: header with Clear history, then the card.
    private struct SectionPreview: View {
        let items: [TransferRecord]
        @State var showAll: Bool
        let thumbnails: RecentThumbnails

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !items.isEmpty { Button("Clear history") {}.buttonStyle(.borderless).font(.system(size: 11)) }
                }
                .padding(.horizontal, 4)
                RecentList(items: items, showAll: $showAll, thumbnails: thumbnails) { _, _ in }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(20)
            .frame(width: 560)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
