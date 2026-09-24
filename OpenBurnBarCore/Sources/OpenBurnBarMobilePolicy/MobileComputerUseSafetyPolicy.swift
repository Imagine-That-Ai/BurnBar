import Foundation

public enum MobileComputerUseSafetyDecision: String, Sendable, Equatable {
    case allow
    case reject
}

/// Fail-closed Computer Use decisions. Android must match iOS.
public enum MobileComputerUseSafetyPolicy {
    public static func decision(
        kind: String,
        viewOnly: Bool = false,
        authenticated: Bool = true,
        grantExpired: Bool = false,
        bindingMatches: Bool = true,
        replayed: Bool = false,
        tampered: Bool = false,
        rateLimited: Bool = false,
        sessionExpired: Bool = false,
        panic: Bool = false,
        intentKind: String = "tap"
    ) -> MobileComputerUseSafetyDecision {
        if panic { return .reject }
        if !authenticated { return .reject }
        if grantExpired { return .reject }
        if sessionExpired { return .reject }
        if !bindingMatches { return .reject }
        if replayed { return .reject }
        if tampered { return .reject }
        if rateLimited { return .reject }
        if viewOnly && intentKind != "panic" { return .reject }
        switch kind {
        case "replay",
             "tamper",
             "expired-grant",
             "unauthenticated",
             "binding-mismatch",
             "view-only-control",
             "panic",
             "rate-limit",
             "session-expiry":
            return .reject
        case "valid-control":
            return .allow
        default:
            return .reject
        }
    }

    public static func reason(
        kind: String,
        viewOnly: Bool = false,
        authenticated: Bool = true,
        grantExpired: Bool = false,
        bindingMatches: Bool = true,
        replayed: Bool = false,
        tampered: Bool = false,
        rateLimited: Bool = false,
        sessionExpired: Bool = false,
        panic: Bool = false,
        intentKind: String = "tap"
    ) -> String {
        if panic { return "panic" }
        if !authenticated { return "unauthenticated" }
        if grantExpired { return "expired-grant" }
        if sessionExpired { return "session-expiry" }
        if !bindingMatches { return "binding-mismatch" }
        if replayed { return "replay" }
        if tampered { return "tamper" }
        if rateLimited { return "rate-limit" }
        if viewOnly && intentKind != "panic" { return "view-only" }
        if kind == "valid-control" { return "ok" }
        return kind
    }

    public static func shouldSendPhoneControl(
        authenticated: Bool,
        grantExpired: Bool,
        bindingMatches: Bool,
        replayed: Bool,
        tampered: Bool,
        rateLimited: Bool,
        sessionExpired: Bool,
        panic: Bool,
        viewOnly: Bool,
        intentKind: String
    ) -> Bool {
        decision(
            kind: "valid-control",
            viewOnly: viewOnly,
            authenticated: authenticated,
            grantExpired: grantExpired,
            bindingMatches: bindingMatches,
            replayed: replayed,
            tampered: tampered,
            rateLimited: rateLimited,
            sessionExpired: sessionExpired,
            panic: panic,
            intentKind: intentKind
        ) == .allow
    }
}
