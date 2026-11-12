//
//  PortalSound.swift
//  DropPortal
//
//  A short, soft sound when a card lands, one per effect. Droppy's own cues
//  (`host.feedback`) are one drop sound for everything, so these are
//  synthesised here, in memory: original, no audio files. They play at the
//  system volume and stay quiet when "Play user interface sound effects" is off.
//

import AppKit
import DropPortalCore

@MainActor
enum PortalSound {
    private static var cache: [PortalEffect: NSSound] = [:]

    static func play(_ effect: PortalEffect) {
        guard uiSoundsEnabled else { return }
        let sound = cache[effect] ?? NSSound(data: wav(samples(effect)))
        guard let sound else { return }
        cache[effect] = sound
        sound.stop()
        sound.volume = 0.5
        sound.play()
    }

    /// System Settings › Sound › "Play user interface sound effects"; missing means on.
    private static var uiSoundsEnabled: Bool {
        let value = CFPreferencesCopyAppValue("com.apple.sound.uiaudio.enabled" as CFString, kCFPreferencesAnyApplication)
        return (value as? NSNumber)?.boolValue ?? true
    }

    static let rate = 44_100.0

    /// Mono samples in -1...1 for each effect's landing.
    static func samples(_ effect: PortalEffect) -> [Double] {
        switch effect {
        case .portal: // a bright two-partial chime that glides up a little
            return tone(0.42) { t in
                let f = 880 * (1 + 0.04 * min(t / 0.08, 1))
                return (sin(2 * .pi * f * t) + 0.5 * sin(2 * .pi * f * 1.5 * t)) / 1.5 * env(t, attack: 0.006, decay: 0.12)
            }
        case .liquid: // a round bloop: pitch rises fast, short tail
            return tone(0.26) { t in
                let phase = 2 * .pi * (320 * t + 2600 * t * t)  // 320 Hz rising
                return sin(phase) * env(t, attack: 0.004, decay: 0.06)
            }
        case .wormhole: // a low drop that sinks into the far side
            return tone(0.45) { t in
                let phase = 2 * .pi * (480 * t - 380 * t * t)  // 480 Hz falling
                return (sin(phase) + 0.3 * sin(2 * phase)) / 1.3 * env(t, attack: 0.01, decay: 0.14)
            }
        case .beam: // two quick blips, the second a fourth higher
            return tone(0.22) { t in
                let (f, local) = t < 0.07 ? (1175.0, t) : (1568.0, t - 0.07)
                return sin(2 * .pi * f * t) * env(local, attack: 0.003, decay: 0.035) * (t < 0.07 ? 0.7 : 1)
            }
        case .plane: // a soft breath of air, then a light tap as it lands
            var seed: UInt64 = 0x5b8cff
            var low = 0.0
            return tone(0.40) { t in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(Int64(bitPattern: seed >> 1) % 2000) / 1000 - 1
                low += 0.08 * (noise - low)  // one-pole low-pass: air, not hiss
                let whoosh = low * 2.2 * sin(.pi * min(t / 0.3, 1))
                let tap = t > 0.28 ? sin(2 * .pi * 660 * t) * env(t - 0.28, attack: 0.003, decay: 0.04) : 0
                return 0.8 * whoosh + 0.6 * tap
            }
        }
    }

    private static func tone(_ seconds: Double, _ f: (Double) -> Double) -> [Double] {
        (0..<Int(seconds * rate)).map { f(Double($0) / rate) }
    }

    /// A quick linear attack and an exponential decay with time constant `decay`.
    private static func env(_ t: Double, attack: Double, decay: Double) -> Double {
        t < 0 ? 0 : t < attack ? t / attack : exp(-(t - attack) / decay)
    }

    /// 16-bit mono PCM WAV, with a 5 ms fade out so nothing clicks.
    static func wav(_ samples: [Double]) -> Data {
        let fade = Int(0.005 * rate)
        var pcm = Data(capacity: samples.count * 2)
        for (i, s) in samples.enumerated() {
            let edge = min(1, Double(samples.count - i) / Double(fade))
            var v = Int16(max(-1, min(1, s * edge)) * 0.8 * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
