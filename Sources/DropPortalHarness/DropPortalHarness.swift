//
//  DropPortalHarness.swift
//
//  Run with: droppykit run
//  Peek card pictures, no window: swift run DropPortalHarness --peek-shots <dir>
//  The Mac card's thrown paths: swift run DropPortalHarness --throw-shots <dir>
//  The couriers, Mac and phone, light and dark: --courier-shots <dir> [courier] (debug builds)
//  The right-edge send, half size: swift run DropPortalHarness --edge-shots <dir>
//  The right-edge drop, simulated end to end: swift run DropPortalHarness --edge-drop-test
//  The real drag watcher and zone on a strip ending at x, for a drag from
//  another process: swift run DropPortalHarness --edge-live <x> <seconds>
//  The GPU effects beside the Core Animation path: --metal-shots <dir> [--effect <name>];
//  their frame costs: --metal-bench [--ca-only] (debug builds)
//
//  Not named main.swift on purpose: Swift treats that name as top-level code,
//  which cannot coexist with @main.
//

import AppKit
import DroppyKit
import DroppyKitHarness
import DropPortal
import Foundation

@main
struct DropPortalHarness: DropletHarnessApp {
    static func makeDroplet() -> any Droplet { DropPortalDroplet() }

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        #if DEBUG
        // The promo video's footage (PromoCapture.swift).
        if args.contains(where: { $0.hasPrefix("--promo-") }) { PromoCapture.run(args) }
        // The phone page mid-drag per effect, CSS and WebGL (PhoneShots.swift).
        if args.contains("--phone-shots") { PhoneShots.run(args) }
        // The couriers on the Mac and the phone, light and dark (CourierShots.swift).
        if args.contains("--courier-shots") { CourierPhoneShots.run(args) }
        #endif
        #if DEBUG
        // The GPU effects (MetalProbe.swift): stills beside the Core Animation path, and frame costs.
        if let flag = args.firstIndex(of: "--metal-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                let only = args.firstIndex(of: "--effect").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                let urls = try MetalProbe.writeShots(to: URL(fileURLWithPath: args[flag + 1]), only: only)
                print("\(urls.count) shots in \(args[flag + 1])")
                exit(0)
            } catch {
                print("metal shots failed: \(error)")
                exit(1)
            }
        }
        if args.contains("--metal-bench") {
            _ = NSApplication.shared
            MetalProbe.bench(caOnly: args.contains("--ca-only")).forEach { print($0) }
            exit(0)
        }
        #endif
        if let flag = args.firstIndex(of: "--peek-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                for url in try PortalPreview.writePeekShots(to: URL(fileURLWithPath: args[flag + 1])) {
                    print(url.path)
                }
                exit(0)
            } catch {
                print("peek shots failed: \(error)")
                exit(1)
            }
        }
        #if DEBUG
        // The landed card's shadow and lean, and the frame clock on this Mac's screens (PortalFeel.swift).
        if let flag = args.firstIndex(of: "--feel-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                try FeelProbe.writeShots(to: URL(fileURLWithPath: args[flag + 1])).forEach { print($0.path) }
                exit(0)
            } catch {
                print("feel shots failed: \(error)")
                exit(1)
            }
        }
        if args.contains("--feel-bench") {
            NSApplication.shared.setActivationPolicy(.accessory)
            FeelProbe.bench().forEach { print($0) }
            exit(0)
        }
        #endif
        if let flag = args.firstIndex(of: "--history-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                for url in try RecentPreview.writeShots(to: URL(fileURLWithPath: args[flag + 1])) {
                    print(url.path)
                }
                exit(0)
            } catch {
                print("history shots failed: \(error)")
                exit(1)
            }
        }
        if let flag = args.firstIndex(of: "--widget-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                for url in try WidgetPreview.writeShots(to: URL(fileURLWithPath: args[flag + 1])) {
                    print(url.path)
                }
                exit(0)
            } catch {
                print("widget shots failed: \(error)")
                exit(1)
            }
        }
        if let flag = args.firstIndex(of: "--settings-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                for url in try SettingsPreview.writeShots(to: URL(fileURLWithPath: args[flag + 1])) {
                    print(url.path)
                }
                exit(0)
            } catch {
                print("settings shots failed: \(error)")
                exit(1)
            }
        }
        if let flag = args.firstIndex(of: "--throw-shots"), args.indices.contains(flag + 1) {
            do {
                for url in try ThrowShots.write(to: URL(fileURLWithPath: args[flag + 1])) { print(url.path) }
                exit(0)
            } catch {
                print("throw shots failed: \(error)")
                exit(1)
            }
        }
        if let flag = args.firstIndex(of: "--edge-shots"), args.indices.contains(flag + 1) {
            _ = NSApplication.shared
            do {
                for url in try PortalPreview.writeEdgeShots(to: URL(fileURLWithPath: args[flag + 1])) {
                    print(url.path)
                }
                exit(0)
            } catch {
                print("edge shots failed: \(error)")
                exit(1)
            }
        }
        if args.contains("--edge-drop-test") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let report = EdgeDropProbe.simulate()
            report.lines.forEach { print($0) }
            print(report.passed ? "edge drop test passed" : "edge drop test FAILED")
            exit(report.passed ? 0 : 1)
        }
        if let flag = args.firstIndex(of: "--edge-live"), args.indices.contains(flag + 2),
           let x = Double(args[flag + 1]), let seconds = Double(args[flag + 2]) {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let dropped = EdgeDropProbe.live(edgeX: CGFloat(x), seconds: seconds)
            print("edge live: \(dropped) file(s) dropped")
            exit(dropped > 0 ? 0 : 1)
        }
        DropletHarness.run(makeDroplet(), manifestURL: manifestURL)
    }
}
