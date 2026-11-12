//
//  DropPortalHarness.swift
//
//  Run with: droppykit run
//  Peek card pictures, no window: swift run DropPortalHarness --peek-shots <dir>
//  The right-edge send, half size: swift run DropPortalHarness --edge-shots <dir>
//  The right-edge drop, simulated end to end: swift run DropPortalHarness --edge-drop-test
//  The real drag watcher and zone on a strip ending at x, for a drag from
//  another process: swift run DropPortalHarness --edge-live <x> <seconds>
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
