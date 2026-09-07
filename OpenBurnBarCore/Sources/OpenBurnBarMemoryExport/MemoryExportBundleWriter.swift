// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBundleWriter — the on-disk MIF v1 `migration` bundle.
//
//   <bundle>/  manifest.json            plaintext, JCS, no bodies, no per-row digests
//              manifest.sig             Ed25519 over the 32 raw bytes of content_digest, b64url (D-0031)
//              keys/wrapped-bundle-key  content key wrapped to the recipient
//              hashtree.json            per-section subroots + THE root + unkeyed per-chunk sidecar (R5)
//              sections/<NN-name>/<index:05>.seg   NDJSON, sealed (D-0031)
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
    /// One D-0031 roll-up tuple per row, in the member order the section's
    /// `rollupTuple` declares. Never emitted per row — only the digest travels.
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
        var segments: [MIFSection: [Data]] = [:]
        var subroots: [MIFSection: String] = [:]
        for buffer in ordered {
            // swiftlint:disable:next force_unwrapping reason: every section was written above
            let plaintext = plaintexts[buffer.section]!
            let key = MemoryExportCrypto.segmentKey(bundleKey: inputs.context.bundleKey, section: buffer.section)
            let sealed = try MemoryExportCrypto
                // §2 rotates a section at `max_section_bytes` of CIPHERTEXT, and
                // each sealed segment carries a 12-byte nonce and a 16-byte tag,
                // so the plaintext cut is that much shorter. Getting this
                // backwards writes segments slightly over the declared limit.
                .chunks(of: plaintext, size: max(1, inputs.maxSectionBytes - MemoryExportCrypto.sealOverheadBytes))
                .enumerated()
                .map { index, chunk in
                    try MemoryExportCrypto.seal(
                        chunk: chunk,
                        section: buffer.section,
                        segmentKey: key,
                        index: index
                    )
                }
            segments[buffer.section] = sealed
            subroots[buffer.section] = MemoryExportCrypto.hashTreeRoot(
                bundleKey: inputs.context.bundleKey,
                segments: sealed
            )
        }

        // 3. The hash-tree root, computed ONCE. `manifest.hashtree.root` is
        //    this value, `hashtree.json`'s copy is the same bytes for a verifier
        //    that has not parsed the manifest, and there is no second,
        //    independently computed root (D-0031 ruling 1).
        let hashtreeRoot = MemoryExportCrypto.combineSubroots(
            bundleKey: inputs.context.bundleKey,
            subroots: MIFSection.allCases.map { subroots[$0] ?? "" }
        )

        // 4. `content_digest` is over the PLAINTEXT section digests — which is
        //    what makes it stable across two exports whose ciphertext differs —
        //    AND the hash-tree root, which is what binds the manifest to the
        //    one tree (D-0031 ruling 1: the root is an input to the digest).
        let contentDigest = MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(.object(
            Dictionary(uniqueKeysWithValues: ordered.map { buffer in
                // swiftlint:disable:next force_unwrapping reason: every section was written above
                (buffer.section.rawValue, MIFJSON.string(MemoryExportDigest.sha256Hex(plaintexts[buffer.section]!)))
            })
            .merging(["hashtree_root": .string(hashtreeRoot)]) { _, new in new }
        )))
        let bundleID = MemoryExportIdentity.bundleID(contentDigest: contentDigest)

        // 5. Wrap the content key and sign the raw digest (D-0031).
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
            hashtreeRoot: hashtreeRoot,
            sections: ordered,
            subroots: subroots,
            segments: segments,
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
        for sealed in segments.values { wouldWrite += sealed.reduce(0) { $0 + $1.count } }

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
                try MemoryExportCrypto.sign(contentDigest: contentDigest, signingKey: $0)
            },
            wrapped: wrapped,
            segments: segments,
            subroots: subroots,
            hashtreeRoot: hashtreeRoot,
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
        hashtreeRoot: String,
        sections: [MemoryExportSectionBuffer],
        subroots: [MIFSection: String],
        segments: [MIFSection: [Data]],
        deviceKeyID: String?,
        findingsSummary: [MemoryExportFinding]
    ) -> MIFJSON {
        let headers: [MIFJSON] = sections.map { buffer in
            let sealed = segments[buffer.section] ?? []
            let ciphertextBytes = sealed.reduce(0) { $0 + $1.count }
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
                "bytes": .int(ciphertextBytes),
                // The number of `<index:05>.seg` FILES this section is written
                // as. It used to be the ciphertext re-chunked at
                // `max_section_bytes`, a boundary that corresponded to nothing
                // on disk — every section was one file however large it was
                // (review F-14).
                "segments": .int(max(1, sealed.count))
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
                // D-0031 ruling 1: THE root — the one computation, carried in
                // exactly this one member. `hashtree.json`'s copy is the same
                // bytes, and a bundle whose two roots disagree is rejected.
                "root": .string(hashtreeRoot),
                // The contract's `const`, verbatim — even though it still names
                // the pre-D-0031 unsalted derivation while the key above follows
                // D-0031's prose (salted, §2 HKDF_SALT). Emitting the salted
                // spelling fails this const on both sides, so the const update
                // is a Po'dex-side contract change; flagged for the spec owner
                // in D-BB-E-14 rather than smuggled in here.
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
    /// section over that section's D-0031 roll-up tuple — one tuple per row,
    /// ORDERED BY THE TUPLE'S FIRST MEMBER and digested as the JCS encoding of
    /// the array; never the per-row values anywhere else, so nothing leaks. A
    /// hand-edited bundle with two bodies swapped balances every count and
    /// still fails here.
    static func rollupDigest(_ tuples: [[String]]) -> String {
        let ordered = tuples.sorted { $0.first ?? "" < $1.first ?? "" }
        return MemoryExportDigest.sha256Hex(MIFCanonicalJSON.data(
            .array(ordered.map { .array($0.map(MIFJSON.string)) })
        ))
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
        signature: String?,
        wrapped: MemoryExportCrypto.WrappedBundleKey,
        segments: [MIFSection: [Data]],
        subroots: [MIFSection: String],
        hashtreeRoot: String,
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
            // D-0031 ruling 1: the file is the b64url rendering, not raw
            // signature bytes — like every other binary in the format.
            try Data(signature.utf8).write(to: destination.appendingPathComponent("manifest.sig"))
        }
        let keys = destination.appendingPathComponent("keys")
        try manager.createDirectory(at: keys, withIntermediateDirectories: true)
        // §2.1: `b64url(enc) ‖ "." ‖ b64url(ct)`, both unpadded. A raw
        // concatenation is unreadable by anything but its own writer.
        try Data(wrapped.wireForm.utf8).write(to: keys.appendingPathComponent("wrapped-bundle-key"))

        // D-0031 ruling 1: this copy is the SAME bytes as
        // `manifest.hashtree.root` — passed in, never recomputed.
        let tree = MIFJSON.object([
            "root": .string(hashtreeRoot),
            "sections": .object(Dictionary(uniqueKeysWithValues: ordered.map {
                ($0.section.rawValue, MIFJSON.string(subroots[$0.section] ?? ""))
            })),
            // R5 — one UNKEYED `sha256` per 4 MiB chunk of every segment file,
            // over the ciphertext, so `verify` detects a modified segment
            // without the bundle key. The keyed tree cannot do that: it needs
            // the ephemeral bundle key, which this side never retains. Over
            // ciphertext a plain hash leaks nothing (review R5), and this is
            // an additive sidecar beside the root and subroots — not a second
            // root, so D-0031's "computed once" still holds.
            "segment_sha256": segmentChunkHashes(segments: segments, ordered: ordered)
        ])
        try MIFCanonicalJSON.data(tree).write(to: destination.appendingPathComponent("hashtree.json"))

        let sections = destination.appendingPathComponent("sections")
        try manager.createDirectory(at: sections, withIntermediateDirectories: true)
        for buffer in ordered {
            let directory = sections.appendingPathComponent(buffer.section.rawValue)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // One file per sealed segment. An empty section still writes
            // `00000.seg`, so a reader never has to distinguish "no
            // segments" from "directory not written".
            let sealed = segments[buffer.section] ?? []
            for (index, segment) in (sealed.isEmpty ? [Data()] : sealed).enumerated() {
                try segment.write(to: directory.appendingPathComponent(Self.segmentFilename(index)))
            }
        }
    }

    /// Unkeyed per-chunk hashes for `hashtree.json` (R5). Keys are bundle-
    /// relative segment paths; values are one `sha256` hex per 4 MiB chunk of
    /// the sealed file. An empty section's placeholder file hashes to no chunks
    /// at all — its emptiness is covered by the manifest's `bytes` count, and
    /// any byte added to it surfaces as a chunk-count mismatch.
    static func segmentChunkHashes(
        segments: [MIFSection: [Data]],
        ordered: [MemoryExportSectionBuffer]
    ) -> MIFJSON {
        var files: [String: MIFJSON] = [:]
        for buffer in ordered {
            let sealed = segments[buffer.section] ?? []
            for (index, segment) in (sealed.isEmpty ? [Data()] : sealed).enumerated() {
                files["sections/" + buffer.section.rawValue + "/" + segmentFilename(index)] =
                    .strings(chunkHashes(segment))
            }
        }
        return .object(files)
    }

    /// One `sha256` hex per 4 MiB chunk — the same chunking as the keyed tree,
    /// so a mismatch names the same offset either side would investigate.
    static func chunkHashes(_ data: Data) -> [String] {
        var out: [String] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(
                offset,
                offsetBy: MemoryExportCrypto.hashTreeChunkBytes,
                limitedBy: data.endIndex
            ) ?? data.endIndex
            out.append(MemoryExportDigest.sha256Hex(Data(data[offset..<end])))
            offset = end
        }
        return out
    }

    /// D-0031 ruling 1: `sections/<NN-name>/<index:05>.seg` — five decimal
    /// digits, zero-padded, from 0. `manifest.sections[].segments` is that
    /// count, so a reader knows every path in the bundle from the manifest
    /// alone. The index is the segment index the nonce and the chunk AAD are
    /// derived from, so the filename and the cryptographic position are the
    /// same number by construction.
    static func segmentFilename(_ index: Int) -> String {
        String(format: "%05d.seg", index)
    }
}
