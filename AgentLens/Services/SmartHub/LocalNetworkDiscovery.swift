import Darwin
import Foundation

// MARK: - Local Network Discovery
//
// Shared helpers for LAN-only device discovery. These routines avoid
// assuming Bonjour is reliable and avoid hard-coding the user's subnet:
// we derive candidates from this Mac's current non-loopback IPv4
// interfaces, then keep pinned/manual hosts first.

enum LocalNetworkDiscovery {
    private struct IPv4Interface {
        var address: String
        var addressValue: UInt32
        var netmaskValue: UInt32
    }

    /// Bonjour browse for AWTRIX clocks advertised via `_http._tcp.`. AWTRIX Light
    /// publishes itself as `awtrix_<chipid>._http._tcp.local.` — this is the
    /// canonical discovery method when DHCP shifts the clock's IP. Returns the
    /// resolved IPv4 host strings (no duplicates), shortest timeout-bounded.
    @MainActor
    static func bonjourDiscoverAwtrixHosts(timeout: TimeInterval = 3) async -> [String] {
        let coordinator = AwtrixBonjourCoordinator()
        return await coordinator.run(timeout: timeout)
    }

    static func localIPv4Addresses() -> [String] {
        unique(localIPv4Interfaces().map(\.address))
    }

    private static func localIPv4Interfaces() -> [IPv4Interface] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var snapshots: [IPv4Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  let netmask = current.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            guard let ip = ipv4String(from: address),
                  let addressValue = ipv4Value(from: address),
                  let netmaskValue = ipv4Value(from: netmask) else { continue }
            guard isUsableLANIPv4(ip) else { continue }
            snapshots.append(IPv4Interface(
                address: ip,
                addressValue: addressValue,
                netmaskValue: netmaskValue
            ))
        }
        return snapshots
    }

    static func pixelClockCandidateHosts(configuredHost: String) -> [String] {
        let pinned = [configuredHost, "192.168.68.92"]
        return subnetCandidates(localIPv4Interfaces: localIPv4Interfaces(), pinnedHosts: pinned)
    }

    static func subnetCandidates(
        localIPv4Interfaces: [(address: String, netmask: String)],
        pinnedHosts: [String] = []
    ) -> [String] {
        let interfaces = localIPv4Interfaces.compactMap { snapshot -> IPv4Interface? in
            guard isUsableLANIPv4(snapshot.address),
                  let addressValue = ipv4Value(from: snapshot.address),
                  let netmaskValue = ipv4Value(from: snapshot.netmask) else {
                return nil
            }
            return IPv4Interface(
                address: snapshot.address,
                addressValue: addressValue,
                netmaskValue: netmaskValue
            )
        }
        return subnetCandidates(localIPv4Interfaces: interfaces, pinnedHosts: pinnedHosts)
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

    private static func subnetCandidates(
        localIPv4Interfaces: [IPv4Interface],
        pinnedHosts: [String]
    ) -> [String] {
        var hosts: [String] = []
        for host in pinnedHosts {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableLANIPv4(trimmed) {
                hosts.append(trimmed)
            }
        }

        for snapshot in localIPv4Interfaces {
            let mask = snapshot.netmaskValue
            let network = snapshot.addressValue & mask
            let broadcast = network | ~mask
            guard broadcast > network + 1 else { continue }

            let hostCount = broadcast - network - 1
            if hostCount <= 2_048 {
                for value in (network + 1)..<broadcast {
                    hosts.append(dottedIPv4(value))
                }
            } else if let prefix = classCPrefix(snapshot.address) {
                for suffix in 1...254 {
                    hosts.append("\(prefix).\(suffix)")
                }
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

    private static func ipv4String(from address: UnsafePointer<sockaddr>) -> String? {
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
        guard result == 0 else { return nil }
        return String(cString: hostname)
    }

    private static func ipv4Value(from address: UnsafePointer<sockaddr>) -> UInt32? {
        guard address.pointee.sa_family == UInt8(AF_INET) else { return nil }
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
        }
    }

    private static func ipv4Value(from address: String) -> UInt32? {
        let parts = address.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }

    private static func dottedIPv4(_ value: UInt32) -> String {
        [
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF
        ]
        .map(String.init)
        .joined(separator: ".")
    }

    static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    static func isUsableLANIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 127 || parts[0] == 0 { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }
        return true
    }
}

// MARK: - AWTRIX Bonjour Coordinator
//
// AWTRIX Light publishes itself via mDNS as `awtrix_<chipid>._http._tcp.local.`.
// Browsing for `_http._tcp.` and filtering by the `awtrix_` name prefix is the
// official discovery path documented by the AWTRIX project — it survives DHCP
// lease changes, IP renumbering, and per-device address shuffles that would
// otherwise leave us pointing at a stale host.
@MainActor
private final class AwtrixBonjourCoordinator: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var pendingServices: Set<NetService> = []
    private var hosts: [String] = []
    private var continuation: CheckedContinuation<[String], Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(timeout: TimeInterval) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish()
            }
        }
    }

    private func finish() {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stop()
        pendingServices.forEach { $0.stop() }
        pendingServices.removeAll()
        let snapshot = LocalNetworkDiscovery.unique(hosts)
        if let continuation = self.continuation {
            self.continuation = nil
            continuation.resume(returning: snapshot)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let isAwtrix = service.name.lowercased().hasPrefix("awtrix")
        Task { @MainActor in
            guard isAwtrix else { return }
            self.pendingServices.insert(service)
            service.delegate = self
            service.resolve(withTimeout: 2)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            let resolved = self.extractIPv4Addresses(from: sender)
            for ip in resolved where LocalNetworkDiscovery.isUsableLANIPv4(ip) {
                self.hosts.append(ip)
            }
            self.pendingServices.remove(sender)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.pendingServices.remove(sender)
        }
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Task { @MainActor in self.finish() }
    }

    private func extractIPv4Addresses(from service: NetService) -> [String] {
        guard let addresses = service.addresses else { return [] }
        return addresses.compactMap { data -> String? in
            data.withUnsafeBytes { buf -> String? in
                guard let saddr = buf.bindMemory(to: sockaddr.self).baseAddress else { return nil }
                guard Int32(saddr.pointee.sa_family) == AF_INET else { return nil }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    saddr,
                    socklen_t(saddr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard result == 0 else { return nil }
                return String(cString: hostname)
            }
        }
    }
}
