import Foundation
import OpenBurnBarKernel

// MARK: - Memory Blind Sync inbox guard (PR-2)
//
// Who may drain the `agent_memory_inbox`, and whether anyone may.
//
// The inbox is a plaintext landing zone shared by three processes with three
// different views of the member. The app knows who is signed in and what they
// consented to; the daemon has no Firebase identity; the Memory MCP engine has
// no uid at all. Before this file, the app established "only the signed-in
// member's rows are unmerged" LAZILY, inside `pullRemoteFacts`, which runs only
// when every consent lever is open — while the two consumers of that invariant
// (`daemon.memory.sync.inbox.list` and `burnbar_memory_sync_pull`) are reachable
// whether or not it ever ran. Two failure modes followed, neither needing an
// attacker: member A's parked rows draining into member B's engine after an
// account switch on a shared Mac, and a member who turned the sub-toggle OFF
// still having their already-parked rows merged on the next tool call.
//
// This closes both, twice over:
//
//   1. **Eagerly, wherever the state is observed.** `enforce` runs on every sync
//      cycle BEFORE the gate can return, and on the Settings toggle itself — so
//      sign-out, a uid change, the sub-toggle closing, the backup opt-in
//      closing, and an entitlement lapse all purge what may no longer drain,
//      rather than waiting for a pull that consent has just forbidden.
//   2. **As a predicate the daemon can evaluate.** The same call publishes (or
//      withdraws) the consent marker `BurnBarMemoryDeviceSyncMarker` describes,
//      which `syncInboxList` / `syncInboxAck` filter on. The daemon no longer
//      documents an invariant it cannot check; it enforces one.
//
// Consent off means BOTH: another member's pending rows go, and so do this
// member's own. Nothing pending may drain while the switch is off.

/// The state the guard acts on: who is signed in, and whether the effective
/// four-lever device-sync gate is open right now.
struct MemoryDeviceSyncScope: Equatable, Sendable {
    /// The signed-in member, or nil when signed out / Firebase absent.
    let uid: String?
    /// `SettingsManager.memoryDeviceSyncEnabled` — the sub-toggle AND the backup
    /// opt-in AND the Data Vault entitlement AND the fleet ceiling.
    let consentGranted: Bool

    /// Signed out, or consent withdrawn: nothing may drain.
    static let closed = MemoryDeviceSyncScope(uid: nil, consentGranted: false)

    /// True only when a member is signed in AND every consent lever is open.
    var isOpen: Bool {
        guard let uid, !uid.isEmpty else { return false }
        return consentGranted
    }
}

/// What one enforcement pass did, so a caller can log an account switch or a
/// consent revocation instead of having it happen silently.
struct MemoryDeviceSyncGuardOutcome: Equatable, Sendable {
    /// Unmerged rows dropped because they belong to a different account.
    let purgedOtherAccount: Int
    /// Unmerged rows dropped because consent is off — the member's own included.
    let purgedConsentWithdrawn: Int
    /// Whether the marker now names a consenting member (true) or is absent
    /// (false, which the daemon reads as "nothing may drain").
    let markerPublished: Bool

    static let noop = MemoryDeviceSyncGuardOutcome(
        purgedOtherAccount: 0,
        purgedConsentWithdrawn: 0,
        markerPublished: false
    )
}

enum MemoryDeviceSyncInboxGuard {
    /// Bring the inbox and the consent marker in line with `scope`.
    ///
    /// Idempotent and cheap to call on every cycle: the purges are `DELETE`s
    /// that usually match nothing, and the marker write is one row.
    ///
    /// Ordering matters. The marker is withdrawn BEFORE the purge when consent
    /// closes (so a drain racing the transition sees no consent rather than a
    /// half-emptied inbox) and published AFTER the purge when it opens (so a
    /// drain racing that transition never sees a marker over foreign rows).
    @discardableResult
    static func enforce(
        scope: MemoryDeviceSyncScope,
        store: ControlPlaneStore,
        now: Date = Date()
    ) async throws -> MemoryDeviceSyncGuardOutcome {
        guard scope.isOpen, let uid = scope.uid else {
            try await store.clearMemoryDeviceSyncMarker()
            let purged = try await store.purgeAllUnappliedRemoteMemoryFacts()
            if purged > 0 {
                AppLogger.sync.error(
                    "memory_device_sync_inbox_purged_on_consent_withdrawn",
                    metadata: ["count": String(purged)]
                )
            }
            return MemoryDeviceSyncGuardOutcome(
                purgedOtherAccount: 0,
                purgedConsentWithdrawn: purged,
                markerPublished: false
            )
        }
        let purged = try await store.purgeUnappliedRemoteMemoryFacts(otherThanUserID: uid)
        if purged > 0 {
            AppLogger.sync.error(
                "memory_device_sync_inbox_purged_other_account",
                metadata: ["count": String(purged)]
            )
        }
        try await store.writeMemoryDeviceSyncMarker(userID: uid, now: now)
        return MemoryDeviceSyncGuardOutcome(
            purgedOtherAccount: purged,
            purgedConsentWithdrawn: 0,
            markerPublished: true
        )
    }
}
