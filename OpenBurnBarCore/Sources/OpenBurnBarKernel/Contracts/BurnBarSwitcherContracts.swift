import Foundation

/// Wave 2.1c-v: the daemon owns `switcher_active_profile` (ADR-005) and the
/// Mac app routes its active-profile writes through this contract instead of
/// touching that table directly. Reads stay on the app's local connection
/// until the read cutover.
///
/// The app finalizes every write locally — the per-provider mirror lookup
/// (`switcher_profiles.cliType`, an app-owned table) and the fallback
/// selection (lowest sortKey) are computed against local reads — and the
/// daemon applies the resulting sets verbatim inside one transaction per
/// apply. The daemon assigns the `updatedAt` stamps (`Date()` bound through
/// GRDB, exactly as the app's pre-cutover writes did), so no timestamps ride
/// the wire.
///
/// `providerID` is a plain string, not a `ProviderID`, for the same reason
/// as the search-index lane: `ProviderID` is open-ended (any string
/// normalizes), so the daemon normalizes and rejects empty spellings loudly
/// (`invalidParams`) instead of decoding into a type that cannot fail.
public struct BurnBarSwitcherActiveProfileSet: Codable, Equatable, Sendable {
    /// The profile to point at, or nil to clear. An empty string is a caller
    /// bug (`invalidParams`): clearing is spelled nil, never "".
    public let profileID: String?

    /// The drain target to rewrite, or nil for the global pointer
    /// (`providerID IS NULL`) that browser launching and legacy callers read.
    public let providerID: String?

    public init(profileID: String?, providerID: String? = nil) {
        self.profileID = profileID
        self.providerID = providerID
    }
}

/// One atomic active-profile apply: an optional clear-by-profile plus an
/// optional batch of pointer sets. At least one operation must be present;
/// a fully empty apply is a caller bug (`invalidParams`). The daemon applies
/// the clear first, then the sets in order — the order is fixed and
/// documented because the app never combines a clear with sets in one call
/// today, and any future combined caller must be able to reason about it.
///
/// Multi-set batches exist for exactly one caller: the global setter, which
/// rewrites the global pointer and mirrors into the profile's per-provider
/// drain target in the single transaction the pre-cutover path used. Batches
/// are capped at two sets; a larger batch is a runaway caller, not a switch.
public struct BurnBarSwitcherActiveProfileApplyRequest: Codable, Equatable, Sendable {
    public let sets: [BurnBarSwitcherActiveProfileSet]
    public let clearProfileID: String?

    public init(
        sets: [BurnBarSwitcherActiveProfileSet] = [],
        clearProfileID: String? = nil
    ) {
        self.sets = sets
        self.clearProfileID = clearProfileID
    }
}

public struct BurnBarSwitcherActiveProfileApplyResponse: Codable, Equatable, Sendable {
    public let setsApplied: Int
    public let rowsCleared: Int

    public init(setsApplied: Int, rowsCleared: Int) {
        self.setsApplied = setsApplied
        self.rowsCleared = rowsCleared
    }
}
