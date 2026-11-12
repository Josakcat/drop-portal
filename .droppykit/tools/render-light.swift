// Texture-only visual fallback when NSApplication cannot connect to the window server.
// Compile alongside the real PortalLightTexture.swift and DropPortalCore module.
import AppKit
import DropPortalCore
import ImageIO
import UniformTypeIdentifiers

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255)/255, green: CGFloat(hex >> 8 & 255)/255,
            blue: CGFloat(hex & 255)/255, alpha: alpha)
}

@main struct RenderLight {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for effect in PortalEffect.allCases {
            let size = CGSize(width: 1440, height: 900), landing = CGPoint(x: 921.6, y: 486)
            let c = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(srgb(0x0B0B0F).cgColor); c.fill(CGRect(origin: .zero, size: size))
            let texture = PortalLightTexture.image(effect: effect, size: size, landing: landing, scale: 2)!
            c.draw(texture, in: CGRect(origin: .zero, size: size))
            // An opaque card proxy checks the actual occlusion of rear light forms.
            let card = CGRect(x: landing.x-120, y: landing.y-134, width: 240, height: 268)
            c.saveGState()
            c.addPath(CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil)); c.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [srgb(0x1C3558).cgColor, srgb(0x559FCE).cgColor] as CFArray, locations: [0,1])!
            c.drawLinearGradient(gradient, start: card.origin, end: CGPoint(x: card.minX,y: card.maxY), options: [])
            for i in 0..<7 {
                let p = CGMutablePath(), x = card.minX+CGFloat(i)*44
                p.addLines(between: [CGPoint(x:x-40,y:card.midY), CGPoint(x:x+24,y:card.maxY-40-CGFloat(i%3)*20), CGPoint(x:x+90,y:card.midY)])
                p.closeSubpath(); c.addPath(p); c.setFillColor(srgb(i%2 == 0 ? 0xDBEAF3 : 0x365579).cgColor); c.fillPath()
            }
            c.setFillColor(srgb(0x1A1A22).cgColor); c.fill(CGRect(x:card.minX,y:card.minY,width:card.width,height:36))
            c.restoreGState()
            let url = folder.appendingPathComponent("texture-\(effect.rawValue)-impact.png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, c.makeImage()!, nil); CGImageDestinationFinalize(dest)
            print(url.path)
        }
    }
}
