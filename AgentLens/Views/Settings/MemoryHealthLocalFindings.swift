import Foundation
import OpenBurnBarKernel

/// The findings the APP can produce about memory health, in the engine's own
/// `{severity, code, detail, fix}` shape.
///
/// **What this is not.** The engine's `burnbar_memory_doctor` runs inside the
/// Python engine against `openburnbar-memory.sqlite` — a store no Swift process
/// reads, whose key never leaves the engine. Nothing here runs it, so nothing
/// here reports its findings, and the card carries a labelled note saying so.
/// Presenting "no findings" from a doctor that never ran is the failure mode
/// this type exists to avoid.
///
/// Every code below is measured from something the app actually holds:
///   * `AUDIT_CHAIN_BROKEN` — walking `memory_audit.prev_hash` over the
///     bounded tail the snapshot read (`ControlPlaneStore.memoryAuditChainWindow`).
///     The bound is stated to the member, not only in this comment.
///   * `SECRET_CORPUS_UNAVAILABLE` — `MemorySecretPIIGate.isAvailable`, the
///     fail-closed corpus every memory write depends on.
///   * `SYNC_MARKER_STALE` — the device-sync consent marker's own age bound.
///   * `PENDING_REVIEW_BACKLOG` — quarantined rows waiting for a human.
enum MemoryHealthLocalFindings {

    // MARK: Codes

    static let auditChainBroken = "AUDIT_CHAIN_BROKEN"
    static let secretCorpusUnavailable = "SECRET_CORPUS_UNAVAILABLE"
    static let syncMarkerStale = "SYNC_MARKER_STALE"
    static let pendingReviewBacklog = "PENDING_REVIEW_BACKLOG"

    /// Every code this type can emit. The card asserts its findings are a subset
    /// of these, so an engine finding can never be smuggled in.
    static let allCodes: Set<String> = [
        auditChainBroken,
        secretCorpusUnavailable,
        syncMarkerStale,
        pendingReviewBacklog
    ]

    /// The engine's severity vocabulary, used verbatim.
    static let severityError = "error"
    static let severityWarn = "warn"

    /// How many quarantined rows count as a backlog worth surfacing.
    static let pendingReviewBacklogThreshold = 25

    /// The labelled statement the card renders so an empty findings list is
    /// never read as a clean engine bill of health.
    static let engineDoctorNotMeasuredNote =
        "Engine doctor findings are not measured here. This card reports only what this Mac can check itself."

    // MARK: Audit chain

    /// The first `seq` whose `prev_hash` does not match its predecessor's hash,
    /// or nil when the walked window is intact.
    ///
    /// The first link in the window is never itself a break: the window is a
    /// tail, so its predecessor is simply outside it.
    static func brokenChainSeq(in links: [MemoryAuditChainLink]) -> Int? {
        let ordered = links.sorted { $0.seq < $1.seq }
        for (index, link) in ordered.enumerated() where index > 0 {
            if link.prevHash != ordered[index - 1].hash { return link.seq }
        }
        return nil
    }

    // MARK: Findings

    static func findings(
        snapshot: MemoryHealthLocalSnapshot,
        secretScannerAvailable: Bool = MemorySecretPIIGate.isAvailable,
        now: Date = Date()
    ) -> [ProjectMemoryHealthFinding] {
        var findings: [ProjectMemoryHealthFinding] = []

        if let brokenSeq = brokenChainSeq(in: snapshot.auditChainLinks) {
            findings.append(ProjectMemoryHealthFinding(
                code: auditChainBroken,
                severity: severityError,
                // The scope is part of the claim. This walk is a TAIL — it can
                // say a break exists, never that none does outside the window.
                detail: "The memory audit hash chain breaks at seq \(brokenSeq). "
                    + "This check walks only the most recent \(snapshot.auditChainLinks.count) links, "
                    + "so an older break would not be detected.",
                fix: "Export your memories and reset the local store; the ledger cannot be repaired in place."
            ))
        }

        if secretScannerAvailable == false {
            findings.append(ProjectMemoryHealthFinding(
                code: secretCorpusUnavailable,
                severity: severityError,
                detail: "The secret/PII corpus did not load, so every memory write is being refused (fail-closed).",
                fix: "Reinstall OpenBurnBar — the corpus ships inside the app bundle."
            ))
        }

        // Absent is not stale: no marker means device sync is simply not
        // consented on this Mac, which is the default and not a fault.
        if let refreshedAt = snapshot.deviceSyncMarkerRefreshedAt,
           now.timeIntervalSince(refreshedAt) > BurnBarMemoryDeviceSyncMarker.maxAge {
            findings.append(ProjectMemoryHealthFinding(
                code: syncMarkerStale,
                severity: severityWarn,
                detail: "The device-sync consent marker has not been refreshed since \(Self.stamp(refreshedAt)); the daemon will stop draining memories it cannot vouch for.",
                fix: "Open OpenBurnBar while signed in, or turn device sync off."
            ))
        }

        if snapshot.pendingReviewCount >= pendingReviewBacklogThreshold {
            findings.append(ProjectMemoryHealthFinding(
                code: pendingReviewBacklog,
                severity: severityWarn,
                detail: "\(snapshot.pendingReviewCount) memories are waiting for review and cannot be used until you approve them.",
                fix: "Review pending memories."
            ))
        }

        return findings
    }

    // MARK: Ages

    /// The placeholder every unmeasured stat renders. Never `0`, never "never":
    /// both would assert something the app did not observe.
    static let unmeasured = ProjectMemoryHealthCardModel.placeholder

    /// A compact human age ("4 min ago", "2 h ago", "3 d ago") or the
    /// placeholder when there is no instant to age.
    static func age(of instant: Date?, now: Date = Date()) -> String {
        guard let instant else { return unmeasured }
        let seconds = max(0, now.timeIntervalSince(instant))
        switch seconds {
        case ..<60:
            return "just now"
        case ..<3_600:
            return "\(Int(seconds / 60)) min ago"
        case ..<86_400:
            return "\(Int(seconds / 3_600)) h ago"
        default:
            return "\(Int(seconds / 86_400)) d ago"
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
