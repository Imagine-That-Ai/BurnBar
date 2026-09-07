// SPDX-License-Identifier: AGPL-3.0-only
//
// OpenBurnBarCLI+MemoryExport — `openburnbar-cli memory <verb>`, release BB-E.
//
// One `case "memory"` with the verbs `export | export-status | verify |
// p5-check`. The parsing and the engine both live in
// `OpenBurnBarCore/Sources/OpenBurnBarMemoryExport`, because the artefact users
// actually run is the Xcode-built binary inside `OpenBurnBar.app` whose "Export
// memory" action calls the same engine IN-PROCESS. Two call sites, one parser,
// no drift.
//
// **R9 is a shipping rule, not a note.** Evidence conflicts on whether the
// SPM-built binary carries a SQLCipher codec on macOS, so this refuses to read
// an encrypted store when `PRAGMA cipher_version` is empty, and names the
// artefact it is running as. It never mints a key: a missing Keychain key on an
// existing encrypted file is `EXPORT_KEY_UNAVAILABLE`, never a re-key.

#if OPENBURNBAR_MEMORY_EXPORT
import Foundation
import GRDB
import OpenBurnBarMemoryExport
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension BurnBarCLIRunner {

    static let memoryUsage = """
    Usage: openburnbar-cli memory <export|export-status|verify|p5-check> [flags]
      --out PATH            bundle directory to write
      --recipient PATH      the importer's X25519 public key (32 raw bytes or 64 hex)
      --dry-run             classify and dereference, write nothing
      --since-audit-seq N   delta export from an audit head
      --snapshot MODE       vacuum | sqlcipher_export | backup_api | read_txn
      --allow-long-read     required for --snapshot read_txn
      --carry-orphans       carry body rows no authority row references (default off)
      --json                emit the reconciliation report as JSON
    """

    func runMemoryCommand(_ arguments: [String]) throws -> String {
        let command: MemoryExportCommand
        do {
            command = try MemoryExportCommand.parse(arguments)
        } catch MemoryExportCommandError.usage(let message) {
            throw BurnBarCLIError.missingArgument("\(message)\n\n\(Self.memoryUsage)")
        }

        switch command.verb {
        case .exportStatus:
            return try memoryExportStatus()
        case .verify:
            // Bundle verification is the IMPORTER's job: it holds the recipient
            // private key and this side holds none. Say so rather than
            // pretending to check a signature we cannot open.
            return "Bundle verification runs on the memory core: `memoryctl memory import --dry-run <bundle>`."
        case .p5Check:
            throw BurnBarCLIError.missingArgument(
                "memory p5-check runs from the migration runbook, which supplies the audit head either side of "
                    + "the final delta and the target's live id set. It is not a standalone CLI step."
            )
        case .export:
            return try runMemoryExport(command)
        }
    }

    // MARK: - Verbs

    private func memoryExportStatus() throws -> String {
        let path = Self.memoryStoreURL.path
        let present = FileManager.default.fileExists(atPath: path)
        let encrypted = present && BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path)
        return """
        store:            \(path)
        present:          \(present)
        encrypted:        \(encrypted)
        codec available:  \(BurnBarDaemonDatabaseCipher.isCipherAvailable())
        key resolvable:   \(BurnBarDaemonDatabaseCipher.validatedKeyForGRDB() != nil)
        flag:             \(MemoryExportFeatureFlag.name) (default OFF)
        """
    }

    private func runMemoryExport(_ command: MemoryExportCommand) throws -> String {
        guard MemoryExportFeatureFlag.isEnabled({ ProcessInfo.processInfo.environment[$0] }) else {
            throw BurnBarCLIError.missingArgument(
                "\(MemoryExportFeatureFlag.name) is OFF. The export is user-initiated by design (spec §5, P1)."
            )
        }
        // D-0009's ladder needs an executed R9-class test to pin a rung on the
        // shipped artefact. Until that test runs, the only honest primitive is
        // the long read, and the export fails rather than falling through to an
        // unpinned copy.
        guard command.snapshot == .readTxn else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.snapshotUnavailable.rawValue): no snapshot rung is pinned on this artefact. "
                    + "Re-run with --snapshot read_txn --allow-long-read, or land the R9 snapshot-primitive pin first."
            )
        }

        let queue = try openMemoryStore()
        let snapshot = try queue.read { try MemoryExportStoreReader.read($0) }
        let exporter = MemoryExporter(
            storeID: try Self.memoryStoreID(),
            storeFingerprint: try Self.memoryStoreFingerprint(),
            sourceVersion: BurnBarDaemonVersion.current,
            userID: nil,
            recipientPublicKey: try command.recipient.map(Self.loadRecipientKey),
            signingKey: try Self.loadSigningKey(),
            options: MemoryExportOptions(
                enabled: true,
                carryOrphans: command.carryOrphans,
                acceptDegradedSource: command.acceptDegradedSource,
                rehearsal: command.rehearsal,
                maxSectionBytes: command.maxSectionBytes,
                snapshotMode: command.snapshot,
                partialSources: command.unreadableSources
            )
        )
        let result = try exporter.export(
            snapshot,
            mode: command.mode,
            to: command.out.map { URL(fileURLWithPath: $0) }
        )
        if command.json {
            return MIFCanonicalJSON.serialize(result.report.json)
        }
        return Self.formatMemoryExport(result)
    }

    // MARK: - Store

    static var memoryStoreURL: URL {
        BurnBarDaemonPaths.supportDirectoryURL.appendingPathComponent("openburnbar.sqlite")
    }

    /// Opens the shared store READ-ONLY. Every refusal below is deliberate: the
    /// export must never be the thing that creates, re-keys or writes to the
    /// file roughly twenty other RPC families depend on.
    private func openMemoryStore() throws -> DatabaseQueue {
        let path = Self.memoryStoreURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw BurnBarCLIError.missingArgument("No memory store at \(path); nothing to export.")
        }
        var configuration = Configuration()
        configuration.readonly = true
        if BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path) {
            guard BurnBarDaemonDatabaseCipher.isCipherAvailable() else {
                // R9: the SPM build is development-only. Name the artefact
                // rather than silently reading a file it cannot decrypt.
                throw BurnBarCLIError.missingArgument(
                    "EXPORT_CODEC_ABSENT: this binary carries no SQLCipher codec "
                        + "(\(CommandLine.arguments.first ?? "openburnbar-cli")). "
                        + "Run the exporter from OpenBurnBar.app, which is the artefact the R9 door test proves."
                )
            }
            guard let key = BurnBarDaemonDatabaseCipher.validatedKeyForGRDB() else {
                throw BurnBarCLIError.missingArgument(
                    "\(MIFExportError.keyUnavailable.rawValue): the store is encrypted and its key is not "
                        + "resolvable on this device. The exporter never mints one."
                )
            }
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA key = '\(key)'")
            }
        }
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    /// A store identity that is not a path: the same value two runs of the same
    /// store produce, and that a copy of the file elsewhere does NOT.
    static func memoryStoreID() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: memoryStoreURL.path)
        let inode = (attributes[.systemFileNumber] as? Int) ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "burnbar-" + String(
            MemoryExportDigest.sha256Hex("\(inode)\u{1F}\(Int(created))").prefix(24)
        )
    }

    static func memoryStoreFingerprint() throws -> String {
        MemoryExportDigest.sha256Hex(try memoryStoreID())
    }

    // MARK: - Keys

    /// The importer publishes this with `memoryctl memory export-recipient`. It
    /// is a P0 prerequisite gated by nothing: a bundle cannot be produced
    /// without it.
    static func loadRecipientKey(_ path: String) throws -> Curve25519.KeyAgreement.PublicKey {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let bytes: Data
        if raw.count == 32 {
            bytes = raw
        } else if let hex = String(data: raw, encoding: .utf8).flatMap(Self.hexBytes), hex.count == 32 {
            bytes = hex
        } else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.recipientUnverified.rawValue): --recipient must be 32 raw bytes or 64 hex chars."
            )
        }
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes)
    }

    /// `com.openburnbar.memory-export` / `export-signing-key-v1`. Absent is a
    /// refusal, not an unsigned bundle: the importer pins this key on first
    /// import and must reject a bundle that carries none.
    static func loadSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let url = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("memory-export-signing-key-v1")
        guard let raw = try? Data(contentsOf: url), raw.count == 32 else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.keyUnavailable.rawValue): no export signing key at \(url.path). "
                    + "Provision it before the first export; the exporter never mints one."
            )
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    static func hexBytes(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // MARK: - Rendering

    static func formatMemoryExport(_ result: MemoryExportBundleResult) -> String {
        let report = result.report
        var lines = [
            "bundle:      \(result.bundleID)",
            "digest:      \(result.contentDigest)",
            "decision:    \(report.decision.rawValue)",
            "memories in: \(report.memoriesIn)",
            "memories out:\(report.memoriesOut)"
        ]
        if report.auditProvenHuman > 0 {
            lines.append("kept human:  \(report.auditProvenHuman)")
        }
        let reclassified = report.approvedToQuarantined.values.reduce(0, +)
        if reclassified > 0 {
            lines.append("need review: \(reclassified) (approved by an agent, not by you)")
        }
        if report.bodiesUnreconstructible > 0 {
            lines.append("lost text:   \(report.bodiesUnreconstructible) (named in lost.csv)")
        }
        if report.gateClasses.total > 0 {
            lines.append(
                "gate held:   \(report.gateClasses.total) "
                    + "(reject \(report.gateClasses.reject), redact \(report.gateClasses.redact), "
                    + "hold \(report.gateClasses.hold))"
            )
        }
        if report.holdReasons.isEmpty == false {
            lines.append("held:        \(report.holdReasons.map(\.rawValue).joined(separator: ", "))")
        }
        if let url = result.bundleURL {
            lines.append("written to:  \(url.path)")
        } else {
            lines.append("dry run:     nothing written (\(result.wouldWriteBytes) bytes would be)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
