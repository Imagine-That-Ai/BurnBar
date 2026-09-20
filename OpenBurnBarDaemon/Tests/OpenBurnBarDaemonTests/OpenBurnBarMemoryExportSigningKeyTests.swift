// SPDX-License-Identifier: AGPL-3.0-only
//
// OpenBurnBarMemoryExportSigningKeyTests — review #2564's two key findings:
// first-use provisioning (nothing used to create the signing key, so every
// real export died `EXPORT_KEY_UNAVAILABLE`) and the out-of-band verification
// key (the bundle carries only `edk_…`; the descriptor beside it is the TOFU
// handoff the importer pins).

import Foundation
import GRDB
import XCTest
@testable import OpenBurnBarDaemon
@testable import OpenBurnBarMemoryExport

final class OpenBurnBarMemoryExportSigningKeyTests: XCTestCase {

    private var supportDir: URL!
    private var previousSupportDir: String?

    override func setUpWithError() throws {
        // The file store, never the real login Keychain: a test that mints a
        // throwaway key into `com.openburnbar.memory-export` would pollute the
        // host's keychain and, worse, could read a REAL key and sign under it.
        previousSupportDir = ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_SUPPORT_DIR"]
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mif-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        setenv("OPENBURNBAR_DAEMON_SUPPORT_DIR", supportDir.path, 1)
        setenv("OPENBURNBAR_EXPORT_SIGNING_KEYCHAIN_DISABLED", "1", 1)
    }

    override func tearDownWithError() throws {
        if let previousSupportDir {
            setenv("OPENBURNBAR_DAEMON_SUPPORT_DIR", previousSupportDir, 1)
        } else {
            unsetenv("OPENBURNBAR_DAEMON_SUPPORT_DIR")
        }
        unsetenv("OPENBURNBAR_EXPORT_SIGNING_KEYCHAIN_DISABLED")
        try? FileManager.default.removeItem(at: supportDir)
    }

    // MARK: - Provisioning (F1)

    /// The refusal was honest but unreachable: no code path created the key.
    /// First use mints it at 0600 under the daemon support dir (Keychain on a
    /// macOS build outside this seam), and the SECOND export reads back the
    /// SAME key — the device identity must not re-mint.
    func test_aFreshSupportDirProvisionsTheSigningKeyOnce() throws {
        let keyFile = BurnBarCLIRunner.signingKeyFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
        XCTAssertThrowsError(
            try BurnBarCLIRunner.loadSigningKey(),
            "read-only load still refuses an absent key — `verify` must not mint"
        )

        let first = try BurnBarCLIRunner.loadOrProvisionSigningKey()
        let second = try BurnBarCLIRunner.loadOrProvisionSigningKey()
        XCTAssertEqual(
            first.rawRepresentation, second.rawRepresentation,
            "provisioning is idempotent: the pinned edk_ survives a second export"
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        XCTAssertEqual(
            attributes[.posixPermissions] as? Int, 0o600,
            "the file store is owner-only, per the contract"
        )
        XCTAssertEqual(try Data(contentsOf: keyFile).count, 32)
        XCTAssertTrue(
            BurnBarCLIRunner.signingKeyLocation().contains("0600"),
            "export-status names where the key lives"
        )
    }

    // MARK: - Descriptor handoff (F2)

    /// End to end at the CLI: a fresh support dir exports a signed bundle, the
    /// descriptor lands beside it, and `verify` — pointed at an EMPTY support
    /// dir, i.e. no key material on this "machine" at all — verifies the
    /// signature off the descriptor alone.
    func test_anExportProvisionsAndTheDescriptorVerifiesOnAKeylessMachine() throws {
        // A minimal store: the reader probes every table and tolerates the
        // absent ones, and the only row the export REQUIRES is the local
        // `devices` identity — the v22 migrator's own shape, recreated here
        // rather than running the full migration chain for one row.
        let storePath = supportDir.appendingPathComponent("openburnbar.sqlite")
        let queue = try DatabaseQueue(path: storePath.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE devices (
                    deviceId TEXT PRIMARY KEY,
                    deviceName TEXT NOT NULL,
                    isLocal INTEGER NOT NULL DEFAULT 0,
                    lastSeenAt TEXT,
                    createdAt TEXT NOT NULL
                )
                """)
            try db.execute(
                sql: "INSERT INTO devices VALUES ('dev-1', 'test mac', 1, NULL, '2026-01-01T00:00:00.000Z')"
            )
        }

        // The recipient descriptor, minted the way the importer publishes one.
        let keypair = try MemoryExportRecipient.generateKeypair(
            storeID: "sto_" + String(repeating: "b", count: 32)
        )
        let recipientPath = supportDir.appendingPathComponent("recipient.json")
        try MIFCanonicalJSON.data(keypair.descriptorJSON).write(to: recipientPath)

        let outDir = supportDir.appendingPathComponent("bundle")
        setenv(MemoryExportFeatureFlag.name, "1", 1)
        defer { unsetenv(MemoryExportFeatureFlag.name) }
        let runner = BurnBarCLIRunner(client: FakeCLIClient())
        let output = try runner.runMemoryCommand([
            "export", "--out", outDir.path,
            "--recipient", recipientPath.path,
            "--snapshot", "read_txn", "--allow-long-read"
        ])
        XCTAssertTrue(output.contains("written to:"), output)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outDir.appendingPathComponent("manifest.sig").path),
            "a signed bundle is the refusal's opposite"
        )

        // The handoff file is BESIDE the bundle — Q-60's closed set refuses it
        // inside — and it parses as the self-authenticating descriptor.
        let descriptorPath = supportDir.appendingPathComponent("exporter-signing-key.json")
        let descriptor = try MemoryExportSigningKeyDescriptor.parse(
            descriptor: Data(contentsOf: descriptorPath)
        )
        let provisioned = try BurnBarCLIRunner.loadSigningKey()
        XCTAssertEqual(
            descriptor.keyID,
            MemoryExportCrypto.deviceKeyID(provisioned.publicKey),
            "the descriptor names the key the export provisioned"
        )

        // The "other machine": move the signing key away so NOTHING local can
        // answer, then verify — the descriptor beside the bundle supplies the
        // public half.
        let keyFile = BurnBarCLIRunner.signingKeyFileURL
        let hidden = supportDir.appendingPathComponent("stashed-key")
        try FileManager.default.moveItem(at: keyFile, to: hidden)
        let verification = try runner.runMemoryCommand(["verify", "--bundle", outDir.path])
        XCTAssertTrue(
            verification.contains("signature:   verified"),
            verification
        )
        XCTAssertTrue(
            verification.contains(descriptorPath.path),
            "the report must name where the verification key came from: \(verification)"
        )
    }

    // MARK: - Deterministic nonces (F7)

    /// The contract's determinism claim is only provable if two runs can share
    /// a key — the flag exists, and this exercises the actual wiring: a fixed
    /// seed fixes the bundle key, so the SEALED segment bytes are identical.
    /// (`manifest.sig` and `keys/wrapped-bundle-key` still vary — CryptoKit
    /// randomizes the signature and HPKE's wrap carries an ephemeral; §2's
    /// determinism claim already excludes both.)
    func test_twoRehearsalExportsUnderOneSeedProduceIdenticalSegments() throws {
        let storePath = supportDir.appendingPathComponent("openburnbar.sqlite")
        let queue = try DatabaseQueue(path: storePath.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE devices (
                    deviceId TEXT PRIMARY KEY, deviceName TEXT NOT NULL,
                    isLocal INTEGER NOT NULL DEFAULT 0,
                    lastSeenAt TEXT, createdAt TEXT NOT NULL
                )
                """)
            try db.execute(
                sql: "INSERT INTO devices VALUES ('dev-1', 'test mac', 1, NULL, '2026-01-01T00:00:00.000Z')"
            )
        }
        setenv(MemoryExportFeatureFlag.name, "1", 1)
        defer { unsetenv(MemoryExportFeatureFlag.name) }
        let runner = BurnBarCLIRunner(client: FakeCLIClient())

        var segmentBytes: [String: Data] = [:]
        for (index, name) in ["first", "second"].enumerated() {
            let outDir = supportDir.appendingPathComponent(name)
            _ = try runner.runMemoryCommand([
                "export", "--out", outDir.path, "--rehearsal",
                "--deterministic-nonces",
                "--snapshot", "read_txn", "--allow-long-read"
            ])
            if index == 0 {
                let sections = outDir.appendingPathComponent("sections")
                let sectionDirs = try FileManager.default.contentsOfDirectory(atPath: sections.path)
                for sectionDir in sectionDirs {
                    let path = sections.appendingPathComponent(sectionDir)
                    for file in try FileManager.default.contentsOfDirectory(atPath: path.path) {
                        segmentBytes["\(sectionDir)/\(file)"] =
                            try Data(contentsOf: path.appendingPathComponent(file))
                    }
                }
            } else {
                let sections = outDir.appendingPathComponent("sections")
                let sectionDirs = try FileManager.default.contentsOfDirectory(atPath: sections.path)
                for sectionDir in sectionDirs {
                    let path = sections.appendingPathComponent(sectionDir)
                    for file in try FileManager.default.contentsOfDirectory(atPath: path.path) {
                        XCTAssertEqual(
                            segmentBytes["\(sectionDir)/\(file)"],
                            try Data(contentsOf: path.appendingPathComponent(file)),
                            "a fixed seed must fix the sealed bytes of \(sectionDir)/\(file)"
                        )
                    }
                }
            }
        }
        XCTAssertFalse(segmentBytes.isEmpty, "both exports must have produced segments")
    }
}
