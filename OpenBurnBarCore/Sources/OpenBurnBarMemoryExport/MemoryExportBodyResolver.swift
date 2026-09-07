// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBodyResolver — §3.2, dual `body_ref` resolution.
//
// Two conventions, one detector, and a deliberate detection ORDER: the
// `memory_body_snapshots:` prefix is tested before the 64-hex regex, so a
// hostile `memory_body_snapshots:<64 hex>` value resolves in the app store and
// cannot be steered into the daemon one. That is a door test, and the distinct
// `adversarial_slug_hex` tag exists so the test can see the difference.
//
// Both lanes get the SAME integrity check (M-24). v1.0 claimed the app column
// carried no hash; it does, and the app lane is the larger one, so skipping it
// there would have left the bigger population unverified.
//
// Nothing is invented and nothing resurrects: a body that cannot be
// reconstructed is not a memory record at all, because `memories.content_key` is
// NOT NULL in the target and there is no body to key it from.

import Foundation

public struct MemoryExportResolvedBody: Sendable, Equatable {
    public var body: String
    public var convention: MIFBodyRefConvention
    public var integrity: MIFBodyIntegrity
    public var recoveredFrom: MIFRecoveredFrom
    public var findings: [MIFFindingCode]
    /// True when the body came from `memory_quarantine_bodies` rather than the
    /// project snapshot. See `docs/MEMORY_EXPORT_MIF.md` deviation D-BB-E-4:
    /// MIF v1.1's `recovered_from` has no member for that store, so the record
    /// reports the daemon lane and the exporter counts these separately.
    public var fromQuarantineStore: Bool
}

public struct MemoryExportUnresolvedBody: Sendable, Equatable {
    public var convention: MIFBodyRefConvention
    public var reasonDetail: String
    public var findings: [MIFFindingCode]
}

public enum MemoryExportBodyResolution: Sendable, Equatable {
    case resolved(MemoryExportResolvedBody)
    /// Not a memory record. Exported as a `findings` record and named by id in
    /// `lost.csv` — a count is not a name.
    case unreconstructible(MemoryExportUnresolvedBody)
}

/// The stores a resolution may read. Passed as a value so the resolver stays
/// pure and the adversarial cases are constructible in a test.
public struct MemoryExportBodyStores: Sendable {
    /// `memory_body_snapshots` keyed by `memory_id`.
    public var snapshotsByMemoryID: [String: MemoryExportBodySnapshotRow]
    /// `project_memory_snapshots.snapshotJSON` keyed by `projectSlug`.
    public var projectSnapshotJSONBySlug: [String: String]
    /// `memory_quarantine_bodies.body` keyed by `memory_id`.
    public var quarantineBodiesByMemoryID: [String: String]

    public init(
        snapshotsByMemoryID: [String: MemoryExportBodySnapshotRow] = [:],
        projectSnapshotJSONBySlug: [String: String] = [:],
        quarantineBodiesByMemoryID: [String: String] = [:]
    ) {
        self.snapshotsByMemoryID = snapshotsByMemoryID
        self.projectSnapshotJSONBySlug = projectSnapshotJSONBySlug
        self.quarantineBodiesByMemoryID = quarantineBodiesByMemoryID
    }
}

public enum MemoryExportBodyResolver {

    static let appPrefix = "memory_body_snapshots:"
    static let daemonLocatorPrefix = "Project Memory snapshot ref:"
    static let quarantineLocatorPrefix = "Quarantine body ref:"

    // MARK: - Detection

    /// Detection order is A-prefix first, then the 64-hex regex. Reversing them
    /// is the vulnerability.
    public static func detectConvention(bodyRef: String) -> MIFBodyRefConvention {
        if bodyRef.isEmpty { return .absent }
        if bodyRef.hasPrefix(appPrefix) {
            let remainder = String(bodyRef.dropFirst(appPrefix.count))
            return isHex64(remainder) ? .adversarialSlugHex : .snapshotSlug
        }
        if isHex64(bodyRef) { return .sha256 }
        return .unknown
    }

    static func isHex64(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    // MARK: - Resolution

    public static func resolve(
        memory: MemoryExportMemoryRow,
        stores: MemoryExportBodyStores
    ) -> MemoryExportBodyResolution {
        let convention = detectConvention(bodyRef: memory.bodyRef)

        switch convention {
        case .snapshotSlug, .adversarialSlugHex:
            if let resolution = resolveAppLane(memory: memory, stores: stores, convention: convention) {
                return resolution
            }
        case .sha256:
            if let resolution = resolveDaemonLane(memory: memory, stores: stores, convention: convention) {
                return resolution
            }
        case .unknown, .absent:
            break
        }

        // A row can carry an app-lane ref and still have both bodies present —
        // the D5 duplicate case — so the cross-store check runs even when the
        // primary lane answered. It is folded into the lane helpers above; what
        // remains here is the recovery ladder.
        return recover(memory: memory, stores: stores, convention: convention)
    }

    private static func resolveAppLane(
        memory: MemoryExportMemoryRow,
        stores: MemoryExportBodyStores,
        convention: MIFBodyRefConvention
    ) -> MemoryExportBodyResolution? {
        guard let snapshot = stores.snapshotsByMemoryID[memory.id], let body = snapshot.body else {
            return nil
        }
        var findings: [MIFFindingCode] = []
        var integrity: MIFBodyIntegrity = MemoryExportDigest.sha256Hex(body) == snapshot.bodyHash
            ? .verified
            : .mismatch
        if integrity == .mismatch { findings.append(.bodyHashMismatch) }

        // D5: a row present in BOTH stores. Equal hashes collapse to one body;
        // unequal ones export the app-lane body and say so.
        if let daemonBody = daemonBody(memory: memory, stores: stores), daemonBody != body {
            integrity = .divergent
            findings.append(.bodyDivergentStores)
        }
        return .resolved(MemoryExportResolvedBody(
            body: body,
            convention: convention,
            integrity: integrity,
            recoveredFrom: .memoryBodySnapshots,
            findings: findings,
            fromQuarantineStore: false
        ))
    }

    private static func resolveDaemonLane(
        memory: MemoryExportMemoryRow,
        stores: MemoryExportBodyStores,
        convention: MIFBodyRefConvention
    ) -> MemoryExportBodyResolution? {
        // The 64-hex `body_ref` is used ONLY for verification and never enters
        // MIF. The locator lives in `body_redacted`.
        guard let found = daemonBodyWithOrigin(memory: memory, stores: stores) else { return nil }
        var findings: [MIFFindingCode] = []
        let integrity: MIFBodyIntegrity = MemoryExportDigest.sha256Hex(found.body) == memory.bodyRef
            ? .verified
            : .mismatch
        if integrity == .mismatch { findings.append(.bodyHashMismatch) }
        return .resolved(MemoryExportResolvedBody(
            body: found.body,
            convention: convention,
            integrity: integrity,
            recoveredFrom: .projectMemorySnapshots,
            findings: findings,
            fromQuarantineStore: found.fromQuarantine
        ))
    }

    /// M-25: recovery FIRST, before declaring loss. For legacy pre-v39 app rows
    /// `body_redacted` held the plaintext body, and the daemon's migration of
    /// those into snapshots can fail or be interrupted.
    private static func recover(
        memory: MemoryExportMemoryRow,
        stores: MemoryExportBodyStores,
        convention: MIFBodyRefConvention
    ) -> MemoryExportBodyResolution {
        let redacted = memory.bodyRedacted
        let isLocator = redacted.hasPrefix(appPrefix)
            || redacted.hasPrefix(daemonLocatorPrefix)
            || redacted.hasPrefix(quarantineLocatorPrefix)
        if redacted.isEmpty == false, isLocator == false {
            return .resolved(MemoryExportResolvedBody(
                body: redacted,
                convention: convention,
                integrity: .recoveredLegacyPlaintext,
                recoveredFrom: .bodyRedactedLegacyPlaintext,
                findings: [.bodyRecoveredLegacyPlaintext],
                fromQuarantineStore: false
            ))
        }
        // Even with an unusable `body_ref`, the daemon locator may still point
        // at a live body. Try it before giving up.
        if let found = daemonBodyWithOrigin(memory: memory, stores: stores) {
            return .resolved(MemoryExportResolvedBody(
                body: found.body,
                convention: convention,
                integrity: .mismatch,
                recoveredFrom: .projectMemorySnapshots,
                findings: convention == .unknown ? [.bodyRefUnknownConvention] : [.bodyHashMismatch],
                fromQuarantineStore: found.fromQuarantine
            ))
        }

        var findings: [MIFFindingCode] = [.bodyUnreconstructible]
        if convention == .unknown { findings.insert(.bodyRefUnknownConvention, at: 0) }
        return .unreconstructible(MemoryExportUnresolvedBody(
            convention: convention,
            reasonDetail: reasonDetail(convention: convention, bodyRef: memory.bodyRef),
            findings: findings
        ))
    }

    private static func reasonDetail(convention: MIFBodyRefConvention, bodyRef: String) -> String {
        switch convention {
        case .absent: "body_ref is empty and body_redacted holds no plaintext"
        case .unknown: "body_ref matches no known convention: \(bodyRef.prefix(32))"
        case .snapshotSlug, .adversarialSlugHex: "no memory_body_snapshots row for this memory_id"
        case .sha256: "no project_memory_snapshots section and no quarantine body"
        }
    }

    // MARK: - Daemon store lookup

    private struct DaemonBody {
        var body: String
        var fromQuarantine: Bool
    }

    private static func daemonBody(memory: MemoryExportMemoryRow, stores: MemoryExportBodyStores) -> String? {
        daemonBodyWithOrigin(memory: memory, stores: stores)?.body
    }

    /// M-17: the locator lives in `body_redacted` (`Project Memory snapshot
    /// ref:agent-<projectID>#<memoryID>`), and where it is missing the exporter
    /// reconstructs it from `project_id` + `id`.
    private static func daemonBodyWithOrigin(
        memory: MemoryExportMemoryRow,
        stores: MemoryExportBodyStores
    ) -> DaemonBody? {
        let locator = parseDaemonLocator(memory.bodyRedacted)
        let slug = locator?.slug ?? projectMemorySlug(projectID: memory.projectID)
        let memoryID = locator?.memoryID ?? memory.id

        if let json = stores.projectSnapshotJSONBySlug[slug],
           let body = section(named: memoryID, inSnapshotJSON: json) {
            return DaemonBody(body: body, fromQuarantine: false)
        }
        // A quarantined or rejected daemon row's body lives in
        // `memory_quarantine_bodies`, not in the project snapshot. Treating that
        // as loss would silently drop the daemon lane's whole review queue.
        if let body = stores.quarantineBodiesByMemoryID[memory.id] {
            return DaemonBody(body: body, fromQuarantine: true)
        }
        return nil
    }

    static func projectMemorySlug(projectID: String) -> String { "agent-\(projectID)" }

    static func parseDaemonLocator(_ value: String) -> (slug: String, memoryID: String)? {
        let prefix: String
        if value.hasPrefix(daemonLocatorPrefix) {
            prefix = daemonLocatorPrefix
        } else if value.hasPrefix(quarantineLocatorPrefix) {
            prefix = quarantineLocatorPrefix
        } else {
            return nil
        }
        let remainder = value.dropFirst(prefix.count)
        guard let hash = remainder.lastIndex(of: "#") else { return nil }
        return (String(remainder[remainder.startIndex..<hash]), String(remainder[remainder.index(after: hash)...]))
    }

    /// `pages[].sections[]` where `id == memoryID`, `body` being the plaintext.
    static func section(named memoryID: String, inSnapshotJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = object["pages"] as? [[String: Any]] else {
            return nil
        }
        for page in pages {
            guard let sections = page["sections"] as? [[String: Any]] else { continue }
            if let match = sections.first(where: { ($0["id"] as? String) == memoryID }) {
                return match["body"] as? String
            }
        }
        return nil
    }
}
