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
      --recipient PATH      the importer's recipient descriptor JSON (required)
      --dry-run             classify and dereference, write nothing
      --since-audit-seq N   delta export from an audit head (needs the watermark too)
      --since-updated-at-ms N  the previous bundle's delta_watermarks.agent_memories
      --snapshot MODE       vacuum | sqlcipher_export | backup_api | read_txn
      --allow-long-read     required for --snapshot read_txn
      --carry-orphans       carry body rows no authority row references (default off)
      --source WHICH        authority | legacy | cloud | all — an unread source is
                            recorded in partial_sources, never silently skipped
      --accept-degraded-source  export a store whose integrity check failed
      --max-section-bytes N section rotation, in bytes of ciphertext (default 256 MiB)
      --rehearsal           DEBUG builds only: seal to a THROWAWAY recipient nobody
                            holds the private half of. A rehearsal bundle cannot be
                            imported anywhere and report.json says so — it is not a
                            way to make an interop fixture (see recipient-keypair)
      --deterministic-nonces  DEBUG builds only, requires --rehearsal: derive the
                            bundle key from a fixture seed so the bundle reproduces
      --json                emit the reconciliation report as JSON

    recipient-keypair --out DIR [--store-id ID]
      Mints an X25519 recipient keypair and writes BOTH halves into DIR:
      recipient.json (the D-0025 descriptor, to pass to `export --recipient`) and
      recipient-secret.json (the private half, 0600, to hand to the importer).
      For the D-0021 ruling 6 interop fixture only — a real migration uses the
      descriptor the IMPORTER publishes with `memoryctl memory export-recipient`,
      and BurnBar never sees that private key. It exists because `--rehearsal`
      cannot serve here: it discards the private half by design, so a rehearsal
      bundle is sealed to a key nobody holds and is refused as a rehearsal
      bundle besides.

    verify --bundle DIR [--recipient PATH]
      Checks the signature, the manifest's self-consistency and the section
      files on disk. It cannot check the plaintext: the bundle key is wrapped to
      the recipient and never kept here.

    p5-check --target-ids FILE --required-version X.Y.Z
             [--socket-token-rotated] [--memory-write-withdrawn]
      Reads audit_head either side of the source's live id set and diffs that
      set against the target's. The two gate flags are operator assertions and
      default to false, so an unasserted gate holds.
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
            return try runMemoryVerify(command)
        case .p5Check:
            return try runMemoryP5Check(command)
        case .export:
            return try runMemoryExport(command)
        case .recipientKeypair:
            return try runMemoryRecipientKeypair(command)
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
        // §3: "`audit_head_seq` is recorded at start and end". Three separate
        // reads, deliberately — inside one transaction the head cannot move, so
        // a single read could never observe the writer it is meant to detect.
        let headBefore = try queue.read { try MemoryExportStoreReader.auditHead($0) }
        var snapshot = try queue.read { try MemoryExportStoreReader.read($0) }
        let headAfter = try queue.read { try MemoryExportStoreReader.auditHead($0) }
        let concurrentWrites = headBefore.seq != headAfter.seq || headBefore.hash != headAfter.hash

        guard let storeID = snapshot.storeIdentity else {
            // One value, from the enum, in both lanes: `MIFVocabulary` carries
            // the case "so both lanes that refuse can name the same value", and
            // this one spelled it as a bare literal until F-8.
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.storeIdentityAbsent.rawValue): this store carries neither a local `devices` row nor an "
                    + "audit chain, so it has nothing that identifies it from the inside. Every canonical "
                    + "id is seeded from that value, and the exporter will not invent one."
            )
        }
        snapshot.concurrentWrites = concurrentWrites
        let exporter = MemoryExporter(
            storeID: storeID,
            storeFingerprint: MemoryExportDigest.sha256Hex(storeID),
            sourceVersion: BurnBarDaemonVersion.current,
            userID: nil,
            recipient: try Self.resolveRecipient(command),
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

    /// The interop fixture's missing half (D-0021 ruling 6). Two commands make a
    /// bundle the Rust importer can open:
    ///
    ///     openburnbar-cli memory recipient-keypair --out ./fixture-keys
    ///     openburnbar-cli memory export --out ./fixture-bundle \\
    ///         --recipient ./fixture-keys/recipient.json \\
    ///         --snapshot read_txn --allow-long-read
    ///
    /// The export is an ordinary sealed export taking an ordinary descriptor, so
    /// D-0025 ruling 3 is satisfied rather than worked around, and the private
    /// half sits in `./fixture-keys/recipient-secret.json` for the importer.
    private func runMemoryRecipientKeypair(_ command: MemoryExportCommand) throws -> String {
        // swiftlint:disable:next force_unwrapping reason: validate() refuses recipient-keypair without --out
        let directory = URL(fileURLWithPath: command.out!)
        let keypair = MemoryExportRecipient.generateKeypair(storeID: command.storeID)
        let written = try MemoryExportRecipient.writeKeypair(keypair, to: directory)
        if command.json {
            return MIFCanonicalJSON.serialize(.object([
                "recipient_key_id": .string(keypair.recipient.keyID),
                "store_id": .string(keypair.recipient.storeID),
                "descriptor": .string(written.descriptor.path),
                "secret": .string(written.secret.path)
            ]))
        }
        return """
        recipient:   \(keypair.recipient.keyID)
        store:       \(keypair.recipient.storeID)
        descriptor:  \(written.descriptor.path)   (pass to `memory export --recipient`)
        private key: \(written.secret.path)   (0600 — hand to the IMPORTER, never ship it in a bundle)

        This keypair exists for the D-0021 ruling 6 interop fixture. A real
        migration seals to the descriptor the importer publishes with
        `memoryctl memory export-recipient`, and BurnBar never holds that key.
        """
    }

    /// F-16. Decryption needs the recipient private key and this side holds
    /// none — but the signature, the manifest's self-consistency and the section
    /// files on disk need no key at all, and without them a corrupted or
    /// truncated bundle was undetectable until it reached the other side.
    private func runMemoryVerify(_ command: MemoryExportCommand) throws -> String {
        // swiftlint:disable:next force_unwrapping reason: validate() refuses verify without --bundle
        let url = URL(fileURLWithPath: command.bundle!)
        let verification = try MemoryExportBundleVerifier.verify(
            bundleAt: url,
            signingPublicKey: try? Self.loadSigningKey().publicKey,
            recipient: try command.recipient.map(Self.loadRecipient)
        )
        if command.json {
            return MIFCanonicalJSON.serialize(.object([
                "bundle": .string(url.path),
                "intact": .bool(verification.isIntact),
                "signature_verified": .bool(verification.signatureVerified),
                "checks_run": .strings(verification.checksRun),
                "problems": .strings(verification.problems)
            ]))
        }
        return MemoryExportBundleVerifier.format(verification, at: url)
    }

    /// F-17. `MemoryExportP5Check.run` had no shipped caller, so D-0007's
    /// memory-lane proof existed only as a library function while the usage
    /// string advertised the verb.
    ///
    /// Steps 1 and 2 are read HERE, either side of the source's live id set and
    /// in separate transactions — inside one, the head cannot move, and the
    /// whole proof is that it did not.
    private func runMemoryP5Check(_ command: MemoryExportCommand) throws -> String {
        let queue = try openMemoryStore()
        let headBefore = try queue.read { try MemoryExportStoreReader.auditHead($0) }
        let sourceLiveIDs = try queue.read { try MemoryExportStoreReader.liveMemoryIDs($0) }
        let storeID = try queue.read { try MemoryExportStoreReader.storeIdentity($0) }
        let headAfter = try queue.read { try MemoryExportStoreReader.auditHead($0) }

        // swiftlint:disable:next force_unwrapping reason: validate() refuses p5-check without --target-ids
        let targetPath = command.targetIDs!
        guard let text = try? String(contentsOf: URL(fileURLWithPath: targetPath), encoding: .utf8) else {
            throw BurnBarCLIError.missingArgument("cannot read the target id set at \(targetPath).")
        }
        let targetLiveIDs = Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false }
        )

        // R6 — the export lane refuses above; this lane refused nothing and
        // seeded every canonical id from the literal `"unknown"`. Same code,
        // same sentence, refused the same way.
        let p5StoreID: String
        do {
            p5StoreID = try MemoryExportP5Check.requireStoreID(storeID)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.storeIdentityAbsent.rawValue): this store carries neither a local `devices` row nor an "
                    + "audit chain, so it has nothing that identifies it from the inside. Every canonical "
                    + "id is seeded from that value, and the p5 check will not invent one."
            )
        }

        let result = MemoryExportP5Check.run(
            gates: MemoryExportP5Gates(
                sourceVersion: BurnBarDaemonVersion.current,
                // swiftlint:disable:next force_unwrapping reason: validate() refuses p5-check without it
                requiredVersion: command.requiredVersion!,
                socketTokenRotated: command.socketTokenRotated,
                memoryWriteCapabilityWithdrawn: command.memoryWriteWithdrawn
            ),
            headBefore: headBefore.seq,
            headAfter: headAfter.seq,
            sourceLiveIDs: sourceLiveIDs,
            targetLiveIDs: targetLiveIDs,
            storeID: p5StoreID
        )
        if command.json {
            return MIFCanonicalJSON.serialize(result.report.json)
        }
        var lines = [
            "audit head:  \(headBefore.seq) -> \(headAfter.seq)"
                + (headBefore.seq == headAfter.seq ? " (quiesced)" : " (A WRITER SURVIVED THE GATES)"),
            "source live: \(sourceLiveIDs.count)",
            "target live: \(targetLiveIDs.count)",
            "decision:    \(result.report.decision.rawValue)"
        ]
        if result.holdReasons.isEmpty == false {
            lines.append("held:        \(result.holdReasons.map(\.rawValue).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
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
                // The key never reaches the SQL text. `validatedKeyForGRDB()`
                // makes injection unreachable in practice, but a quote in the
                // key would break the open with a confusing SQL error on a path
                // that is otherwise carefully defensive — and a read-only export
                // is the last place to hand-build a statement (review F-19).
                try db.execute(sql: "PRAGMA key = ?", arguments: [key])
            }
        }
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    // MARK: - Keys

    /// `validate()` has already refused an export with neither `--recipient`
    /// nor `--rehearsal`, so the throwaway branch is reachable only under
    /// rehearsal — and on a release build it does not exist at all.
    private static func resolveRecipient(_ command: MemoryExportCommand) throws -> MemoryExportRecipient {
        if let path = command.recipient { return try loadRecipient(path) }
        #if DEBUG
        return MemoryExportRecipient.rehearsalThrowaway()
        #else
        throw BurnBarCLIError.missingArgument(
            "\(MIFExportError.recipientRequired.rawValue): memory export needs --recipient <descriptor.json>."
        )
        #endif
    }

    /// The importer publishes this with `memoryctl memory export-recipient`. It
    /// is a P0 prerequisite gated by nothing: a bundle cannot be produced
    /// without it, and `MemoryExportCommand.validate()` now enforces what this
    /// comment used to only claim.
    ///
    /// D-0025 ruling 2 makes it a three-field descriptor rather than a bare
    /// key, because a key alone cannot say which store it belongs to. The id is
    /// recomputed from the key, so a descriptor whose id was edited to look like
    /// somebody else's is refused rather than used to address a bundle.
    static func loadRecipient(_ path: String) throws -> MemoryExportRecipient {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.recipientUnverified.rawValue): no recipient descriptor at \(path)."
            )
        }
        do {
            return try MemoryExportRecipient.parse(descriptor: raw)
        } catch MemoryExportRecipient.DescriptorError.keyIDMismatch(let declared, let recomputed) {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.recipientUnverified.rawValue): the descriptor declares "
                    + "recipient_key_id \(declared), but its public_key hashes to \(recomputed)."
            )
        } catch MemoryExportRecipient.DescriptorError.malformed(let reason) {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.recipientUnverified.rawValue): \(reason). --recipient takes the "
                    + "JSON descriptor `memoryctl memory export-recipient` prints."
            )
        }
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
        // §2 review rec 5: showing the recipient is what makes a substituted
        // --recipient descriptor VISIBLE rather than merely honoured.
        if let keyID = report.recipientKeyID {
            lines.append("sealed to:   \(keyID)")
        }
        if let storeID = report.recipientStoreID {
            lines.append("target store:\(storeID)")
        }
        if report.recipientIsRehearsalThrowaway {
            lines.append("             ^ a REHEARSAL throwaway: no store can open this bundle")
        }
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
