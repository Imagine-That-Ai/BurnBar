import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum OpenBurnBarBrowserTargetPolicy {
    static func validatedURL(_ rawValue: String, allowDataURL: Bool = false) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let url = URL(string: trimmed) else {
            throw NSError(
                domain: "OpenBurnBarBrowserTargetPolicy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Browser action URL is invalid."]
            )
        }

        guard let scheme = url.scheme?.lowercased() else {
            throw NSError(
                domain: "OpenBurnBarBrowserTargetPolicy",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Browser action URL must include a scheme."]
            )
        }

        if allowDataURL, scheme == "data" {
            return url
        }

        guard scheme == "http" || scheme == "https",
              let host = url.host,
              host.isEmpty == false else {
            throw NSError(
                domain: "OpenBurnBarBrowserTargetPolicy",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Browser action URL must use http or https with a host."]
            )
        }

        guard isBlockedHost(host) == false else {
            throw NSError(
                domain: "OpenBurnBarBrowserTargetPolicy",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Browser action URL targets a blocked local, private, or metadata host."]
            )
        }

        return url
    }

    /// T-AI-04 — post-DNS (anti-rebind) enforcement.
    ///
    /// `validatedURL`/`isBlockedHost` reject a *literal* private/metadata host,
    /// but a hostname can resolve to a private/link-local/metadata IP (classic
    /// DNS-rebinding SSRF: `evil.example.com → 169.254.169.254`). This resolves the
    /// host through the system resolver and rejects the navigation if ANY resolved
    /// address is in the blocked ranges, so the agent's browser cannot be steered
    /// onto the loopback/metadata plane via DNS.
    ///
    /// `resolver` is injectable so the security decision is unit-testable without
    /// real DNS. The default resolver uses `getaddrinfo`. A host that is already a
    /// literal IP short-circuits (the literal check above already covered it). A
    /// resolution failure is treated as fail-closed (`blocked`) for http/https.
    static func validatedResolvedURL(
        _ rawValue: String,
        allowDataURL: Bool = false,
        resolver: (String) -> [String] = OpenBurnBarBrowserTargetPolicy.systemResolvedAddresses
    ) throws -> URL {
        let url = try validatedURL(rawValue, allowDataURL: allowDataURL)
        // data: URLs (when allowed) and schemes without a host have no DNS to
        // rebind; the literal validation already accepted them.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, host.isEmpty == false else {
            return url
        }

        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        // A literal IP was already range-checked by `isBlockedHost`; no DNS step.
        if ipv4Bytes(from: normalized) != nil || ipv6Bytes(from: normalized) != nil {
            return url
        }

        let resolved = resolver(host)
        guard resolved.isEmpty == false else {
            throw NSError(
                domain: "OpenBurnBarBrowserTargetPolicy",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Browser action host could not be resolved; refusing navigation."]
            )
        }
        for address in resolved where isBlockedHost(address) {
            throw NSError(
                domain: "OpenBurnBarBrowserTargetPolicy",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Browser action host resolves to a blocked local, private, or metadata address (anti-rebind)."]
            )
        }
        return url
    }

    /// Resolve `host` to its A/AAAA addresses via `getaddrinfo`. Returns the
    /// numeric address strings (empty on failure).
    static func systemResolvedAddresses(_ host: String) -> [String] {
        #if canImport(Darwin) || canImport(Glibc)
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let sockaddr = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    sockaddr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    let address = String(cString: buffer)
                    if address.isEmpty == false {
                        addresses.append(address)
                    }
                }
            }
            node = current.pointee.ai_next
        }
        return addresses
        #else
        return []
        #endif
    }

    static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard normalized.isEmpty == false else { return true }

        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if normalized == "metadata"
            || normalized == "metadata.google.internal"
            || normalized.hasSuffix(".metadata.google.internal") {
            return true
        }

        if let bytes = ipv4Bytes(from: normalized) {
            return isBlockedIPv4(bytes)
        }
        if let bytes = ipv6Bytes(from: normalized) {
            return isBlockedIPv6(bytes)
        }

        return false
    }

    private static func ipv4Bytes(from host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard let value = ipv4NumericPart(part) else {
                return nil
            }
            values.append(value)
        }

        switch values.count {
        case 1:
            guard values[0] <= 0xffff_ffff else { return nil }
            return [
                UInt8((values[0] >> 24) & 0xff),
                UInt8((values[0] >> 16) & 0xff),
                UInt8((values[0] >> 8) & 0xff),
                UInt8(values[0] & 0xff)
            ]
        case 2:
            guard values[0] <= 0xff, values[1] <= 0x00ff_ffff else { return nil }
            return [
                UInt8(values[0]),
                UInt8((values[1] >> 16) & 0xff),
                UInt8((values[1] >> 8) & 0xff),
                UInt8(values[1] & 0xff)
            ]
        case 3:
            guard values[0] <= 0xff, values[1] <= 0xff, values[2] <= 0xffff else { return nil }
            return [
                UInt8(values[0]),
                UInt8(values[1]),
                UInt8((values[2] >> 8) & 0xff),
                UInt8(values[2] & 0xff)
            ]
        case 4:
            guard values.allSatisfy({ $0 <= 0xff }) else { return nil }
            return values.map { UInt8($0) }
        default:
            return nil
        }
    }

    private static func ipv4NumericPart(_ part: Substring) -> UInt64? {
        guard part.isEmpty == false else { return nil }
        let raw = String(part).lowercased()
        let radix: Int
        let digits: Substring
        if raw.hasPrefix("0x") {
            radix = 16
            digits = raw.dropFirst(2)
        } else if raw.count > 1 && raw.hasPrefix("0") {
            radix = 8
            digits = raw.dropFirst()
        } else {
            radix = 10
            digits = Substring(raw)
        }
        guard digits.isEmpty == false else { return 0 }
        let allowed: ClosedRange<UInt32>
        switch radix {
        case 16: allowed = 0x30...0x66
        case 10: allowed = 0x30...0x39
        case 8: allowed = 0x30...0x37
        default: return nil
        }
        guard digits.unicodeScalars.allSatisfy({
            if radix == 16 {
                return (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
            }
            return allowed.contains($0.value)
        }) else {
            return nil
        }
        return UInt64(digits, radix: radix)
    }

    private static func isBlockedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        let first = bytes[0]
        let second = bytes[1]

        if first == 0 || first == 10 || first == 127 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 198 && (second == 18 || second == 19) { return true }
        if first >= 224 { return true }
        if bytes == [255, 255, 255, 255] { return true }
        return false
    }

    private static func ipv6Bytes(from host: String) -> [UInt8]? {
        #if canImport(Darwin) || canImport(Glibc)
        var address = in6_addr()
        let result = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
        #else
        return nil
        #endif
    }

    private static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }

        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (bytes[0] & 0xfe) == 0xfc { return true }
        if bytes[0] == 0xff { return true }

        let mappedPrefix = Array(repeating: UInt8(0), count: 10) + [0xff, 0xff]
        if Array(bytes.prefix(12)) == mappedPrefix {
            return isBlockedIPv4(Array(bytes.suffix(4)))
        }
        let compatiblePrefix = Array(repeating: UInt8(0), count: 12)
        if Array(bytes.prefix(12)) == compatiblePrefix,
           bytes.suffix(4).contains(where: { $0 != 0 }) {
            return isBlockedIPv4(Array(bytes.suffix(4)))
        }

        return false
    }
}
