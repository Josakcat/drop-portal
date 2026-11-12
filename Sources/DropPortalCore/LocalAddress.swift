//
//  LocalAddress.swift
//  DropPortalCore
//

import Darwin
import Foundation
import SystemConfiguration

public enum LocalAddress {
    /// This Mac's IPv4 address on the local network, preferring Wi-Fi/Ethernet
    /// (en*) over anything else. `nil` when offline.
    public static func ipv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: (name: String, address: String)?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let address = String(cString: host)
            if address.hasPrefix("169.254.") { continue }
            if best == nil || (name.hasPrefix("en") && !best!.name.hasPrefix("en")) || name == "en0" {
                best = (name, address)
            }
        }
        return best?.address
    }

    /// This Mac's Bonjour name ("Name-MacBook.local"), which the phone resolves
    /// on any network and which survives a new IP address. `nil` if unset.
    public static func bonjourName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// The link that installs one phone shortcut, with the token in it.
    public static func shortcutURL(host: String, port: UInt16, token: String, kind: PhoneShortcut = .share) -> String {
        "http://\(host):\(port)\(kind.path)?t=\(token)"
    }

    /// The URL the phone opens, with the token in it.
    public static func pageURL(host: String, port: UInt16, token: String) -> String {
        "http://\(host):\(port)/?t=\(token)"
    }
}
