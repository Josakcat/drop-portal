//
//  PortalSound.swift
//  DropPortal
//
//  A short, soft sound when a card lands, one per effect. Droppy's own cues
//  (`host.feedback`) are one drop sound for everything, so these are
//  synthesised here, in memory: original, no audio files. They play at the
//  system volume and stay quiet when "Play user interface sound effects" is off.
//
//  Starting a sound waits for the output device, and AirPods, AirPlay or a
//  sleeping display can hold that for seconds, so nothing here touches audio
//  on the main thread: `play` decides on main (the switch, the effect, the
//  time) and hands the rest to one serial queue of its own, which builds the
//  sample data, keeps one `AVAudioPlayer` per effect and plays it. A sound that
//  waited on that queue for more than a second is dropped: it would land after
//  the card did. `stopAll()` (from `deactivate()`) stops and forgets every
//  player and drops whatever is still queued.
//

import AppKit
import AVFoundation
import DropPortalCore

enum PortalSound {
    /// Every player and every start runs here, never on main.
    private static let queue = DispatchQueue(label: "drop-portal.sound", qos: .userInitiated)
    /// Queue-only state.
    nonisolated(unsafe) private static var players: [PortalEffect: AVAudioPlayer] = [:]
    /// Raised by `stopAll()` at once (not on the queue), so a play asked for before it is dropped.
    nonisolated(unsafe) private static var generation = 0
    private static let lock = NSLock()
    private static var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
    /// A sound that could not start within this long after the landing is not played.
    static let maxWait: TimeInterval = 1.0

    /// Called on main when a card lands (or a settings Preview lands).
    @MainActor
    static func play(_ effect: PortalEffect) {
        guard uiSoundsEnabled else { return }
        let asked = DispatchTime.now()
        let ticket = currentGeneration
        queue.async {
            guard ticket == currentGeneration else { return }
            let waited = Double(DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1e9
            guard waited <= maxWait else { return }
            let player: AVAudioPlayer
            if let cached = players[effect] {
                player = cached
            } else {
                guard let made = try? AVAudioPlayer(data: wav(samples(effect))) else { return }
                made.volume = 0.5
                made.prepareToPlay()
                players[effect] = made
                player = made
            }
            // Building the player can take a moment: check the clock and stopAll() again.
            let total = Double(DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds) / 1e9
            guard total <= maxWait, ticket == currentGeneration else { return }
            player.stop()
            player.currentTime = 0
            player.play()
        }
    }

    /// Stops every sound and forgets the players; anything still queued is dropped.
    static func stopAll() {
        lock.lock(); generation &+= 1; lock.unlock()
        queue.async {
            players.values.forEach { $0.stop() }
            players = [:]
        }
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
        case .stardust: // a soft shimmer of high partials settling into one chime
            return tone(0.45) { t in
                let shimmer = (sin(2 * .pi * 2093 * t) + 0.6 * sin(2 * .pi * 2637 * t + 1) + 0.4 * sin(2 * .pi * 3136 * t + 2)) / 2
                let twinkle = 0.5 + 0.5 * sin(2 * .pi * 18 * t)
                return 0.35 * shimmer * twinkle * env(t, attack: 0.02, decay: 0.12) + 0.5 * sin(2 * .pi * 1568 * t) * env(t - 0.05, attack: 0.004, decay: 0.12)
            }
        case .lightning: // a short dry crack and a low soft rumble, no boom
            var seed: UInt64 = 0x9cc8ff
            var low = 0.0
            return tone(0.40) { t in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(Int64(bitPattern: seed >> 1) % 2000) / 1000 - 1
                low += 0.03 * (noise - low)
                let crack = noise * env(t, attack: 0.001, decay: 0.012)
                return 0.55 * crack + 1.6 * low * env(t - 0.01, attack: 0.03, decay: 0.12)
            }
        // The couriers (the spec's sounds, all under 300 ms).
        case .cheek: // a squeak near 1.8 kHz for 80 ms, then a soft cork pop
            return tone(0.26) { t in
                let squeak = t < 0.09 ? sin(2 * .pi * (1750 * t + 900 * t * t)) * env(t, attack: 0.006, decay: 0.03) : 0
                let pop = t > 0.1 ? sin(2 * .pi * (520 * (t - 0.1) - 900 * (t - 0.1) * (t - 0.1))) * env(t - 0.1, attack: 0.002, decay: 0.03) : 0
                return 0.6 * squeak + 0.9 * pop
            }
        case .pounce: // a soft "mrrp", rising 400 → 700 Hz over 120 ms, then a pop
            return tone(0.27) { t in
                let f = 400 * t + 1250 * t * t, trill = 1 + 0.25 * sin(2 * .pi * 34 * t)
                let mrrp = t < 0.13 ? (sin(2 * .pi * f) + 0.35 * sin(4 * .pi * f)) / 1.35 * trill * env(t, attack: 0.015, decay: 0.05) : 0
                let pop = t > 0.15 ? sin(2 * .pi * 600 * (t - 0.15)) * env(t - 0.15, attack: 0.002, decay: 0.025) : 0
                return 0.6 * mrrp + 0.8 * pop
            }
        case .mole: // three soft dig ticks, then a little boing
            return tone(0.30) { t in
                var ticks = 0.0
                for k in 0..<3 { let a = t - Double(k) * 0.035; if a > 0 { ticks += sin(2 * .pi * 900 * a) * env(a, attack: 0.001, decay: 0.006) } }
                let b = t - 0.12
                let boing = b > 0 ? sin(2 * .pi * (180 * b + 260 * sin(2 * .pi * 9 * b) / (2 * .pi * 9))) * env(b, attack: 0.004, decay: 0.07) : 0
                return 0.5 * ticks + 0.9 * boing
            }
        case .ducks: // a quack chord: three rising quacks, 40 ms apart, 90 ms each
            return tone(0.28) { t in
                var sum = 0.0
                for (k, f) in [520.0, 660, 780].enumerated() {
                    let a = t - Double(k) * 0.04
                    guard a > 0, a < 0.1 else { continue }
                    // Nasal: a few odd harmonics, a quick drop in pitch.
                    let ph = 2 * .pi * (f * a - 400 * a * a)
                    sum += (sin(ph) + 0.5 * sin(3 * ph) + 0.25 * sin(5 * ph)) / 1.75 * env(a, attack: 0.008, decay: 0.03)
                }
                return 0.55 * sum
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
