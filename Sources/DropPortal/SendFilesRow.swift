//
//  SendFilesRow.swift
//  DropPortal
//
//  Settings › Send to phone: one drop area for files and folders, with
//  Choose files… inside it. Whatever is dropped or picked goes to the open
//  phone page through the same offer path as a drop on the shelf widget; the
//  last send's status replaces the area's caption for a few seconds.
//

import AppKit
import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

struct SendDropArea: View {
    @ObservedObject var droplet: DropPortalDroplet
    @State private var targeted = false

    private var caption: String {
        if targeted { return "Release to send to your phone" }
        return droplet.outgoingLine ?? "A folder is sent as a .zip."
    }

    var body: some View {
        DropletStackedRow(title: "Drop files or folders here", icon: "arrow.down.doc") {
            VStack(spacing: DroppySpacing.sm) {
                Image(systemName: targeted ? "iphone.and.arrow.forward" : "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(targeted ? Color.accentColor : AdaptiveColors.secondaryTextAuto)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose files…") { choose() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, DroppySpacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                           let file = URL(dataRepresentation: data, relativeTo: nil) { urls.append(file) }
                    }
                    droplet.send(files: urls)
                }
                return true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Drop files or folders here to send them to your phone")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Send to phone"
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        droplet.send(files: panel.urls)
    }
}
