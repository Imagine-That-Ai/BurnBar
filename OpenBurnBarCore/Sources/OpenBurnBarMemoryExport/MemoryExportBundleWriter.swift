// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBundleWriter — the on-disk MIF v1 `migration` bundle.
//
//   <bundle>/  manifest.json            plaintext, JCS, no bodies, no per-row digests
//              manifest.sig             Ed25519 over sha256(manifest.json)
//              keys/wrapped-bundle-key  content key wrapped to the recipient
//              hashtree.json            per-section subroots + root, keyed, over CIPHERTEXT
//              sections/<NN-name>/      NDJSON, sealed
//              lost.csv                 every row whose body could not be reconstructed
//              id-map.csv               every rewritten memory_id (deviation D-BB-E-1)
//              report.json              §10, phase "export"
//
// A body is read into memory, canonicalised and written straight into the
// encrypted stream: **no plaintext file is ever created**.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One section's accumulated records, before sealing.
public struct MemoryExportSectionBuffer: Sendable {
    public var section: MIFSection
    public var records: [MIFJSON] = []
    /// `(id, digest)` pairs the roll-up is taken over. Never emitted per row.
    public var rollupTuples: [[String]] = []

    public init(section: MIFSection) { self.section = section }

    public mutating func append(_ record: MIFJSON, rollup: [String]? = nil) {
        records.append(record)
        if let rollup { rollupTuples.append(rollup) }
    }
}

public struct MemoryExportBundleInputs: Sendable {
    public var sections: [MIFSection: MemoryExportSectionBuffer]
    public var report: MemoryExportReport
    public var context: MemoryExportRecordContext
    public var lostRecords: [(memoryID: String, createdAtMS: Int, tags: [String], reason: String)]
    public var idMappings: [MemoryExportIDMapping]
    /// D-0025 ruling 3: NOT optional. A sealed bundle whose content key exists
    /// nowhere is worse than no bundle — the operator is told "written to: …"
    /// and nobody can ever open it — so the type refuses to represent one.
    public var recipient: MemoryExportRecipient
    public var signingKey: Curve25519.Signing.PrivateKey?
    public var exportMode: String
    public var sinceAuditSeq: Int?
    public var deltaWatermarks: [String: Int]
    public var carriesHumanOrigin: Bool
    public var rehearsal: Bool
    public var createdAtMS: Int
    public var maxSectionBytes: Int
}

public struct MemoryExportBundleResult: Sendable {
    public var bundleURL: URL?
    public var bundleID: String
    public var contentDigest: String
    /// The manifest with `created_at_ms`, the recipient fields and the signature
    /// blanked. §2 claims determinism on exactly this, so exactly this is what
    /// the determinism test compares.
    public var determinismDigest: String
    public var report: MemoryExportReport
    public var wouldWriteBytes: Int
    /// The records exactly as they were serialised. Carried so a caller — the
    /// schema-validation test above all — can check what actually went into the
    /// sealed segments without decrypting them first.
    public var sectionBuffers: [MIFSection: MemoryExportSectionBuffer]
}

public enum MemoryExportBundleWriter {

    /// Build every artefact in memory, then (unless `dryRun`) write it.
    ///
    /// Dry-run performs every classification and dereference and writes no
    /// bundle, so on an unchanged source it must produce byte-identical counts
    /// and findings to the real run — a door property, which is only true
    /// because both paths run this same function.
    public static func build(
        _ inputs: MemoryExportBundleInputs,
        writingTo destination: URL?,
        dryRun: Bool
    ) throws -> MemoryExportBundleResult {
        var report = inputs.report
        let ordered = MIFSection.allCases.map { inputs.sections[$0] ?? MemoryExportSectionBuffer(section: $0) }

        // 1. Serialise each section to NDJSON, sorted byte-ascending on its
        //    declared sort key.
        var plaintexts: [MIFSection: Data] = [:]
        for buffer in ordered {
            plaintexts[buffer.section] = ndjson(buffer)
        }

        // 2. Seal, and build the keyed tree over the CIPHERTEXT so a section can
        //    be verified before it is decrypted.
        var ciphertexts: [MIFSection: Data] = [:]
        var subroots: [MIFSection: String] = [:]
        for buffer in ordered {
            // swiftlint:disable:next force_unwrapping reason: every section was written above
            let plaintext = plaintexts[buffer.section]!
            let key = MemoryExportCrypto.segmentKey(bundleKey: inputs.context.bundleKey, section: buffer.section)
            var sealed = Data()
            for (index, chunk) in MemoryExportCrypto
                .chunks(of: plaintext, size: inputs.maxSectionBytes)
                .enumerated() {
                sealed.append(try MemoryExportCrypto.seal(
                    chunk: chunk,
                    section: buffer.section,
                    segmentKey: key,
                    index: index
                ))
            }
            ciphertexts[buffer.section] = sealed
            subroots[buffer.section] = MemoryExportCrypto.hashTreeRoot(
                bundleKey: inputs.context.bundleKey,
                ciphertext: sealed
            )
        }

        // 3. `content_digest` is over the PLAINTEXT section digests, which is
        //    what makes it stable across two exports whose ciphertext differs.
        let contentDigest = MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(.object(
            Dictionary(uniqueKeysWithValues: ordered.map { buffer in
                // swiftlint:disable:next force_unwrapping reason: every section was written above
                (buffer.section.rawValue, MIFJSON.string(MemoryExportDigest.sha256Hex(plaintexts[buffer.section]!)))
            })
        )))
        let bundleID = MemoryExportIdentity.bundleID(contentDigest: contentDigest)

        // 4. Wrap the content key and sign.
        let wrapped = try MemoryExportCrypto.wrap(
            bundleKey: inputs.context.bundleKey,
            recipient: inputs.recipient
        )
        let deviceKeyID = inputs.signingKey.map { MemoryExportCrypto.deviceKeyID($0.publicKey) }

        report.bundleID = bundleID
        report.contentDigest = contentDigest
        report.exporterDeviceKeyID = deviceKeyID
        report.rehearsal = inputs.rehearsal

        let manifest = manifestJSON(
            inputs: inputs,
            bundleID: bundleID,
            contentDigest: contentDigest,
            sections: ordered,
            subroots: subroots,
            ciphertexts: ciphertexts,
            deviceKeyID: deviceKeyID,
            findingsSummary: report.findings
        )
        let manifestData = MIFCanonicalJSON.data(manifest)
        let determinismDigest = MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(
            stripVolatile(manifest)
        ))

        let lostCSV = lostCSVText(inputs.lostRecords)
        let idMapCSV = idMapCSVText(inputs.idMappings)
        var wouldWrite = manifestData.count + lostCSV.utf8.count + idMapCSV.utf8.count
        for data in ciphertexts.values { wouldWrite += data.count }

        report.wouldWriteBytes = wouldWrite
        if inputs.lostRecords.isEmpty == false {
            report.lostCSVPath = destination.map { $0.appendingPathComponent("lost.csv").path } ?? "lost.csv"
        }
        let reportData = MIFCanonicalJSON.data(report.json)

        guard dryRun == false, let destination else {
            return MemoryExportBundleResult(
                bundleURL: nil,
                bundleID: bundleID,
                contentDigest: contentDigest,
                determinismDigest: determinismDigest,
                report: report,
                wouldWriteBytes: wouldWrite,
                sectionBuffers: inputs.sections
            )
        }

        try write(
            destination: destination,
            manifestData: manifestData,
            signature: try inputs.signingKey.map {
                try MemoryExportCrypto.sign(manifestBytes: manifestData, signingKey: $0)
            },
            wrapped: wrapped,
            ciphertexts: ciphertexts,
            subroots: subroots,
            ordered: ordered,
            bundleKey: inputs.context.bundleKey,
            lostCSV: lostCSV,
            idMapCSV: idMapCSV,
            reportData: reportData
        )
        return MemoryExportBundleResult(
            bundleURL: destination,
            bundleID: bundleID,
            contentDigest: contentDigest,
            determinismDigest: determinismDigest,
            report: report,
            wouldWriteBytes: wouldWrite,
            sectionBuffers: inputs.sections
        )
    }

    // MARK: - Sections

    /// NDJSON, one canonical record per line, sorted byte-ascending on the
    /// section's declared sort key so two exports of one store agree line for
    /// line.
    static func ndjson(_ buffer: MemoryExportSectionBuffer) -> Data {
        let keys = buffer.section.sortKeys
        var keyed: [(sortKey: String, text: String)] = []
        keyed.reserveCapacity(buffer.records.count)
        for record in buffer.records {
            keyed.append((sortValue(record, keys: keys), MIFCanonicalJSON.serialize(record)))
        }
        keyed.sort { lhs, rhs in
            lhs.sortKey == rhs.sortKey ? lhs.text < rhs.text : lhs.sortKey < rhs.sortKey
        }
        guard keyed.isEmpty == false else { return Data() }
        return Data((keyed.map(\.text).joined(separator: "\n") + "\n").utf8)
    }

    private static func sortValue(_ record: MIFJSON, keys: [String]) -> String {
        guard case .object(let fields) = record else { return "" }
        return keys.map { key in
            switch fields[key] {
            case .string(let value): value
            case .int(let value): String(format: "%020d", value)
            default: ""
            }
        }.joined(separator: "\u{1F}")
    }

    // MARK: - Manifest

    // swiftlint:disable:next function_parameter_count reason: the manifest is a wide record by construction
    static func manifestJSON(
        inputs: MemoryExportBundleInputs,
        bundleID: String,
        contentDigest: String,
        sections: [MemoryExportSectionBuffer],
        subroots: [MIFSection: String],
        ciphertexts: [MIFSection: Data],
        deviceKeyID: String?,
        findingsSummary: [MemoryExportFinding]
    ) -> MIFJSON {
        let headers: [MIFJSON] = sections.map { buffer in
            let ciphertext = ciphertexts[buffer.section] ?? Data()
            var fields: [String: MIFJSON] = [
                "name": .string(buffer.section.rawValue),
                "rank": .int(buffer.section.rank),
                // M-20: 09 is required the moment any record claims human origin.
                "required": .bool(
                    buffer.section.isAlwaysRequired
                        || (buffer.section == .auditEvidence && inputs.carriesHumanOrigin)
                ),
                "mergeable": .bool(buffer.section.isMergeable),
                "row_count": .int(buffer.records.count),
                "record_type": .string(buffer.section.recordTypePointer),
                "subroot": .string(subroots[buffer.section] ?? String(repeating: "0", count: 64)),
                "bytes": .int(ciphertext.count),
                "segments": .int(max(1, MemoryExportCrypto.chunks(of: ciphertext, size: inputs.maxSectionBytes).count))
            ]
            if buffer.rollupTuples.isEmpty == false {
                fields["rollup_digest"] = .string(rollupDigest(buffer.rollupTuples))
            }
            return .object(fields)
        }

        let rollups: [MIFJSON] = sections.compactMap { buffer in
            guard buffer.rollupTuples.isEmpty == false else { return nil }
            return .object([
                "section": .string(buffer.section.rawValue),
                // The declared tuple is what the importer recomputes from, and
                // it HOLDS on `ROLLUP_DIGEST_MISMATCH`. Sections 05 and 06 do
                // not digest the same third value — 05 takes the provenance
                // digest, 06 the body join key — so one hardcoded tuple made
                // every bundle fail on 06 (review F-3).
                "tuple": .strings(buffer.section.rollupTuple),
                "rollup_digest": .string(rollupDigest(buffer.rollupTuples)),
                "row_count": .int(buffer.rollupTuples.count)
            ])
        }

        var summary: [String: MIFJSON] = [:]
        for finding in findingsSummary { summary[finding.code.rawValue] = .int(finding.count) }

        var notExported: [String: MIFJSON] = [:]
        for table in inputs.report.tables {
            for (reason, count) in table.notExported {
                if case .int(let existing) = notExported[reason.rawValue] ?? .int(0) {
                    notExported[reason.rawValue] = .int(existing + count)
                }
            }
        }

        var fields: [String: MIFJSON] = [
            "mif_version": .int(1),
            "mif_minor": .int(2),
            "profile": .string(MIFProfile.migration.rawValue),
            "bundle_id": .string(bundleID),
            "prev_bundle_id": .null,
            "producer_store_id": .string(inputs.context.storeID),
            "producer_device_id": .string(inputs.context.originDeviceID),
            "user_id": .string(inputs.context.userID),
            "created_at_ms": .int(inputs.createdAtMS),
            // A migration bundle has no pairing peer, so the window is empty and
            // ordering comes from `since_audit_seq` and the watermarks.
            "window": .object(["from_lamport": .int(0), "to_lamport": .int(0)]),
            "schema_version": .int(inputs.context.schemaVersion),
            "sections": .array(headers),
            "min_importer_mif_version": .int(1),
            "content_digest": .string(contentDigest),
            "hashtree": .object([
                "alg": .string("hmac-sha256"),
                "over": .string("ciphertext"),
                "chunk_bytes": .int(MemoryExportCrypto.hashTreeChunkBytes),
                "root": .string(MemoryExportCrypto.combineSubroots(
                    bundleKey: inputs.context.bundleKey,
                    subroots: MIFSection.allCases.map { subroots[$0] ?? "" }
                )),
                "key_derivation": .string("HKDF(bundle_key,'mif1/hashtree/v1')")
            ]),
            "determinism": .object([
                "canonicalization": .string("JCS"),
                "sort_keys": .object(Dictionary(uniqueKeysWithValues: MIFSection.allCases.map {
                    ($0.rawValue, MIFJSON.strings($0.sortKeys))
                }))
            ]),
            "rehearsal": .bool(inputs.rehearsal),
            // §2.1 ruling 4: the manifest declares what sealed the bundle, so a
            // CryptoKit exporter and a Rust importer can both be correct.
            // `wrap` and `key_schedule` are `const` in the contract — that is
            // the schema deliberately refusing to let a hand-rolled wrap be
            // negotiated, and this object is only emittable because the wrap
            // above is RFC 9180.
            "crypto": .object([
                "aead": .string(MemoryExportCrypto.aead),
                "compression": .string(MemoryExportCrypto.compression),
                "wrap": .string(MemoryExportCrypto.wrapName),
                "key_schedule": .string(MemoryExportCrypto.keyScheduleName)
            ]),
            "recipient_key_id": .string(inputs.recipient.manifestKeyID),
            // The TARGET store's fingerprint, from the recipient descriptor —
            // not the producer's, which is `source.store_fingerprint` below.
            // An importer asks "is this bundle addressed to me?" here.
            "recipient_store_id": .string(inputs.recipient.storeID),
            "exporter_device_key_id": .string(deviceKeyID),
            "export_mode": .string(inputs.exportMode),
            "since_audit_seq": .int(inputs.sinceAuditSeq),
            "delta_watermarks": .object(inputs.deltaWatermarks.mapValues { MIFJSON.int($0) }),
            "snapshot_mode": .string(inputs.report.snapshotMode.rawValue),
            "source": .object([
                "product": .string(inputs.report.sourceProduct),
                "version": .string(inputs.report.sourceVersion),
                "build_kind": .string(inputs.rehearsal ? "rehearsal_fixture" : "xcode_app_bundle"),
                "store_kind": .string(inputs.report.sourceStoreKind.rawValue),
                "store_fingerprint": .string(inputs.report.sourceStoreFingerprint),
                "platform": .string(platform),
                "keyed": .bool(inputs.report.sourceStoreKind == .authority),
                "cipher_version": .null,
                "schema_variant": .object([:]),
                "support_root_overridden": .bool(false)
            ]),
            "source_integrity": .string(inputs.report.sourceIntegrityOK ? "ok" : "failed"),
            "concurrent_writes": .bool(inputs.report.concurrentWrites),
            "partial_sources": .array(inputs.report.partialSources.map {
                .object(["source": .string($0.source), "reason": .string($0.reason)])
            }),
            "not_exported": .object(notExported),
            "findings_summary": .object(summary),
            "rollups": .array(rollups)
        ]
        if inputs.exportMode == "full" { fields["since_audit_seq"] = .null }
        return .object(fields)
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(iOS)
        "ios"
        #elseif os(Linux)
        "linux"
        #elseif os(Windows)
        "windows"
        #else
        "macos"
        #endif
    }

    /// M-19: counts cannot catch a body attached to the wrong id. One digest per
    /// section over the sorted `(id, digest)` list; never the per-row values, so
    /// nothing leaks. A hand-edited bundle with two bodies swapped balances
    /// every count and still fails here.
    static func rollupDigest(_ tuples: [[String]]) -> String {
        let joined = tuples
            .map { $0.joined(separator: "\u{1F}") }
            .sorted()
            .joined(separator: "\n")
        return MemoryExportDigest.sha256Hex(joined)
    }

    /// Determinism is claimed on the manifest MINUS these fields, so this is
    /// what the property test compares.
    static func stripVolatile(_ manifest: MIFJSON) -> MIFJSON {
        guard case .object(var fields) = manifest else { return manifest }
        fields["created_at_ms"] = .null
        fields["recipient_key_id"] = .null
        fields["exporter_device_key_id"] = .null
        // `recipient_store_id` is NOT blanked. §2's determinism claim excludes
        // exactly `{created_at_ms, recipient_key_id, wrapped key, signature}`,
        // and blanking a deterministic field here is how the source-fingerprint
        // bug it used to hold survived a determinism test (review F-9).
        // The tree is keyed by the per-export bundle key, so its root moves even
        // when every plaintext byte is identical.
        fields["hashtree"] = .null
        if case .array(let sections) = fields["sections"] ?? .null {
            fields["sections"] = .array(sections.map { section in
                guard case .object(var header) = section else { return section }
                header["subroot"] = .null
                header["bytes"] = .null
                return .object(header)
            })
        }
        return .object(fields)
    }

    // MARK: - Sidecars

    static func lostCSVText(_ rows: [(memoryID: String, createdAtMS: Int, tags: [String], reason: String)]) -> String {
        var lines = ["memory_id,created_at_ms,tags,reason_detail"]
        for row in rows.sorted(by: { $0.memoryID < $1.memoryID }) {
            lines.append([
                csvField(row.memoryID),
                String(row.createdAtMS),
                csvField(row.tags.sorted().joined(separator: " ")),
                csvField(row.reason)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func idMapCSVText(_ mappings: [MemoryExportIDMapping]) -> String {
        var lines = ["source_memory_id,bundle_memory_id"]
        for mapping in mappings.sorted(by: { $0.sourceID < $1.sourceID }) {
            lines.append("\(csvField(mapping.sourceID)),\(csvField(mapping.bundleID))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Disk

    // swiftlint:disable:next function_parameter_count reason: writing the bundle is writing its parts
    private static func write(
        destination: URL,
        manifestData: Data,
        signature: Data?,
        wrapped: MemoryExportCrypto.WrappedBundleKey,
        ciphertexts: [MIFSection: Data],
        subroots: [MIFSection: String],
        ordered: [MemoryExportSectionBuffer],
        bundleKey: SymmetricKey,
        lostCSV: String,
        idMapCSV: String,
        reportData: Data
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try manifestData.write(to: destination.appendingPathComponent("manifest.json"))
        try reportData.write(to: destination.appendingPathComponent("report.json"))
        try Data(lostCSV.utf8).write(to: destination.appendingPathComponent("lost.csv"))
        try Data(idMapCSV.utf8).write(to: destination.appendingPathComponent("id-map.csv"))

        if let signature {
            try signature.write(to: destination.appendingPathComponent("manifest.sig"))
        }
        let keys = destination.appendingPathComponent("keys")
        try manager.createDirectory(at: keys, withIntermediateDirectories: true)
        // §2.1: `b64url(enc) ‖ "." ‖ b64url(ct)`, both unpadded. A raw
        // concatenation is unreadable by anything but its own writer.
        try Data(wrapped.wireForm.utf8).write(to: keys.appendingPathComponent("wrapped-bundle-key"))

        let tree = MIFJSON.object([
            "root": .string(MemoryExportCrypto.combineSubroots(
                bundleKey: bundleKey,
                subroots: MIFSection.allCases.map { subroots[$0] ?? "" }
            )),
            "sections": .object(Dictionary(uniqueKeysWithValues: ordered.map {
                ($0.section.rawValue, MIFJSON.string(subroots[$0.section] ?? ""))
            }))
        ])
        try MIFCanonicalJSON.data(tree).write(to: destination.appendingPathComponent("hashtree.json"))

        let sections = destination.appendingPathComponent("sections")
        try manager.createDirectory(at: sections, withIntermediateDirectories: true)
        for buffer in ordered {
            let directory = sections.appendingPathComponent(buffer.section.rawValue)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try (ciphertexts[buffer.section] ?? Data())
                .write(to: directory.appendingPathComponent("000.ndjson.seal"))
        }
    }
}
