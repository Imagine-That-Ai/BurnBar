import Foundation

/// Together prepaid remaining-credit meter.
///
/// Phase 2 re-check (2026-09-17): Together's public OpenAPI Billing tag is
/// only `GET /v1/billing/usage` (month-to-date spend, org-gated beta).
/// Official credits docs are console-only. Live probes of
/// `/v1/billing/balance`, `/v1/billing/credits`, `/v1/credits`, and
/// `/v1/account` return 404 HTML (the Together console Next.js app), not a
/// Bearer JSON wallet. Folklore `/billing/balance` snippets in third-party
/// repos are not a Together API.
///
/// BurnBar therefore ships an **explicit unsupported remaining-credit meter**
/// instead of scraping Together's Google/GitHub console or inventing a
/// remaining-credit window from spend. Facebook is not a Together IdP.
public enum TogetherRemainingCreditsMeter: Sendable {
    public static let title = "Remaining prepaid credits"

    public static let unsupportedStatus =
        "Together prepaid remaining credits are console-only."

    public static let unsupportedDetail =
        "Together's public OpenAPI exposes GET /v1/billing/usage (month-to-date spend), not a remaining-credit or balance endpoint. GET /v1/billing/balance and /v1/credits 404 to the console HTML app. BurnBar will not scrape Together's Google/GitHub billing console or invent a remaining-credit window."

    public static let consoleSignInNote =
        "Together console sign-in is Google or GitHub, not Facebook."

    /// Paths some unofficial snippets claim exist. They are not Together
    /// Bearer APIs — do not request them from the quota adapter.
    public static let folkloreBalancePaths = [
        "/v1/billing/balance",
        "/v1/billing/credits",
        "/v1/credits",
        "/v1/account",
    ]

    public static var fullUnsupportedMessage: String {
        "\(unsupportedStatus) \(unsupportedDetail) \(consoleSignInNote)"
    }
}
