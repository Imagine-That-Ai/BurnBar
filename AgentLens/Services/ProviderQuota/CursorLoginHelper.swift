import Foundation
#if os(macOS)
import AppKit
#endif
import OpenBurnBarCore

// MARK: - Cursor Login Helper

/// Captures a Cursor *product* session so usage-summary meters can refresh.
/// This is not BurnBar / Firebase sign-in and invents no OAuth client IDs.
///
/// Web capture reuses `FactoryLoginHelper` (non-persistent WKWebView, Google
/// popup routing, Safari UA). Success requires `WorkosCursorSessionToken`.
/// The cookie is persisted to `ProviderAPIKeyStore` (`cursor_cookie` / per-seat
/// accounts) — the store `CursorQuotaAdapter` already reads.
///
/// Quota refresh must never call these methods.

@MainActor
enum CursorLoginHelper {

    struct LoginResult: Sendable {
        let cookieHeader: String
        let persist: CursorMeterPersistPlan
    }

    enum PersistOutcome: Sendable {
        case persisted(CursorMeterPersistPlan)
        case needsConfirmation(CursorMeterPersistPlan)
    }

    /// Opens Cursor's own login window. Cancel returns nil without changing secrets.
    /// Compatibility wrapper — popover/wizard should call `captureWebSession` then persist.
    static func runLoginFlow() async -> String? {
        try? await captureWebSession()
    }

    static func captureWebSession() async throws -> String {
        guard let header = await FactoryLoginHelper.runCursorLoginFlow() else {
            throw CursorLoginError.userCancelled
        }
        guard CursorMeterSeatPlanning.workosCookieValue(fromCookieHeader: header) != nil else {
            throw CursorLoginError.noCookiesFound
        }
        return header
    }

    static func login(
        installLabel: String = "Cursor",
        confirmAddSeat: Bool = false,
        replaceExistingDefault: Bool = false,
        keyStore: ProviderAPIKeyStore = .shared
    ) async throws -> LoginResult {
        let header = try await captureWebSession()
        let outcome = try persistCookie(
            header,
            installLabel: installLabel,
            confirmAddSeat: confirmAddSeat,
            replaceExistingDefault: replaceExistingDefault,
            keyStore: keyStore
        )
        switch outcome {
        case .persisted(let plan):
            return LoginResult(cookieHeader: plan.seat.cookieHeader, persist: plan)
        case .needsConfirmation:
            throw CursorLoginError.needsSeatConfirmation
        }
    }

    static func persistCookie(
        _ incomingCookie: String,
        installLabel: String,
        email: String? = nil,
        membershipType: String? = nil,
        sourcePath: String? = nil,
        confirmAddSeat: Bool = false,
        replaceExistingDefault: Bool = false,
        keyStore: ProviderAPIKeyStore = .shared
    ) throws -> PersistOutcome {
        let trimmed = incomingCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CursorLoginError.missingCookie
        }
        guard let workos = CursorMeterSeatPlanning.workosCookieValue(fromCookieHeader: trimmed) else {
            throw CursorLoginError.invalidCookie
        }
        if CursorMeterSeatPlanning.isJWTExpired(CursorMeterSeatPlanning.accessToken(fromWorkosValue: workos)) {
            throw CursorLoginError.expiredSession
        }

        let existingDefault = keyStore.apiKey(for: CursorMeterSeat.defaultCookieAccount)
        let existingSeatIDs = CursorMeterSeatPlanning.parseSeatIDs(
            fromIndexJSON: keyStore.apiKey(for: CursorMeterSeat.seatIndexAccount)
        )
        guard let plan = CursorMeterSeatPlanning.planPersist(
            incomingCookie: trimmed,
            existingDefaultCookie: existingDefault,
            existingSeatIDs: existingSeatIDs,
            installLabel: installLabel,
            email: email,
            membershipType: membershipType,
            sourcePath: sourcePath,
            replaceExistingDefault: replaceExistingDefault
        ) else {
            throw CursorLoginError.invalidCookie
        }

        if plan.avoidedOverwrite, !confirmAddSeat, !replaceExistingDefault {
            return .needsConfirmation(plan)
        }

        try CursorMeterSeatPlanning.apply(plan) { account, value in
            try keyStore.setAPIKey(value, for: account)
        }
        return .persisted(plan)
    }

    static func persistEditorSession(
        _ discovered: CursorCookieExtractor.DiscoveredSession,
        confirmAddSeat: Bool = false,
        replaceExistingDefault: Bool = false,
        keyStore: ProviderAPIKeyStore = .shared
    ) throws -> PersistOutcome {
        try persistCookie(
            discovered.session.cookieHeader,
            installLabel: discovered.install.label,
            email: discovered.session.email,
            membershipType: discovered.session.membershipType,
            sourcePath: discovered.install.stateDatabasePath,
            confirmAddSeat: confirmAddSeat,
            replaceExistingDefault: replaceExistingDefault,
            keyStore: keyStore
        )
    }

    static func discoverEditorSessions() -> [CursorCookieExtractor.DiscoveredSession] {
        CursorCookieExtractor.readAllSessions()
    }

    static func configuredSeats(keyStore: ProviderAPIKeyStore = .shared) -> [CursorMeterSeat] {
        CursorMeterSeatPlanning.configuredSeats(
            fromResolvedKeys: CursorMeterSeatPlanning.loadResolvedKeys { keyStore.apiKey(for: $0) }
        )
    }
}

enum CursorLoginError: LocalizedError, Equatable {
    case userCancelled
    case invalidURL
    case noCookiesFound
    case missingCookie
    case invalidCookie
    case expiredSession
    case needsSeatConfirmation

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Sign in was cancelled."
        case .invalidURL:
            return "Could not open Cursor login page."
        case .noCookiesFound:
            return "Cursor signed in, but no WorkosCursorSessionToken cookie was found."
        case .missingCookie:
            return "Paste a WorkosCursorSessionToken to connect this meter."
        case .invalidCookie:
            return "That cookie is not a WorkosCursorSessionToken. Paste the Cursor session cookie and try again."
        case .expiredSession:
            return "That Cursor session has expired. Sign in to Cursor again, then reconnect."
        case .needsSeatConfirmation:
            return "This Cursor session is a different account. Confirm to add it as another meter seat."
        }
    }
}
