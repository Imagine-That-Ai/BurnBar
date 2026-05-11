import Darwin
import Foundation

// MARK: - Local Network Discovery
//
// Shared helpers for LAN-only device discovery. These routines avoid
// assuming Bonjour is reliable and avoid hard-coding the user's subnet:
// we derive candidates from this Mac's current non-loopback IPv4
// interfaces, then keep pinned/manual hosts first.

enum LocalNetworkDiscovery {
    static func localIPv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            guard isUsableLANIPv4(ip) else { continue }
            addresses.append(ip)
        }
        return unique(addresses)
    }

    static func pixelClockCandidateHosts(configuredHost: String) -> [String] {
        let pinned = [configuredHost, "192.168.68.92"]
        return classCCandidates(localIPv4Addresses: localIPv4Addresses(), pinnedHosts: pinned)
    }

    static func classCCandidates(localIPv4Addresses: [String], pinnedHosts: [String] = []) -> [String] {
        var hosts: [String] = []
        for host in pinnedHosts {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableLANIPv4(trimmed) {
                hosts.append(trimmed)
            }
        }

        for address in localIPv4Addresses where isUsableLANIPv4(address) {
            guard let prefix = classCPrefix(address) else { continue }
            for suffix in 1...254 {
                hosts.append("\(prefix).\(suffix)")
            }
        }
        return unique(hosts)
    }

    static func preferredLANIPv4Address() -> String? {
        localIPv4Addresses().first
    }

    static func dashboardURLCandidates(port: Int = 8787, path: String = "/render.html") -> [URL] {
        var urls: [URL] = []
        if let address = preferredLANIPv4Address(),
           let url = URL(string: "http://\(address):\(port)\(path)") {
            urls.append(url)
        }

        if let hostName = Host.current().localizedName?
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: ""),
           !hostName.isEmpty,
           let url = URL(string: "http://\(hostName).local:\(port)\(path)") {
            urls.append(url)
        }

        if let fallback = URL(string: "http://127.0.0.1:\(port)\(path)") {
            urls.append(fallback)
        }
        return unique(urls)
    }

    private static func classCPrefix(_ address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }

    private static func isUsableLANIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 127 || parts[0] == 0 { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }
        return true
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
