import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// T-IOS-05 — hardened clipboard writes for sensitive values (pairing tokens,
/// relay URLs, curl snippets that embed secrets, and text grabbed from the
/// paired Mac's clipboard).
///
/// Plain `UIPasteboard.general.string = …` leaves the value on the system
/// pasteboard indefinitely, syncs it to every Handoff/Universal-Clipboard device
/// in range, and exposes it to any app that reads the pasteboard. This helper
/// uses `setItems(_:options:)` so each write is:
///   * `.expirationDate` — auto-cleared by the system after a short TTL even if
///     the user never pastes it,
///   * `.localOnly` — never broadcast to other devices via Universal Clipboard.
///
/// `clear()` lets call sites wipe the value early (e.g. once a one-time token has
/// been consumed). Pure `Foundation` decision (`expirationDate(from:ttl:)`) so
/// the TTL math is unit-testable without `UIPasteboard`.
enum SecurePasteboard {
    /// Default time-to-live for a sensitive clipboard value. Long enough to
    /// switch apps and paste, short enough to bound exposure.
    static let defaultTTL: TimeInterval = 90

    /// Pure TTL helper: the absolute expiration date for a write made `now`.
    static func expirationDate(from now: Date = Date(), ttl: TimeInterval = defaultTTL) -> Date {
        now.addingTimeInterval(ttl)
    }

    /// Copies `string` to the general pasteboard with an expiration and
    /// local-only scope. No-op off UIKit platforms.
    static func copy(_ string: String, ttl: TimeInterval = defaultTTL) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems(
            [[UTTypeText: string]],
            options: [
                .expirationDate: expirationDate(ttl: ttl),
                .localOnly: true
            ]
        )
        #endif
    }

    /// Clears the general pasteboard if it still holds the value we wrote, so a
    /// consumed one-time token does not linger. Best-effort.
    static func clearIfMatching(_ string: String) {
        #if canImport(UIKit)
        if UIPasteboard.general.string == string {
            UIPasteboard.general.items = []
        }
        #endif
    }

    #if canImport(UIKit)
    /// Pasteboard UTI for plain text. Spelled out (rather than `UTType`) to keep
    /// the helper free of a `UniformTypeIdentifiers` import across all call
    /// sites and match the `[String: Any]` item shape `setItems` expects.
    private static let UTTypeText = "public.utf8-plain-text"
    #endif
}
