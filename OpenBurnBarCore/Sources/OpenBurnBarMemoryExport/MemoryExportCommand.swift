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
    public var source: SourceSelection = .authority
    public var dryRun = false
    public var resume = false
    public var sinceAuditSeq: Int?
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
        if let sinceAuditSeq { return .delta(sinceAuditSeq: sinceAuditSeq) }
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
            case "--out", "--recipient", "--source", "--since-audit-seq", "--snapshot", "--max-section-bytes":
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
        case "--snapshot":
            guard let parsed = MIFSnapshotMode(rawValue: value) else {
                throw MemoryExportCommandError.usage(
                    "--snapshot must be one of \(MIFSnapshotMode.allCases.map(\.rawValue))"
                )
            }
            snapshot = parsed
        case "--max-section-bytes":
            guard let parsed = Int(value), parsed > 0 else {
                throw MemoryExportCommandError.usage("--max-section-bytes must be positive")
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
        // `read_txn` pins the WAL against a live 8.4 GB file, so it is never the
        // silent fallback: the operator has to ask for it.
        if snapshot == .readTxn, allowLongRead == false, verb == .export, dryRun == false {
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
