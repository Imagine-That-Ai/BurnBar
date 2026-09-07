// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportP5Check — §5 step 0-3 under D-0007. A separate command, because
// it proves something the export itself cannot.
//
// **The P5 hard stop is a MEMORY-LANE stop, not a BurnBar stop.** v1.1's first
// draft answered "the final delta ran against a store still being written" by
// killing the daemon LaunchAgent and `chmod 0400`-ing the file. D-0007 forbids
// both: that agent and that one `openburnbar.sqlite` serve roughly twenty
// unrelated RPC families — inbox, fleet, search, resume — and BurnBar must keep
// working without Po'dex and without memory. Stopping the agent or changing the
// shared file's mode breaks a product this migration has no licence to break.
//
// The purpose of the stop is "no second writer", and a VERSION GATE proves that
// better than a process kill, because a build with no memory writer in it cannot
// write memory even while it is running. So:
//
//   0. require BurnBar >= BB-R (refused by version, never disabled in place),
//      rotate the socket token, withdraw `memoryWrite` — and LEAVE
//      `com.openburnbar.daemon` LOADED AND RUNNING with the store's mode
//      exactly as it is.
//   1. assert `audit_head_seq`, take the final delta.
//   2. assert `audit_head_seq` is UNCHANGED across it. That is the whole proof
//      that no writer remains, and it is an observation of the shared file
//      rather than an assertion about a process — which is why it stays valid
//      with the LaunchAgent up.
//   3. reconcile as an id-set + digest diff, never a per-bundle count.

import Foundation

public struct MemoryExportP5Gates: Sendable, Equatable {
    /// The running BurnBar version.
    public var sourceVersion: String
    /// The release whose daemon carries no `daemon.memory.*` handler and no
    /// `agent_memories` writer.
    public var requiredVersion: String
    /// Step 0(b) — a process still holding the old token is refused at the
    /// socket.
    public var socketTokenRotated: Bool
    /// Step 0(c) — the `memoryWrite` capability class is withdrawn from every
    /// delegate.
    public var memoryWriteCapabilityWithdrawn: Bool

    public init(
        sourceVersion: String,
        requiredVersion: String,
        socketTokenRotated: Bool,
        memoryWriteCapabilityWithdrawn: Bool
    ) {
        self.sourceVersion = sourceVersion
        self.requiredVersion = requiredVersion
        self.socketTokenRotated = socketTokenRotated
        self.memoryWriteCapabilityWithdrawn = memoryWriteCapabilityWithdrawn
    }

    /// Semantic compare, so `1.0.9 < 1.0.40` rather than the string answer.
    public var buildIsNewEnough: Bool {
        MemoryExportP5Check.compare(sourceVersion, requiredVersion) >= 0
    }
}

public struct MemoryExportP5Result: Sendable {
    public var report: MemoryExportReport
    public var passed: Bool
    public var holdReasons: [MIFHoldReason]
}

public enum MemoryExportP5Check {

    /// Run the check around a final delta.
    ///
    /// - Parameters:
    ///   - headBefore: `audit_head_seq` read at the start of the delta.
    ///   - headAfter: the same value read after the delta completed.
    ///   - sourceLiveIDs / targetLiveIDs: step 3's id sets.
    ///   - digestMismatch: ids whose per-row digest roll-up differs.
    public static func run(
        gates: MemoryExportP5Gates,
        headBefore: Int,
        headAfter: Int,
        sourceLiveIDs: Set<String>,
        targetLiveIDs: Set<String>,
        digestMismatch: Set<String> = [],
        storeID: String
    ) -> MemoryExportP5Result {
        var report = MemoryExportReport(phase: .p5Reconcile)
        var holds: [MIFHoldReason] = []

        // Step 0(a). An older build is refused BY VERSION and never disabled in
        // place — disabling it in place is the thing D-0007 rules out.
        if gates.buildIsNewEnough == false { holds.append(.p5SourceBuildTooOld) }
        // 0(b) and 0(c) are gates too: without them a process holding an old
        // token is still a writer, and the head assertion below would be
        // measuring luck.
        if gates.socketTokenRotated == false || gates.memoryWriteCapabilityWithdrawn == false {
            holds.append(.p5SourceNotQuiesced)
        }

        // Step 2 — the whole proof. If it moved, a writer survived the gates,
        // and the fix is the version gate, NEVER a kill.
        let quiesced = headBefore == headAfter
        if quiesced == false, holds.contains(.p5SourceNotQuiesced) == false {
            holds.append(.p5SourceNotQuiesced)
        }

        // Step 3 — an id-set + digest diff, not a per-bundle count. All three
        // must be empty.
        let onlyInSource = sourceLiveIDs.subtracting(targetLiveIDs).sorted()
        let onlyInTarget = targetLiveIDs.subtracting(sourceLiveIDs).sorted()
        let mismatched = digestMismatch.sorted()
        let empty = onlyInSource.isEmpty && onlyInTarget.isEmpty && mismatched.isEmpty
        if empty == false { holds.append(.reconciliationMismatch) }

        report.idSetDiff = .object([
            "source_live_count": .int(sourceLiveIDs.count),
            "target_live_count": .int(targetLiveIDs.count),
            "only_in_source": .strings(onlyInSource.map { MemoryExportIdentity.canonicalMemoryID($0, storeID: storeID) }),
            "only_in_target": .strings(onlyInTarget.map { MemoryExportIdentity.canonicalMemoryID($0, storeID: storeID) }),
            "digest_mismatch": .strings(mismatched.map { MemoryExportIdentity.canonicalMemoryID($0, storeID: storeID) }),
            "empty": .bool(empty)
        ])
        report.target = MemoryExportReportTarget(quiesced: quiesced)
        report.holdReasons = holds
        report.decision = holds.isEmpty ? .exported : .held
        report.findings = quiesced ? [] : [MemoryExportFinding(
            code: .concurrentWrites,
            severity: .error,
            count: headAfter - headBefore,
            detail: "audit_head moved across the final delta, so a writer survived the P5 gates. "
                + "The fix is the version gate; the LaunchAgent stays up and the file mode stays as it is."
        )]
        return MemoryExportP5Result(report: report, passed: holds.isEmpty, holdReasons: holds)
    }

    /// Dotted numeric compare with a non-numeric tail ignored, so `1.0.41-beta`
    /// still reads as newer than `1.0.40`.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func components(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .compactMap { Int($0.prefix(while: \.isNumber)) }
    }
}

/// The report's `target` block. Export writes no target, so only the P5 check
/// fills it in.
public struct MemoryExportReportTarget: Sendable, Equatable {
    public var quiesced: Bool
}
