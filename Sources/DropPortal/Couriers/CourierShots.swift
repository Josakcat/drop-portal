//
//  CourierShots.swift
//  DropPortal
//
//  The Mac half of `--courier-shots <dir> [courier]` (the harness adds the
//  phone's): each courier on the real stage and card (PortalPreview's scene,
//  1440 × 900), light and dark, at four instants: `waiting` (the phone holds
//  the card at p 0.6), `arrival` (half way to L), `landing` (40 ms after L,
//  the hand-off) and `after` (half way through the exit).
//  `<courier>-mac-<instant>-<light|dark>.png`. Harness only.
//

import AppKit
import DropPortalCore

@MainActor
public enum CourierShots {
    /// The courier a name means: its effect's name (`cheek`) or its stem (`pip`); nil = all four.
    public static func couriers(named name: String?) -> [Courier] {
        guard let name = name?.lowercased() else { return Courier.allCases }
        return Courier.allCases.filter { $0.rawValue == name || $0.stem.lowercased() == name }
    }

    public static func writeMac(to folder: URL, only: [Courier] = Courier.allCases) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for courier in only {
            let effect = courier.effect, L = courier.landingMS
            let palette = PortalPalette(tint: .defaultTint(for: effect))
            let instants: [(String, Bool, Double?, Double?)] = [
                ("waiting", false, nil, nil),
                ("arrival", false, nil, L / 2000),
                ("landing", true, 0.04, nil),
                ("after", true, ((courier.exitMS + courier.goneMS) / 2 - L) / 1000, nil),
            ]
            for light in [true, false] {
                for (name, impact, impactAt, sentAt) in instants {
                    let size = CGSize(width: 1440, height: 900)
                    let root = PortalPreview.effectScene(effect, palette: palette, light: light, photo: PortalPreview.samplePhoto,
                                                         impact: impact, impactAt: impactAt, progress: 0.6, size: size, sentAt: sentAt)
                    let url = folder.appendingPathComponent("\(courier.rawValue)-mac-\(name)-\(light ? "light" : "dark").png")
                    try write(root, size: size, to: url)
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func write(_ root: CALayer, size: CGSize, to url: URL) throws {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        root.render(in: ctx)
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
