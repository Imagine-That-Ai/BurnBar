import Foundation

// MARK: - Mini-Program Host Contracts (Hermes Square §6.6)
//
// The host primitives exposed to a `custom` card's sandboxed mini-program
// (rendered in WKWebView on iOS, WebView on Android). The JS bridge
// allowlists exactly these 8 verbs (plan §2 Pillar 4). Anything else is
// rejected.
//
// JSON-on-wire shape — JS side calls
//     window.burnbarHostInvoke({ action: "dispatch", payload: {...} })
// and the bridge dispatches into `MiniProgramHostPrimitive.handle(...)`.

public enum MiniProgramHostPrimitive: String, Codable, Sendable, Hashable, CaseIterable {
    case dispatch
    case approve
    case fork
    case forward
    case delegate
    case pin
    case subscribe
    case rollback

    public var displayLabel: String {
        rawValue.capitalized
    }
}

// MARK: - JS bridge envelope

public struct MiniProgramHostCall: Codable, Sendable, Hashable {
    public let action: MiniProgramHostPrimitive
    public let correlationID: String
    public let payload: [String: String]
    public let agentURI: String
    public let cardURI: String

    public init(
        action: MiniProgramHostPrimitive,
        correlationID: String,
        payload: [String: String],
        agentURI: String,
        cardURI: String
    ) {
        self.action = action
        self.correlationID = correlationID
        self.payload = payload
        self.agentURI = agentURI
        self.cardURI = cardURI
    }
}

public struct MiniProgramHostResponse: Codable, Sendable, Hashable {
    public let correlationID: String
    public let success: Bool
    public let resultJSON: String?
    public let error: String?

    public init(correlationID: String, success: Bool, resultJSON: String? = nil, error: String? = nil) {
        self.correlationID = correlationID
        self.success = success
        self.resultJSON = resultJSON
        self.error = error
    }
}

// MARK: - Validation

public enum MiniProgramHostCallValidator {
    public enum ValidationError: LocalizedError {
        case unknownAction(String)
        case payloadTooLarge(bytes: Int, max: Int)
        case missingAgentURI
        case unauthorisedAgent(String)

        public var errorDescription: String? {
            switch self {
            case .unknownAction(let s):
                return "Mini-program tried to invoke unknown host action '\(s)'."
            case .payloadTooLarge(let bytes, let max):
                return "Mini-program call payload was \(bytes) bytes; max is \(max)."
            case .missingAgentURI:
                return "Mini-program call missing agentURI."
            case .unauthorisedAgent(let uri):
                return "Mini-program call references unauthorised agent '\(uri)'."
            }
        }
    }

    /// Per-call payload cap. Keep tiny — the host primitive vocabulary is
    /// already narrow (8 verbs), so legitimate calls fit in well under 16 KB.
    public static let maxCallPayloadBytes = 16_384

    /// Validate before dispatch. Throws on policy violations; caller
    /// echoes an error response over the bridge.
    public static func validate(
        _ call: MiniProgramHostCall,
        installedAgentURIs: Set<String>
    ) throws {
        if call.agentURI.isEmpty {
            throw ValidationError.missingAgentURI
        }
        if !installedAgentURIs.contains(call.agentURI) {
            throw ValidationError.unauthorisedAgent(call.agentURI)
        }
        let payloadData = try? JSONEncoder().encode(call.payload)
        if let payloadData, payloadData.count > maxCallPayloadBytes {
            throw ValidationError.payloadTooLarge(bytes: payloadData.count, max: maxCallPayloadBytes)
        }
    }

    /// Build the strict CSP a `WKWebView` / `WebView` should apply when
    /// hosting a mini-program. Locked down to self + the sandbox URL.
    public static func contentSecurityPolicy(sandboxURL: String) -> String {
        let origin = URL(string: sandboxURL)
            .flatMap { url -> String? in
                guard let host = url.host else { return nil }
                let scheme = url.scheme ?? "https"
                if let port = url.port { return "\(scheme)://\(host):\(port)" }
                return "\(scheme)://\(host)"
            } ?? "'self'"
        return [
            "default-src 'self' \(origin)",
            "script-src 'self' \(origin)",
            "style-src 'self' 'unsafe-inline' \(origin)",
            "img-src 'self' data: \(origin)",
            "connect-src \(origin)",
            "object-src 'none'",
            "base-uri 'self'",
            "frame-ancestors 'none'"
        ].joined(separator: "; ")
    }
}
