//
//  ThrowShots.swift
//  DropPortal
//
//  `--throw-shots <dir>`: the Mac card's path after a flick, for a few
//  releases, on a dark 1440 × 900 screen. One dot per 120 Hz frame (dots far
//  apart = fast), the card's outline where it starts and lands, and each
//  path's flight time. Harness only; nothing here runs in Droppy.
//

import AppKit
import DropPortalCore

@MainActor
public enum ThrowShots {
    public static func write(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let releases: [(String, ThrowFlight.Vector, Double)] = [
            ("fast", .init(-3600, 0), 0.5), ("medium", .init(-1700, -220), 0.42), ("slow", .init(-450, 0), 0.5),
            ("up", .init(-1500, -1400), 0.62), ("down", .init(-1400, 1100), 0.3), ("hard", .init(-9000, 300), 0.5),
        ]
        var urls: [URL] = []
        for effect in PortalEffect.allCases {
            let url = folder.appendingPathComponent("throw-\(effect.rawValue).png")
            try draw(effect, releases: releases, to: url)
            urls.append(url)
        }
        return urls
    }

    private static func draw(_ effect: PortalEffect, releases: [(String, ThrowFlight.Vector, Double)], to url: URL) throws {
        let size = CGSize(width: 1440, height: 900), card = LandingPresenter.fileCardSize
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // The same spot as the presenter's `landingRect` and the peek shots.
        let land = CGPoint(x: size.width * 0.64 - card.width / 2, y: size.height / 2 + size.height * 0.08 - card.height / 2)
        let offX = size.width + 12, inset = size.height * 0.06
        let range = Double(inset)...Double(size.height - inset - card.height)
        let colors: [NSColor] = [.systemPink, .systemOrange, .systemTeal, .systemGreen, .systemPurple, .systemYellow]
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(origin: land, size: card))
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        func label(_ text: String, _ at: CGPoint, _ color: NSColor) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            ctx.textPosition = at
            CTLineDraw(line, ctx)
        }
        label("\(effect.title): base L \(String(format: "%.2f", effect.flight)) s", CGPoint(x: 40, y: size.height - 50), .white)
        for (i, (name, v, exitY)) in releases.enumerated() {
            // Released at p = 0.5, at the height the phone gave, half way to the landing height (as `follow(phoneY:)`).
            let entry = ThrowFlight.entryY(exitY: exitY, in: (range.lowerBound + card.height / 2)...(range.upperBound + card.height / 2)) - card.height / 2
            let from = ThrowFlight.Vector(Double(offX - (offX - land.x) * 0.5), entry + (Double(land.y) - entry) * 0.25)
            let path = ThrowFlight(from: from, to: .init(Double(land.x), Double(land.y)), release: v, base: effect.flight,
                                   scale: Double(size.width / 1280), yRange: range)
            let color = colors[i % colors.count]
            ctx.setFillColor(color.cgColor)
            var t = 0.0
            while t <= path.duration + 1e-9 {
                let p = path.position(at: t)
                ctx.fillEllipse(in: CGRect(x: p.x + card.width / 2 - 3, y: p.y + card.height / 2 - 3, width: 6, height: 6))
                t += 1.0 / 120
            }
            ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor)
            ctx.stroke(CGRect(x: from.x, y: from.y, width: card.width, height: card.height))
            label("\(name): \(Int(abs(v.x))) px/s → \(String(format: "%.2f", path.duration)) s", CGPoint(x: 40, y: size.height - 90 - CGFloat(i) * 28), color)
        }
        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
