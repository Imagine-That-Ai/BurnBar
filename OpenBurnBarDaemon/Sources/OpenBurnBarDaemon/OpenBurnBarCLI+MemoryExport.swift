// SPDX-License-Identifier: AGPL-3.0-only
//
// OpenBurnBarCLI+MemoryExport — `openburnbar-cli memory <verb>`, release BB-E.
//
// One `case "memory"` with the verbs `export | export-status | verify |
// p5-check`. The parsing and the engine both live in
// `OpenBurnBarCore/Sources/OpenBurnBarMemoryExport` so the CLI is a thin shell
// over the same code a future in-app action would call — today the command is
// the only shipped caller (review #2564).
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

    verify --bundle DIR [--recipient PATH] [--signing-key PATH]
      Checks the signature, the manifest's self-consistency and the section
      files on disk. It cannot check the plaintext: the bundle key is wrapped to
      the recipient and never kept here.
      --signing-key points at an `exporter-signing-key.json` descriptor — the
      public half the export writes BESIDE the bundle. Without the flag the
      adjacent descriptor is tried first, then this device's own key.

    p5-check --target-ids FILE --target-digests FILE --required-version X.Y.Z
             [--socket-token-rotated] [--memory-write-withdrawn]
      Reads audit_head either side of the source's live id set and diffs that
      set against the target's — ids, and the per-row
      sha256(UTF-8(normalize(body))) digests in --target-digests (one
      `memory_id digest` pair per line). The two gate flags are operator
      assertions and default to false, so an unasserted gate holds.
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
        // The signing key the bundle's `manifest.sig` and the importer's TOFU
        // pin hang on: presence, where it lives, and the `edk_` id a first
        // import will be asked to confirm.
        let signingKey: String
        if let key = try? Self.loadSigningKey() {
            signingKey = "present (\(MemoryExportCrypto.deviceKeyID(key.publicKey))) at "
                + Self.signingKeyLocation()
        } else {
            signingKey = Self.signingKeyLocation()
        }
        return """
        store:            \(path)
        present:          \(present)
        encrypted:        \(encrypted)
        codec available:  \(BurnBarDaemonDatabaseCipher.isCipherAvailable())
        key resolvable:   \(BurnBarDaemonDatabaseCipher.validatedKeyForGRDB() != nil)
        signing key:      \(signingKey)
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
            signingKey: try Self.loadOrProvisionSigningKey(),
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
        // `--deterministic-nonces` swaps the RANDOM bundle key for a seeded one
        // — the segment nonces are derived from it, so a fixed key is what makes
        // two runs byte-identical. The flag and this branch are DEBUG-only
        // (validate() refuses it outright in a release build, so on release the
        // random arm is unconditional).
        let bundleKey: SymmetricKey
        #if DEBUG
        bundleKey = command.deterministicNonces
            ? MemoryExportCrypto.deterministicBundleKey(seed: storeID)
            : MemoryExportCrypto.randomBundleKey()
        #else
        bundleKey = MemoryExportCrypto.randomBundleKey()
        #endif
        let result = try exporter.export(
            snapshot,
            mode: command.mode,
            to: command.out.map { URL(fileURLWithPath: $0) },
            bundleKey: bundleKey
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
        // reason: validate() refuses recipient-keypair without --out
        // swiftlint:disable:next force_unwrapping
        let directory = URL(fileURLWithPath: command.out!)
        let keypair = try MemoryExportRecipient.generateKeypair(storeID: command.storeID)
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
        // reason: validate() refuses verify without --bundle
        // swiftlint:disable:next force_unwrapping
        let url = URL(fileURLWithPath: command.bundle!)

        // The key the signature verifies against, in precedence order:
        //   1. `--signing-key FILE` — the descriptor the operator carried over;
        //   2. `exporter-signing-key.json` BESIDE the bundle — the file the
        //      export writes there, which is what lets a bundle verify with no
        //      key material on this machine at all (review #2564);
        //   3. this device's own provisioned key — the right answer when the
        //      bundle was signed here.
        // Whatever wins is cross-checked against the signed manifest's
        // `exporter_device_key_id`: a descriptor or local key naming a
        // different `edk_` is a finding, not a shrug.
        let verificationKey = try Self.resolveVerificationKey(command: command, bundle: url)
        var verification = try MemoryExportBundleVerifier.verify(
            bundleAt: url,
            signingPublicKey: verificationKey?.publicKey,
            recipient: try command.recipient.map(Self.loadRecipient)
        )
        if let key = verificationKey {
            verification.checksRun.append("signing key ← \(key.origin)")
            if let declared = verification.manifestExporterDeviceKeyID, declared != key.keyID {
                verification.problems.append(
                    "manifest's exporter_device_key_id \(declared) is not the \(key.origin) key \(key.keyID)"
                )
                verification.signatureVerified = false
            }
        }
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

        // reason: validate() refuses p5-check without --target-ids
        // swiftlint:disable:next force_unwrapping
        let targetPath = command.targetIDs!
        guard let text = try? String(contentsOf: URL(fileURLWithPath: targetPath), encoding: .utf8) else {
            throw BurnBarCLIError.missingArgument("cannot read the target id set at \(targetPath).")
        }
        let targetLiveIDs = Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.isEmpty == false }
        )

        // Step 3's second leg: `memory_id digest` pairs, one per line, where
        // the digest is `sha256(UTF-8(normalize(body)))` — the unkeyed recipe
        // both stores can compute over their own rows (the bundle's keyed
        // `body_norm_digest` died with the discarded bundle key).
        // reason: validate() refuses p5-check without --target-digests
        // swiftlint:disable:next force_unwrapping
        let digestPath = command.targetDigests!
        guard let digestText = try? String(
            contentsOf: URL(fileURLWithPath: digestPath),
            encoding: .utf8
        ) else {
            throw BurnBarCLIError.missingArgument(
                "cannot read the target digest map at \(digestPath)."
            )
        }
        var targetDigests: [String: String] = [:]
        for line in digestText.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2 else {
                throw BurnBarCLIError.missingArgument(
                    "target digests at \(digestPath) carry `memory_id digest` pairs, one per line."
                )
            }
            targetDigests[String(parts[0])] = String(parts[1])
        }
        let sourceDigests = try queue.read { try MemoryExportStoreReader.liveMemoryDigests($0) }

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

        // The diff is between two CANONICAL id spaces. The importer's live-id
        // set is `mem_<32 hex>` — but the source's app-lane rows carry raw
        // UUID ids that the bundle canonicalises at export (D-BB-E-1), so a
        // raw-vs-canonical subtract reports every app-lane row as
        // `only_in_source` and holds a healthy migration (review #2564).
        // Canonicalise the source side with the same store id the bundle used.
        let canonicalSourceIDs = Set(sourceLiveIDs.map {
            MemoryExportIdentity.canonicalMemoryID($0, storeID: p5StoreID)
        })
        // The digest map lives in the same canonical space: a raw UUID id on
        // this side is `mem_<hex>` on the other, exactly as the id set is.
        let canonicalSourceDigests = Dictionary(
            uniqueKeysWithValues: sourceDigests.map { id, digest in
                (MemoryExportIdentity.canonicalMemoryID(id, storeID: p5StoreID), digest)
            }
        )
        let digestMismatch = Set(canonicalSourceDigests.compactMap { id, digest -> String? in
            guard let target = targetDigests[id] else { return nil }
            return target == digest ? nil : id
        })

        let result = MemoryExportP5Check.run(
            gates: MemoryExportP5Gates(
                sourceVersion: BurnBarDaemonVersion.current,
                // reason: validate() refuses p5-check without it
                // swiftlint:disable:next force_unwrapping
                requiredVersion: command.requiredVersion!,
                socketTokenRotated: command.socketTokenRotated,
                memoryWriteCapabilityWithdrawn: command.memoryWriteWithdrawn
            ),
            headBefore: headBefore.seq,
            headAfter: headAfter.seq,
            sourceLiveIDs: canonicalSourceIDs,
            targetLiveIDs: targetLiveIDs,
            digestMismatch: digestMismatch,
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
    /// The key `verify` checks `manifest.sig` against, with where it came
    /// from — `--signing-key` first, then the descriptor the export writes
    /// beside every signed bundle, then this device's own provisioned key.
    /// A descriptor that fails to parse fails the verification with its
    /// reason rather than silently falling through to a different key.
    private static func resolveVerificationKey(
        command: MemoryExportCommand,
        bundle url: URL
    ) throws -> (publicKey: Curve25519.Signing.PublicKey, keyID: String, origin: String)? {
        if let path = command.signingKeyPath {
            let descriptorURL = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: descriptorURL) else {
                throw BurnBarCLIError.missingArgument(
                    "cannot read the signing-key descriptor at \(path)."
                )
            }
            let descriptor = try MemoryExportSigningKeyDescriptor.parse(descriptor: data)
            return (descriptor.publicKey, descriptor.keyID, "--signing-key \(path)")
        }
        let beside = url.deletingLastPathComponent()
            .appendingPathComponent("exporter-signing-key.json")
        if let data = try? Data(contentsOf: beside),
           let descriptor = try? MemoryExportSigningKeyDescriptor.parse(descriptor: data) {
            return (descriptor.publicKey, descriptor.keyID, beside.path)
        }
        if let local = try? loadSigningKey() {
            return (local.publicKey, MemoryExportCrypto.deviceKeyID(local.publicKey), "this device's key")
        }
        return nil
    }

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

    /// `com.openburnbar.memory-export` / `export-signing-key-v1` — the
    /// service/account pair the contract names, `WhenUnlockedThisDeviceOnly`
    /// on macOS; a `0600` file under the daemon's support dir on Linux and
    /// wherever Keychain is unavailable (review #2564: nothing used to create
    /// the key, so every real export died `EXPORT_KEY_UNAVAILABLE`).
    ///
    /// The support-dir file is still READ on every platform — installs from
    /// before the Keychain store carry the key there and the format has not
    /// changed — but a key this build MINTS lands where the contract says.
    private static let signingKeychainService = "com.openburnbar.memory-export"
    private static let signingKeychainAccount = "export-signing-key-v1"

    /// The test seam: `OPENBURNBAR_EXPORT_SIGNING_KEYCHAIN_DISABLED=1` forces
    /// the file store so a test never writes a throwaway key into the real
    /// login Keychain.
    private static var signingKeychainDisabled: Bool {
        ProcessInfo.processInfo.environment["OPENBURNBAR_EXPORT_SIGNING_KEYCHAIN_DISABLED"] == "1"
    }

    static var signingKeyFileURL: URL {
        BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("memory-export-signing-key-v1")
    }

    /// Read-only. `verify` tolerates absent (`try?` at the call site); the
    /// export path calls `loadOrProvisionSigningKey` instead, because a fresh
    /// install has no key and refusing to mint one made the verb unreachable.
    static func loadSigningKey() throws -> Curve25519.Signing.PrivateKey {
        guard let raw = signingKeyMaterial() else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.keyUnavailable.rawValue): no export signing key for this device. "
                    + "Any `memory export` provisions one (Keychain on macOS, a 0600 file under the "
                    + "daemon's support dir on Linux)."
            )
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    /// First-use provisioning: mint the Ed25519 key, store it at
    /// Keychain-class protection where the contract names it, and return it.
    /// The mint is idempotent across processes — a second exporter reads what
    /// the first stored; two racing mints converge because the file write is
    /// create-only (the loser re-reads) and the Keychain add fails benignly.
    static func loadOrProvisionSigningKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = signingKeyMaterial() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let minted = Curve25519.Signing.PrivateKey()
        let raw = minted.rawRepresentation
        if storeSigningKeyInKeychain(raw) == false {
            try storeSigningKeyInFile(raw)
        }
        // Re-read rather than returning the minted bytes: if a racer won the
        // store, the surviving key is theirs and both halves of the device
        // must sign under ONE identity — the pinned `edk_` is that identity.
        guard let stored = signingKeyMaterial() else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.keyUnavailable.rawValue): provisioned a signing key but could not "
                    + "read it back from either store."
            )
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
    }

    /// The raw 32 key bytes wherever they live, or nil.
    private static func signingKeyMaterial() -> Data? {
        if let raw = readSigningKeyFromKeychain() {
            return raw
        }
        guard let raw = try? Data(contentsOf: signingKeyFileURL), raw.count == 32 else {
            return nil
        }
        return raw
    }

    /// Where the key material resolves to, for `export-status`: the operator
    /// needs to know WHICH store the first import's TOFU pin will trust.
    static func signingKeyLocation() -> String {
        if readSigningKeyFromKeychain() != nil {
            return "keychain \(signingKeychainService)/\(signingKeychainAccount)"
        }
        if let raw = try? Data(contentsOf: signingKeyFileURL), raw.count == 32 {
            return "file \(signingKeyFileURL.path) (0600)"
        }
        return "absent (provisioned on first export)"
    }

#if canImport(Security)
    private static func readSigningKeyFromKeychain() -> Data? {
        guard signingKeychainDisabled == false else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: signingKeychainService,
            kSecAttrAccount as String: signingKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            return nil
        }
        return data
    }

    private static func storeSigningKeyInKeychain(_ raw: Data) -> Bool {
        guard signingKeychainDisabled == false else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: signingKeychainService,
            kSecAttrAccount as String: signingKeychainAccount,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = withKeychainUserInteractionDisabled {
            SecItemAdd(query as CFDictionary, nil)
        }
        // errSecDuplicateItem means a racer won — the surviving key is the
        // one to sign under, which the re-read above resolves.
        return status == errSecSuccess || status == errSecDuplicateItem
    }
#else
    private static func readSigningKeyFromKeychain() -> Data? { nil }

    private static func storeSigningKeyInKeychain(_ raw: Data) -> Bool { false }
#endif

    /// The Linux and fallback store: create-only at 0600 — an existing file
    /// is the surviving key, never overwritten, because a re-mint would fork
    /// the device identity every importer pinned.
    private static func storeSigningKeyInFile(_ raw: Data) throws {
        let url = signingKeyFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: raw,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BurnBarCLIError.missingArgument(
                "\(MIFExportError.keyUnavailable.rawValue): could not create \(url.path) at 0600."
            )
        }
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
            if let keyID = report.exporterDeviceKeyID {
                // The importer's TOFU pin needs this file; name it, or it is
                // discoverable only by reading this code.
                lines.append(
                    "signed by:   \(keyID) (public half: exporter-signing-key.json beside the bundle)"
                )
            }
        } else {
            lines.append("dry run:     nothing written (\(result.wouldWriteBytes) bytes would be)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
