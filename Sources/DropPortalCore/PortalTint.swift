//
//  PortalTint.swift
//  DropPortalCore
//
//  The colour of a crossing effect. Each effect remembers its own; the Mac
//  stores it, writes it into the page (`data-tint`) and sends it over the peek
//  socket with the effect, so the page recolours live. Rainbow walks the hue
//  wheel with the wall clock, the same formula on both sides, so a crossing
//  has nearly the same hue on the phone and the Mac.
//

import Foundation

/// An sRGB colour, components 0...1.
public struct PortalRGB: Hashable, Sendable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.unit(red)
        self.green = Self.unit(green)
        self.blue = Self.unit(blue)
    }

    public init(hue: Double, saturation: Double, value: Double) {
        let h = (hue - hue.rounded(.down)) * 6, s = Self.unit(saturation), v = Self.unit(value)
        let i = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: self.init(red: v, green: t, blue: p)
        case 1: self.init(red: q, green: v, blue: p)
        case 2: self.init(red: p, green: v, blue: t)
        case 3: self.init(red: p, green: q, blue: v)
        case 4: self.init(red: t, green: p, blue: v)
        default: self.init(red: v, green: p, blue: q)
        }
    }

    /// `#RRGGBB` or `RRGGBB`.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let n = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double(n >> 16 & 0xFF) / 255, green: Double(n >> 8 & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
    }

    /// `#RRGGBB`, upper case.
    public var hex: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    public var hsv: (hue: Double, saturation: Double, value: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue), d = maxC - minC
        var h = 0.0
        if d > 0 {
            if maxC == red { h = (green - blue) / d } else if maxC == green { h = 2 + (blue - red) / d } else { h = 4 + (red - green) / d }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : d / maxC, maxC)
    }

    /// Toward `other` by `amount` (0 keeps this colour).
    public func mixed(with other: PortalRGB, _ amount: Double) -> PortalRGB {
        PortalRGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                  blue: blue + (other.blue - blue) * amount)
    }

    public static let white = PortalRGB(red: 1, green: 1, blue: 1)

    private static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
}

/// What the user picked for an effect: a colour, or Rainbow.
public enum PortalTint: Hashable, Sendable {
    case color(PortalRGB)
    case rainbow

    public static let electricBlue = PortalTint.color(PortalRGB(hex: "#2F6BFF")!)
    public static let violet = PortalTint.color(PortalRGB(hex: "#8A2BFF")!)
    public static let magenta = PortalTint.color(PortalRGB(hex: "#FF2BD0")!)
    public static let sunset = PortalTint.color(PortalRGB(hex: "#FF5A1F")!)
    public static let lime = PortalTint.color(PortalRGB(hex: "#6BFF1F")!)
    public static let aqua = PortalTint.color(PortalRGB(hex: "#00D4FF")!)
    public static let gold = PortalTint.color(PortalRGB(hex: "#FFC21A")!)

    /// The settings' swatches, in order.
    public static let presets: [(name: String, tint: PortalTint)] = [
        ("Electric blue", electricBlue), ("Violet", violet), ("Magenta", magenta), ("Sunset orange", sunset),
        ("Lime", lime), ("Aqua", aqua), ("Gold", gold), ("Rainbow", .rainbow)
    ]

    /// Each effect's colour until the user picks another.
    public static func defaultTint(for effect: PortalEffect) -> PortalTint {
        switch effect {
        case .portal: electricBlue
        case .liquid: aqua
        case .wormhole: violet
        case .beam: magenta
        case .plane: sunset
        }
    }

    /// `#RRGGBB` or `rainbow`; anything else is nil (the effect's default).
    public init?(stored: String?) {
        guard let stored else { return nil }
        if stored.lowercased() == "rainbow" { self = .rainbow; return }
        guard let rgb = PortalRGB(hex: stored) else { return nil }
        self = .color(rgb)
    }

    public var stored: String {
        switch self {
        case .rainbow: "rainbow"
        case .color(let rgb): rgb.hex
        }
    }

    /// The preset's name, or nil for a custom colour.
    public var presetName: String? { Self.presets.first { $0.tint == self }?.name }

    /// Rainbow's hue steps and how long each lasts. The page uses the same numbers.
    public static let rainbowSteps = 12
    public static let rainbowStepSeconds = 1.5

    /// Rainbow's hue at `date`, one of `rainbowSteps` steps around the wheel.
    public static func rainbowHue(at date: Date) -> Double {
        let step = Int((date.timeIntervalSince1970 / rainbowStepSeconds).rounded(.down)) % rainbowSteps
        return Double(step) / Double(rainbowSteps)
    }

    /// The colour to draw with now.
    public func base(at date: Date = Date()) -> PortalRGB {
        switch self {
        case .color(let rgb): rgb
        case .rainbow: PortalRGB(hue: Self.rainbowHue(at: date), saturation: 1, value: 1)
        }
    }
}

/// The three colours an effect draws with, from its tint: a saturated glow,
/// a second tone a little round the hue wheel (a third of it for Rainbow),
/// and a core that is nearly white. Mirrored by `tones()` in the page.
public struct PortalTones: Hashable, Sendable {
    public let glow: PortalRGB, second: PortalRGB, core: PortalRGB

    public init(_ base: PortalRGB, rainbow: Bool = false) {
        let (h, s, v) = base.hsv
        // A grey or white pick stays pale; anything with colour is pushed to full saturation and brightness.
        let sat = s < 0.12 ? s : max(s, 0.82)
        let val = max(v, 0.92)
        glow = PortalRGB(hue: h, saturation: sat, value: val)
        second = PortalRGB(hue: h + (rainbow ? 1.0 / 3 : 0.075), saturation: sat, value: val)
        core = glow.mixed(with: .white, 0.82)
    }
}
