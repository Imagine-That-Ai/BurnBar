import Foundation

/**
 * Single source of truth for the loopback services the Mac app and daemon
 * talk to. Every "is this endpoint ours" / "default port" / "base URL"
 * decision funnels through here instead of a scattered `127.0.0.1:NNNN`
 * literal; the CI ratchet (`scripts/ci/check-local-service-literals.mjs`)
 * rejects new literals.
 */

/// A local HTTP service BurnBar launches, manages, or integrates with.
public enum LocalService: String, CaseIterable, Sendable {
    /// The BurnBar daemon's own gateway (`GatewaySettings.gatewayPort` is
    /// user-configurable; this is the default).
    case openBurnBarGateway
    /// The managed Hermes relay host (`hermes_relay_host` runtime).
    case hermesGateway
    /// The managed Pi Agents relay host.
    case piAgentGateway
    /// The managed OpenClaw chat backend gateway.
    case openClawGateway
    /// External Ollama daemon (`ollama serve`).
    case ollama
    /// External MLX server (`mlx_lm.server` — its own default port).
    case mlxServer
    /// External SmartHub (Nest Hub) dashboard service.
    case smartHubDashboard
}

/// How a service's process lifecycle relates to BurnBar.
public enum LocalServiceOwnership: Sendable {
    /// Owned by BurnBar itself (the daemon gateway).
    case openBurnBar
    /// A companion runtime BurnBar manages/launches (Hermes, Pi, OpenClaw).
    case managedCompanion
    /// A third-party local daemon the user runs separately (Ollama, MLX, SmartHub).
    case external
}

public struct LocalServiceDescriptor: Sendable, Equatable {
    public let service: LocalService
    public let displayName: String
    public let defaultPort: Int
    public let ownership: LocalServiceOwnership
    /// Path appended to the loopback base for the canonical entry point
    /// ("" when the bare host:port is the base).
    public let defaultPath: String
    /// True when the service contract requires loopback-only binding —
    /// only the BurnBar gateway, which must never face the LAN.
    public let loopbackRequired: Bool
}

extension LocalService {
    public var descriptor: LocalServiceDescriptor {
        switch self {
        case .openBurnBarGateway:
            return LocalServiceDescriptor(
                service: self,
                displayName: "OpenBurnBar gateway",
                defaultPort: 8317,
                ownership: .openBurnBar,
                defaultPath: "",
                loopbackRequired: true,
            )
        case .hermesGateway:
            return LocalServiceDescriptor(
                service: self,
                displayName: "Hermes gateway",
                defaultPort: 8642,
                ownership: .managedCompanion,
                defaultPath: "",
                loopbackRequired: false,
            )
        case .piAgentGateway:
            return LocalServiceDescriptor(
                service: self,
                displayName: "Pi Agents gateway",
                defaultPort: 8765,
                ownership: .managedCompanion,
                defaultPath: "",
                loopbackRequired: false,
            )
        case .openClawGateway:
            return LocalServiceDescriptor(
                service: self,
                displayName: "OpenClaw gateway",
                defaultPort: 18789,
                ownership: .managedCompanion,
                defaultPath: "",
                loopbackRequired: false,
            )
        case .ollama:
            return LocalServiceDescriptor(
                service: self,
                displayName: "Ollama",
                defaultPort: 11434,
                ownership: .external,
                defaultPath: "",
                loopbackRequired: false,
            )
        case .mlxServer:
            return LocalServiceDescriptor(
                service: self,
                displayName: "MLX server",
                defaultPort: 8080,
                ownership: .external,
                defaultPath: "",
                loopbackRequired: false,
            )
        case .smartHubDashboard:
            return LocalServiceDescriptor(
                service: self,
                displayName: "SmartHub dashboard",
                defaultPort: 8787,
                ownership: .external,
                defaultPath: "/render.html",
                loopbackRequired: false,
            )
        }
    }

    public var defaultPort: Int {
        descriptor.defaultPort
    }

    /// `http://127.0.0.1:<defaultPort>` — the loopback base with no path.
    public var defaultBaseURL: URL {
        // All registered services default to loopback; the URL is built from
        // validated parts, so the initializer cannot fail.
        URL(string: "http://127.0.0.1:\(descriptor.defaultPort)") ?? URL(fileURLWithPath: "/")
    }

    /// `defaultBaseURL` + `descriptor.defaultPath` (when non-empty).
    public var defaultEndpointURL: URL {
        if descriptor.defaultPath.isEmpty {
            return defaultBaseURL
        }
        return defaultBaseURL.appendingPathComponent(descriptor.defaultPath)
    }

    /**
     * Ports that count as "this config points at this service": the
     * configured port plus the shipped default, so configs written before a
     * port change still detect as wired. An out-of-range configured port
     * degrades to the default rather than widening detection.
     */
    public func acceptedPorts(configured: Int) -> [Int] {
        Array(Set([resolvedPort(configured), descriptor.defaultPort])).sorted()
    }

    /// A configured port clamped to a usable value: anything outside
    /// 1...65535 (including a stored `0`/negative "unset" marker) resolves to
    /// the registry default rather than producing a dead endpoint.
    public func resolvedPort(_ configured: Int) -> Int {
        (1...65_535).contains(configured) ? configured : descriptor.defaultPort
    }

    /// A configured host clamped to a usable value: empty and wildcard bind
    /// addresses (`0.0.0.0`, `::`, `[::]`) resolve to loopback — a local
    /// service never listens on an any-address interface.
    public func resolvedHost(_ configured: String?) -> String {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed {
        case "", "0.0.0.0", "::", "[::]":
            return "127.0.0.1"
        default:
            return trimmed
        }
    }

    /**
     * Resolve a configured endpoint to a base URL. An empty, `0.0.0.0`, or
     * `::` host and a missing/out-of-range port normalize to the loopback
     * default — the service is loopback-only by construction.
     */
    public func baseURL(host: String?, port: Int?) -> URL {
        let normalizedHost = resolvedHost(host)
        let normalizedPort = port.map { resolvedPort($0) } ?? descriptor.defaultPort
        return URL(string: "http://\(normalizedHost):\(normalizedPort)") ?? defaultBaseURL
    }

    /**
     * True when `text` references a loopback endpoint on `port` —
     * `127.0.0.1:<port>` or `localhost:<port>`, with or without an
     * `http(s)://` scheme (matches bare `:<port>` occurrences inside config
     * values like TOML `base_url` strings).
     *
     * This is a "mentions" check: any occurrence counts, including comments.
     * For "does this config point at the service" detection, prefer
     * `matchesLoopbackHTTPEndpoint(_:port:)`, which requires a URL scheme so a
     * bare `host:port` mention cannot read as a real endpoint.
     */
    public static func matchesLoopbackEndpoint(_ text: String, port: Int) -> Bool {
        text.range(
            of: #"(?:https?://)?(?:127\.0\.0\.1|localhost):\#(port)\b"#,
            options: .regularExpression,
        ) != nil
    }

    /**
     * True when `text` contains an `http(s)://127.0.0.1:<port>` or
     * `http(s)://localhost:<port>` URL. Use this for endpoint detection where
     * a scheme-less `host:port` mention (a comment, a doc note, an unrelated
     * key) must not count.
     */
    public static func matchesLoopbackHTTPEndpoint(_ text: String, port: Int) -> Bool {
        text.range(
            of: #"https?://(?:127\.0\.0\.1|localhost):\#(port)\b"#,
            options: .regularExpression,
        ) != nil
    }
}

/// Endpoints owned by third-party apps that intentionally share port space
/// with BurnBar services. Not configurable — detection constants only.
public enum LegacyLocalEndpoint {
    /// VibeProxy's own gateway port. It coincides with the BurnBar gateway
    /// default (8317) because OpenBurnBar's gateway replaced VibeProxy's
    /// role; VibeProxy detection (VibeProxyMigrationService and the
    /// `isVibeProxy*` config checks) must keep matching 8317 even when the
    /// user has moved `GatewaySettings.gatewayPort` elsewhere.
    public static let vibeProxyPort = 8317
}

public enum LocalServiceInvariantSeverity: String, Sendable {
    /// A bug in the registry itself — assertion in DEBUG, logged in release.
    case programmerError
    /// A bad user-facing override (unparseable URL, colliding host:port,
    /// non-loopback BurnBar gateway) — surfaced in Help/Support diagnostics.
    case configuration
}

public struct LocalServiceInvariantViolation: Sendable, Equatable, CustomStringConvertible {
    /// Which invariant failed. Drives the Help & Support copy — renderers key
    /// off `kind` and `services`, never off `message` text.
    public enum Kind: String, Sendable {
        /// Two registered services declare the same default port.
        case registryPortCollision
        /// A registry default base URL is not loopback.
        case registryNonLoopbackDefault
        /// The configured endpoint string does not parse as a URL.
        case unparseableEndpoint
        /// Two configured services resolve to the same host:port.
        case endpointCollision
        /// The loopback-required BurnBar gateway was pointed off loopback.
        case gatewayNotLoopback
        /// A configured port (or a registry default that lost its port) is
        /// outside 1...65535.
        case portOutOfRange
    }

    public let kind: Kind
    public let severity: LocalServiceInvariantSeverity
    public let message: String
    public let services: [LocalService]
    /// The offending value (`"htp:/x"`, `"127.0.0.1:8642"`, a port number) so
    /// renderers can quote it without re-parsing `message`.
    public let endpoint: String?

    public init(
        kind: Kind,
        severity: LocalServiceInvariantSeverity,
        message: String,
        services: [LocalService],
        endpoint: String? = nil,
    ) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.services = services
        self.endpoint = endpoint
    }

    public var description: String { message }
}

public enum LocalServiceInvariants {
    /// Registry self-checks: unique default ports, loopback defaults, valid URLs.
    public static func staticViolations() -> [LocalServiceInvariantViolation] {
        var violations: [LocalServiceInvariantViolation] = []
        var seenPorts: [Int: LocalService] = [:]
        for service in LocalService.allCases {
            let descriptor = service.descriptor
            if let other = seenPorts[descriptor.defaultPort] {
                violations.append(LocalServiceInvariantViolation(
                    kind: .registryPortCollision,
                    severity: .programmerError,
                    message: "\(other.descriptor.displayName) and \(descriptor.displayName) share default port \(descriptor.defaultPort)",
                    services: [other, service],
                    endpoint: String(descriptor.defaultPort),
                ))
            }
            seenPorts[descriptor.defaultPort] = service
            let base = service.defaultBaseURL
            if !isLoopbackHost(base.host) {
                violations.append(LocalServiceInvariantViolation(
                    kind: .registryNonLoopbackDefault,
                    severity: .programmerError,
                    message: "\(descriptor.displayName) default base URL is not loopback: \(base.absoluteString)",
                    services: [service],
                    endpoint: base.absoluteString,
                ))
            }
            if base.port != descriptor.defaultPort {
                violations.append(LocalServiceInvariantViolation(
                    kind: .portOutOfRange,
                    severity: .programmerError,
                    message: "\(descriptor.displayName) default base URL lost its port: \(base.absoluteString)",
                    services: [service],
                    endpoint: base.absoluteString,
                ))
            }
        }
        return violations
    }

    /**
     * Checks the caller's resolved override endpoints. `resolved` maps a
     * service to the raw configured string (e.g. a settings TextField value);
     * services absent from the map are checked at their defaults.
     *
     * Collisions are only reported when both endpoints belong to BurnBar-owned
     * services (`openBurnBar` / `managedCompanion`), or when a third-party
     * (`.external`) service's configured value differs from its registry
     * default — a user who moved Hermes onto `127.0.0.1:8080` because they
     * never run MLX must not get a permanent warning for sharing MLX's unused
     * default port.
     */
    public static func configurationViolations(resolved: [LocalService: String]) -> [LocalServiceInvariantViolation] {
        var violations: [LocalServiceInvariantViolation] = []
        var seen: [String: [LocalService]] = [:] // "host:port" -> every service there
        for service in LocalService.allCases {
            let raw = resolved[service]
            let url: URL
            if let raw, !raw.isEmpty {
                guard let parsed = URL(string: raw), parsed.host != nil else {
                    violations.append(LocalServiceInvariantViolation(
                        kind: .unparseableEndpoint,
                        severity: .configuration,
                        message: "\(service.descriptor.displayName) has an unparseable endpoint: \(raw)",
                        services: [service],
                        endpoint: raw,
                    ))
                    continue
                }
                url = parsed
            } else {
                url = service.defaultBaseURL
            }

            if service.descriptor.loopbackRequired, !isLoopbackHost(url.host) {
                violations.append(LocalServiceInvariantViolation(
                    kind: .gatewayNotLoopback,
                    severity: .configuration,
                    message: "\(service.descriptor.displayName) must stay on loopback, not \(url.absoluteString)",
                    services: [service],
                    endpoint: url.absoluteString,
                ))
            }
            if let port = url.port, !(1...65_535).contains(port) {
                violations.append(LocalServiceInvariantViolation(
                    kind: .portOutOfRange,
                    severity: .configuration,
                    message: "\(service.descriptor.displayName) port \(port) is out of range",
                    services: [service],
                    endpoint: String(port),
                ))
            }

            if let host = url.host?.lowercased(), let port = url.port {
                let key = "\(host):\(port)"
                // Check every earlier service on this host:port — suppressing
                // an external-at-default pair must not hide a real collision
                // between two other services sharing the key.
                for other in seen[key] ?? []
                where shouldReportCollision(between: other, and: service, resolved: resolved) {
                    violations.append(LocalServiceInvariantViolation(
                        kind: .endpointCollision,
                        severity: .configuration,
                        message: "\(other.descriptor.displayName) and \(service.descriptor.displayName) are both set to \(key)",
                        services: [other, service],
                        endpoint: key,
                    ))
                }
                seen[key, default: []].append(service)
            }
        }
        return violations
    }

    /// A host:port collision is user-visible only when both services are
    /// BurnBar-owned, or when the third-party side is an explicit override —
    /// an `.external` service sitting on its registry default is not
    /// considered "configured" and cannot produce a warning the user can't
    /// fix in BurnBar settings.
    private static func shouldReportCollision(
        between a: LocalService,
        and b: LocalService,
        resolved: [LocalService: String]
    ) -> Bool {
        if a.descriptor.ownership != .external, b.descriptor.ownership != .external {
            return true
        }
        return isExplicitExternalOverride(a, resolved: resolved)
            || isExplicitExternalOverride(b, resolved: resolved)
    }

    /// True when an `.external` service's configured endpoint parses and
    /// differs from its registry default — i.e. the user pointed it somewhere
    /// on purpose.
    private static func isExplicitExternalOverride(
        _ service: LocalService,
        resolved: [LocalService: String]
    ) -> Bool {
        guard service.descriptor.ownership == .external,
              let raw = resolved[service],
              let parsed = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parsed.host else { return false }
        let defaultBase = service.defaultBaseURL
        return host.lowercased() != defaultBase.host || parsed.port != defaultBase.port
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}
