import Foundation

// MARK: - OpenBurnBar Error Taxonomy
//
// Canonical typed failures for macOS app, daemon clients, and Cloud sync surfaces.
// See `docs/architecture/error-taxonomy.md` for handling rules and metric keys.
//
// Deferred (Phase 4 Stream E): `OpenBurnBarUI` SPM split — `OpenBurnBarCore` already
// ships SwiftUI views alongside models; extracting a UI module requires moving 200+
// view files and rewiring the Xcode target graph without a net compile-time win yet.

/// Stable failure domain for observability, user surfaces, and SLO counters.
public enum OpenBurnBarErrorDomain: String, Codable, CaseIterable, Sendable {
    case database
    case sync
    case daemon
    case parse
    case network
    case search
    case quota
    case media
}

/// Typed, log-friendly application error with a stable `{domain}_{code}` metric key.
public struct OpenBurnBarError: Error, Hashable, Sendable {
    public let domain: OpenBurnBarErrorDomain
    public let code: String
    public let message: String
    public let underlyingDescription: String?

    public init(
        domain: OpenBurnBarErrorDomain,
        code: String,
        message: String,
        underlyingDescription: String? = nil
    ) {
        self.domain = domain
        self.code = code
        self.message = message
        self.underlyingDescription = underlyingDescription
    }

    /// Counter key for `LocalMetricsAggregator` / daemon `GET /metrics` (`{domain}_{code}`).
    public var metricKey: String { "\(domain.rawValue)_\(code)" }

    /// Structured log metadata aligned with `AppLogger` conventions.
    public var logMetadata: [String: String] {
        var metadata: [String: String] = [
            "domain": domain.rawValue,
            "code": code,
            "message": message,
        ]
        if let underlyingDescription, !underlyingDescription.isEmpty {
            metadata["underlying"] = underlyingDescription
        }
        return metadata
    }
}

extension OpenBurnBarError: LocalizedError {
    public var errorDescription: String? { message }
    public var failureReason: String? { underlyingDescription ?? message }
}

// MARK: - Factory helpers

public extension OpenBurnBarError {
    static func database(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .database,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func sync(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .sync,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func daemon(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .daemon,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func parse(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .parse,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func network(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .network,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func search(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .search,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func quota(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .quota,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }

    static func media(_ code: String, message: String, underlying: Error? = nil) -> OpenBurnBarError {
        OpenBurnBarError(
            domain: .media,
            code: code,
            message: message,
            underlyingDescription: underlying?.localizedDescription
        )
    }
}

// MARK: - Heuristic mapping

public extension OpenBurnBarError {
    /// Best-effort mapping from legacy string messages to typed sync failures.
    static func inferSync(from message: String) -> OpenBurnBarError {
        let normalized = message.lowercased()
        if normalized.contains("permission") || normalized.contains("denied") {
            return .sync("permission_denied", message: message)
        }
        if normalized.contains("offline") || normalized.contains("network") {
            return .sync("network_unavailable", message: message)
        }
        if normalized.contains("conflict") || normalized.contains("merge") {
            return .sync("merge_conflict", message: message)
        }
        if normalized.contains("circuit") || normalized.contains("breaker") {
            return .sync("circuit_open", message: message)
        }
        return .sync("upload_failed", message: message)
    }
}

/// Minimal cross-platform parser identity contract. App-layer `LogParser` extends this
/// with `parse()` returning `ParseResult`.
public protocol LogParserProtocol: Sendable {
    var provider: AgentProvider { get }
}
