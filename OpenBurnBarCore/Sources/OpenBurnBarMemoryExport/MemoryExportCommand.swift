// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportCommand — flags and dispatch for `openburnbar-cli memory <verb>`.
//
// The CLI dispatches on a flat first word in `BurnBarCLIRunner.run(arguments:)`,
// so this is one new `case "memory"` with the verbs `export`, `export-status`,
// `verify` and `p5-check`. Parsing lives here rather than in the CLI target for
// the reason §3.1 of the integration plan gives: the artefact users actually run
// is the **Xcode-built binary inside `OpenBurnBar.app`**, whose "Export memory"
// action calls the engine IN-PROCESS. Two call sites, one parser, no drift.
//
// R9 is a shipping rule, not a note: the SPM build is development-only, and on
// an encrypted source with no codec it must fail naming the artefact rather than
// silently reading a file it cannot decrypt.

import Foundation

public struct MemoryExportCommand: Sendable, Equatable {
    public enum Verb: String, Sendable, CaseIterable {
        case export
        case exportStatus = "export-status"
        case verify
        /// D-0007's memory-lane check. Deliberately its own verb: it proves
        /// something the export cannot, and it must be runnable without one.
        case p5Check = "p5-check"
        /// The D-0021 ruling 6 interop fixture's missing half: an X25519
        /// recipient keypair with BOTH halves written to disk, so a sealed
        /// bundle exists that the Rust importer can actually open. Its own verb
        /// rather than a flag on `export`, because D-0025 ruling 3 requires
        /// `--recipient` whenever a bundle is sealed and this must not become a
        /// second way around that: the export that follows takes the descriptor
        /// this verb wrote, like any other.
        case recipientKeypair = "recipient-keypair"
    }

    public enum SourceSelection: String, Sendable, CaseIterable {
        case authority
        case legacy
        case cloud
        case all
    }

    public var verb: Verb
    public var out: String?
    public var recipient: String?
    /// `verify` and `p5-check` read an existing bundle rather than writing one.
    public var bundle: String?
    /// `verify`: the exporter's signing-key descriptor (`exporter-signing-key.json`,
    /// written beside the bundle by the export and carried to the verifier by
    /// the operator — the out-of-band half of the TOFU pin, review #2564).
    /// Absent means "verify against this device's own key", which is correct
    /// exactly when the bundle was exported here.
    public var signingKeyPath: String?
    /// `p5-check`: the target's live memory ids, one per line, as the importer
    /// publishes them. Step 3 is an id-set diff, and there is no honest way to
    /// obtain the other side's set from this one.
    public var targetIDs: String?
    /// `p5-check`: the target's per-row digests — `memory_id` then the row's
    /// `sha256(UTF-8(normalize(body)))` hex, whitespace-separated, one pair per
    /// line. The keyed `body_norm_digest` cannot be recomputed here (the
    /// bundle key was wrapped and discarded), so the shared recipe is the
    /// unkeyed normalized-body digest both stores can compute over their own
    /// rows (review #2564).
    public var targetDigests: String?
    /// `p5-check` step 0(a): the release whose daemon carries no
    /// `daemon.memory.*` handler and no `agent_memories` writer. No default —
    /// inventing a version number here would turn the gate into a formality.
    public var requiredVersion: String?
    /// `recipient-keypair`: the store id the fixture's importer will present,
    /// which is what `manifest.recipient_store_id` carries and what an importer
    /// compares against its own store id to answer "was this bundle sealed to
    /// me?".
    ///
    /// `nil` means MINT one (`MemoryExportRecipient.mintStoreID()`), and that is
    /// the default: it used to default to the literal `importer-store-fixture`,
    /// which `schema/memory-v1.sql`'s CHECK on `schema_meta.store_id` forbids —
    /// so interop run 1's fixture was addressed to a store that could not exist
    /// and `RECIPIENT_MISMATCH` was unavoidable at any importer (M-10, M-11).
    /// A value supplied here is validated against the same pattern.
    public var storeID: String?
    /// Step 0(b) and 0(c). Operator assertions, defaulting to FALSE, so an
    /// operator who does not make them gets `P5_SOURCE_NOT_QUIESCED` rather
    /// than a pass.
    public var socketTokenRotated = false
    public var memoryWriteWithdrawn = false
    public var source: SourceSelection = .authority
    public var dryRun = false
    public var resume = false
    public var sinceAuditSeq: Int?
    /// The previous bundle's `delta_watermarks["agent_memories"]`. §5's delta
    /// predicate is `audit_seq > since` OR `updated_at > watermark`, and without
    /// the second half a delta is a full export wearing a delta's manifest.
    public var sinceUpdatedAtMS: Int?
    public var snapshot: MIFSnapshotMode = .readTxn
    public var allowLongRead = false
    public var carryOrphans = false
    public var acceptDegradedSource = false
    public var rehearsal = false
    public var deterministicNonces = false
    public var maxSectionBytes = 256 * 1024 * 1024
    public var json = false

    public var mode: MemoryExportMode {
        if dryRun { return .dryRun }
        if let sinceAuditSeq, let sinceUpdatedAtMS {
            return .delta(sinceAuditSeq: sinceAuditSeq, sinceUpdatedAtMS: sinceUpdatedAtMS)
        }
        return .full
    }

    /// Sources the caller asked for that this release cannot read. Recorded as
    /// `partial_sources`, never a silent skip — §3.3's rule for cloud applies to
    /// any source the exporter declines.
    public var unreadableSources: [(source: String, reason: String)] {
        switch source {
        case .authority: []
        case .legacy: [("legacy", "legacy plaintext stores are inventoried but not carried in BB-E")]
        case .cloud: [("cloud", "the cloud vault reader is not part of release BB-E")]
        case .all: [
            ("legacy", "legacy plaintext stores are inventoried but not carried in BB-E"),
            ("cloud", "the cloud vault reader is not part of release BB-E")
        ]
        }
    }

    public static func parse(_ arguments: [String]) throws -> MemoryExportCommand {
        guard let first = arguments.first, let verb = Verb(rawValue: first) else {
            throw MemoryExportCommandError.usage(
                "Usage: openburnbar-cli memory <\(Verb.allCases.map(\.rawValue).joined(separator: "|"))> [flags]"
            )
        }
        var command = MemoryExportCommand(verb: verb)
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--dry-run": command.dryRun = true
            case "--resume": command.resume = true
            case "--allow-long-read": command.allowLongRead = true
            case "--carry-orphans": command.carryOrphans = true
            case "--accept-degraded-source": command.acceptDegradedSource = true
            case "--rehearsal": command.rehearsal = true
            case "--deterministic-nonces": command.deterministicNonces = true
            case "--json": command.json = true
            case "--socket-token-rotated": command.socketTokenRotated = true
            case "--memory-write-withdrawn": command.memoryWriteWithdrawn = true
            case "--out", "--recipient", "--source", "--since-audit-seq", "--since-updated-at-ms",
                 "--snapshot", "--max-section-bytes", "--bundle", "--target-ids", "--target-digests",
                 "--required-version", "--store-id", "--signing-key":
                index += 1
                guard index < arguments.count else {
                    throw MemoryExportCommandError.usage("\(argument) needs a value")
                }
                try command.assign(argument, value: arguments[index])
            default:
                throw MemoryExportCommandError.usage("Unknown flag \(argument)")
            }
            index += 1
        }
        try command.validate()
        return command
    }

    private mutating func assign(_ flag: String, value: String) throws {
        switch flag {
        case "--out": out = value
        case "--recipient": recipient = value
        case "--bundle": bundle = value
        case "--target-ids": targetIDs = value
        case "--target-digests": targetDigests = value
        case "--signing-key": signingKeyPath = value
        case "--store-id": storeID = value
        case "--required-version": requiredVersion = value
        case "--source":
            guard let parsed = SourceSelection(rawValue: value) else {
                throw MemoryExportCommandError.usage("--source must be one of \(SourceSelection.allCases.map(\.rawValue))")
            }
            source = parsed
        case "--since-audit-seq":
            guard let parsed = Int(value), parsed >= 0 else {
                throw MemoryExportCommandError.usage("--since-audit-seq must be a non-negative integer")
            }
            sinceAuditSeq = parsed
        case "--since-updated-at-ms":
            guard let parsed = Int(value), parsed >= 0 else {
                throw MemoryExportCommandError.usage("--since-updated-at-ms must be a non-negative integer")
            }
            sinceUpdatedAtMS = parsed
        case "--snapshot":
            guard let parsed = MIFSnapshotMode(rawValue: value) else {
                throw MemoryExportCommandError.usage(
                    "--snapshot must be one of \(MIFSnapshotMode.allCases.map(\.rawValue))"
                )
            }
            snapshot = parsed
        case "--max-section-bytes":
            // A section's rotation boundary is measured in CIPHERTEXT, and
            // every sealed segment carries a 16-byte Poly1305 tag — so a limit
            // at or below the AEAD overhead leaves zero bytes of plaintext
            // capacity and writes `limit`-byte-segment bundles no manifest can
            // declare honestly (review #2564).
            guard let parsed = Int(value),
                  parsed > MemoryExportCrypto.sealOverheadBytes else {
                throw MemoryExportCommandError.usage(
                    "--max-section-bytes must exceed the AEAD overhead "
                        + "(\(MemoryExportCrypto.sealOverheadBytes) bytes of tag per segment)"
                )
            }
            maxSectionBytes = parsed
        default:
            throw MemoryExportCommandError.usage("Unknown flag \(flag)")
        }
    }

    private func validate() throws {
        if verb == .export, dryRun == false, out == nil {
            throw MemoryExportCommandError.usage("memory export needs --out")
        }
        // D-0025 ruling 3. Without this the exporter writes a complete, sealed,
        // signed bundle whose content key exists nowhere, tells the operator
        // "written to: …", and nobody can ever open it. `--rehearsal` is the one
        // exception, and it mints a throwaway recipient that report.json names.
        if verb == .export, recipient == nil, rehearsal == false {
            throw MemoryExportCommandError.usage(
                "\(MIFExportError.recipientRequired.rawValue): memory export needs --recipient "
                    + "<descriptor.json>, published by `memoryctl memory export-recipient`. "
                    + "A bundle sealed to no recipient can never be opened."
            )
        }
        // D-0039 ruling 7's shape, checked before an export is built on top of
        // it rather than after a bundle has been sealed to it.
        if let storeID, MemoryExportRecipient.isValidStoreID(storeID) == false {
            throw MemoryExportCommandError.usage(
                "--store-id must be the target store's own id, `sto_` followed by 32 lowercase hex "
                    + "digits (36 characters) — `memoryctl memory export-recipient` prints it. Omit the "
                    + "flag to mint one. A bundle sealed to any other string is refused by every store."
            )
        }
        if verb == .recipientKeypair, out == nil {
            throw MemoryExportCommandError.usage(
                "memory recipient-keypair needs --out <dir>: it writes recipient.json (the D-0025 "
                    + "descriptor) and recipient-secret.json (the private half) there."
            )
        }
        if verb == .verify, bundle == nil {
            throw MemoryExportCommandError.usage("memory verify needs --bundle <dir>")
        }
        // The P5 check is an id-set diff between two stores, and this side holds
        // one of them. Both other inputs are the runbook's to supply.
        if verb == .p5Check {
            if targetIDs == nil {
                throw MemoryExportCommandError.usage(
                    "memory p5-check needs --target-ids <file>: the target's live memory ids, one per line, "
                        + "as `memoryctl memory live-ids` prints them. Step 3 is an id-set diff."
                )
            }
            if targetDigests == nil {
                throw MemoryExportCommandError.usage(
                    "memory p5-check needs --target-digests <file>: the target's per-row digests, "
                        + "`memory_id` then `sha256(UTF-8(normalize(body)))` hex, whitespace-separated, "
                        + "one pair per line. Step 3 is an id-set AND digest diff; without the second "
                        + "leg a corrupted row diffs clean."
                )
            }
            if requiredVersion == nil {
                throw MemoryExportCommandError.usage(
                    "memory p5-check needs --required-version <x.y.z>: the release whose daemon carries no "
                        + "daemon.memory.* handler and no agent_memories writer. Step 0(a) refuses an older "
                        + "build BY VERSION and never disables one in place."
                )
            }
        }
        // A delta needs BOTH halves of §5's predicate. Accepting `--since-audit-seq`
        // alone and quietly exporting everything is worse than refusing: the
        // manifest would say `"delta"`, the operator would believe P4's catch-up
        // had run, and the P5 final delta would carry the whole store.
        if (sinceAuditSeq == nil) != (sinceUpdatedAtMS == nil) {
            throw MemoryExportCommandError.usage(
                "a delta needs both --since-audit-seq and --since-updated-at-ms; take them from the "
                    + "previous bundle's manifest (`since_audit_seq` is its audit head, "
                    + "`delta_watermarks.agent_memories` the watermark)."
            )
        }
        // `read_txn` pins the WAL against a live 8.4 GB file, so it is never the
        // silent fallback: the operator has to ask for it. A dry run reads the
        // same way and for the same duration, so it asks too.
        if snapshot == .readTxn, allowLongRead == false, verb == .export {
            throw MemoryExportCommandError.usage("--snapshot read_txn requires --allow-long-read")
        }
        // Compiled out of release builds, not merely refused at runtime — so on
        // a release build this flag cannot even be honoured.
        #if !DEBUG
        if deterministicNonces {
            throw MemoryExportCommandError.usage("--deterministic-nonces is not available in a release build")
        }
        #endif
        if deterministicNonces, rehearsal == false {
            throw MemoryExportCommandError.usage("--deterministic-nonces requires --rehearsal")
        }
        // BB-E's writer builds a bundle in one pass rather than streaming it,
        // so there is no partial bundle to resume onto. Accepting the flag and
        // silently ignoring it would be worse than not offering it: the
        // operator would believe a half-written bundle had been completed.
        if resume {
            throw MemoryExportCommandError.usage(
                "--resume is not available in release BB-E: the bundle is written in one pass, "
                    + "so there is no partial bundle to resume. Re-run the export."
            )
        }
    }
}

public enum MemoryExportCommandError: Error, Equatable {
    case usage(String)
}

/// §5, P1: `burnbar.memory.export.enabled`, default OFF and user-initiated.
/// Namespaced by product — v1.0's shared `memory.*` prefix across two products
/// is gone.
public enum MemoryExportFeatureFlag {
    public static let name = "burnbar.memory.export.enabled"
    public static let defaultValue = false

    /// Resolve against a caller-supplied lookup so the flag store stays the
    /// app's. An absent or unparseable value is OFF, never ON.
    public static func isEnabled(_ lookup: (String) -> String?) -> Bool {
        switch lookup(name)?.lowercased() {
        case "1", "true", "yes": true
        default: defaultValue
        }
    }
}
