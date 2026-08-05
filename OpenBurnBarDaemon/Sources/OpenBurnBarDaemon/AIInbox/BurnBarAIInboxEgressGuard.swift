import Foundation
import OpenBurnBarEngine

/// Enforces the egress promise made by `BurnBarInboxEgressMode`.
///
/// The settings screen tells the user that **local** means "a model running on
/// this machine or your local network — nothing reaches a cloud provider". That
/// is a privacy commitment, and a commitment that lives only in copy is not a
/// commitment. Without this guard, `.local` and `.cloud` behave identically:
/// both resolve a route through the same router, and a user who selected
/// `.local` because they did not want their transcripts leaving the LAN could
/// silently ship them to a cloud endpoint — because a provider happened to be
/// configured, not because they chose it.
///
/// So the mode is enforced where the destination is finally known: after the
/// route resolves and before a single byte is sent. A route that fails the check
/// is refused, and the tick degrades to the rule-based brief rather than
/// quietly doing the thing the user declined.
enum BurnBarAIInboxEgressGuard {
    enum Decision: Sendable, Hashable {
        case allowed
        case refused(reason: String)

        var isAllowed: Bool { self == .allowed }
    }

    /// Checks a resolved route against the configured mode.
    static func evaluate(baseURL: String, mode: BurnBarInboxEgressMode) -> Decision {
        switch mode {
        case .off:
            // Should be unreachable — the pipeline never resolves a route in this
            // mode — but a defense-in-depth refusal costs nothing and means a
            // future refactor cannot silently start spending.
            return .refused(reason: "Model calls are turned off.")
        case .cloud:
            return .allowed
        case .local:
            guard let host = host(from: baseURL) else {
                return .refused(reason: "The configured endpoint has no resolvable host.")
            }
            guard isLocal(host: host) else {
                return .refused(
                    reason: "\(host) is not on this machine or local network, and the AI Inbox is set to local-only."
                )
            }
            return .allowed
        }
    }

    /// Extracts the host, tolerating a base URL written without a scheme
    /// (`localhost:11434`), which is a common way to configure Ollama.
    static func host(from baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let url = URL(string: trimmed), let host = url.host, host.isEmpty == false {
            return host.lowercased()
        }
        if let url = URL(string: "http://\(trimmed)"), let host = url.host, host.isEmpty == false {
            return host.lowercased()
        }
        return nil
    }

    /// Loopback, link-local, `.local` mDNS names, and the RFC1918 private ranges.
    ///
    /// Deliberately a strict allowlist rather than a cloud-provider denylist: a
    /// denylist is wrong the moment someone stands up a new endpoint, and being
    /// wrong here means leaking a transcript.
    static func isLocal(host: String) -> Bool {
        let host = host.lowercased()

        if host == "localhost" || host == "::1" || host.hasSuffix(".localhost") { return true }
        // mDNS / Bonjour names, e.g. `studio.local`.
        if host.hasSuffix(".local") { return true }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            // A non-IPv4 literal that is not a recognized local name. IPv6
            // loopback is handled above; anything else is treated as remote.
            return false
        }

        switch (octets[0], octets[1]) {
        case (127, _):                       return true  // loopback
        case (10, _):                        return true  // RFC1918 /8
        case (192, 168):                     return true  // RFC1918 /16
        case (169, 254):                     return true  // link-local
        case (172, let second) where (16...31).contains(second):
            return true                                    // RFC1918 /12
        default:
            return false
        }
    }
}
