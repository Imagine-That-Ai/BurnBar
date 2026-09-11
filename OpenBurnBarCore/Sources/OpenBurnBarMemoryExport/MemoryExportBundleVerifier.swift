// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBundleVerifier — what `openburnbar-cli memory verify` can honestly
// check on the operator's own disk, before a bundle is handed over.
//
// It cannot decrypt anything and it cannot recompute the KEYED hash tree:
// both need the bundle key, which is ephemeral, wrapped to the recipient, and
// never retained here. `verify` used to return a sentence pointing at the
// importer for that reason — which left a corrupted or truncated bundle
// undetectable until it reached the other side (review F-16). What it CAN
// recompute is the UNKEYED per-chunk `chunk_sha256` in `hashtree.json`
// (review R5, Q-56): the tree is over ciphertext, so a plain hash leaks
// nothing and a flipped bit names its segment and chunk without any key.
//
// Everything below needs no key at all:
//
//   * `manifest.sig` verifies against THIS device's export signing key, so a
//     manifest edited after signing is caught;
//   * `bundle_id` follows from `content_digest`, which is how the importer's
//     idempotency is keyed;
//   * `hashtree.json` agrees with the manifest's `hashtree` block and with every
//     section's declared `subroot`;
//   * every section directory holds exactly the `segments` files the manifest
//     declares, summing to the declared `bytes` — which catches a truncated,
//     partly-copied or partly-deleted bundle;
//   * every segment file's 4 MiB chunks hash to `hashtree.json`'s
//     `chunk_sha256` — which catches a MODIFIED segment, naming the file
//     and chunk;
//   * `keys/wrapped-bundle-key` is the two-part b64url form §2.1 states, with a
//     32-byte encapsulated key;
//   * given the recipient descriptor, `recipient_key_id` and
//     `recipient_store_id` are the ones the bundle is addressed to — the
//     substituted-`--recipient` check, run against the artefact rather than
//     against the exporter's memory.
//
// What it deliberately does NOT claim: that the plaintext is intact, or that
// the keyed tree verifies. Only the importer holds the bundle key, so only it
// can say those — and `verify` says so rather than implying otherwise.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct MemoryExportVerification: Sendable, Equatable {
    public var checksRun: [String] = []
    public var problems: [String] = []
    public var bundleID: String?
    public var contentDigest: String?
    public var recipientKeyID: String?
    public var recipientStoreID: String?
    /// The manifest's declared `exporter_device_key_id`, surfaced so a caller
    /// that supplied the verification key out-of-band can prove the bundle was
    /// signed by the key that file names (review #2564).
    public var manifestExporterDeviceKeyID: String?
    public var signatureVerified = false

    public var isIntact: Bool { problems.isEmpty }
}

public enum MemoryExportBundleVerifier {

    public enum VerifyError: Error, Equatable {
        case unreadable(String)
    }

    // reason: one branch per artefact the bundle is made of
    public static func verify(
        bundleAt url: URL,
        signingPublicKey: Curve25519.Signing.PublicKey?,
        recipient: MemoryExportRecipient? = nil
    ) throws -> MemoryExportVerification {
        var result = MemoryExportVerification()
        let manager = FileManager.default

        guard let manifestData = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else {
            throw VerifyError.unreadable("no manifest.json at \(url.path)")
        }
        guard let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw VerifyError.unreadable("manifest.json is not a JSON object")
        }

        // 1. The signature. An unsigned bundle is a finding, not a pass: the
        //    importer pins this key on first import and must reject one without.
        //    D-0031 ruling 1: the preimage is the 32 RAW bytes of
        //    `content_digest` and the file is its b64url rendering — shared
        //    with the signer through `sign`/`verifySignature`, so there is one
        //    spelling of the preimage, not two.
        result.checksRun.append("manifest.sig")
        let signatureURL = url.appendingPathComponent("manifest.sig")
        let contentDigestForSig = manifest["content_digest"] as? String ?? ""
        if let sigText = try? String(contentsOf: signatureURL, encoding: .utf8) {
            if let signingPublicKey {
                result.signatureVerified = MemoryExportCrypto.verifySignature(
                    sigText: sigText,
                    contentDigest: contentDigestForSig,
                    publicKey: signingPublicKey
                )
                if result.signatureVerified == false {
                    result.problems.append("manifest.sig does not verify against this device's export signing key")
                }
            } else {
                result.problems.append("manifest.sig is present but no export signing key is available to check it")
            }
        } else {
            result.problems.append("manifest.sig is missing; the importer refuses an unsigned bundle")
        }

        // 2. The identity the importer keys idempotency on.
        result.checksRun.append("bundle_id ↔ content_digest")
        let contentDigest = manifest["content_digest"] as? String
        let bundleID = manifest["bundle_id"] as? String
        result.contentDigest = contentDigest
        result.bundleID = bundleID
        result.manifestExporterDeviceKeyID = manifest["exporter_device_key_id"] as? String
        if let contentDigest, let bundleID {
            let expected = MemoryExportIdentity.bundleID(contentDigest: contentDigest)
            if expected != bundleID {
                result.problems.append("bundle_id \(bundleID) does not follow from content_digest")
            }
        } else {
            result.problems.append("the manifest is missing bundle_id or content_digest")
        }

        // 2b. And the digest itself, RECOMPUTED from the manifest on disk
        //     (review F-1). Without this the signature proved only that the
        //     declared digest was signed by this device, never that the manifest
        //     beside it is the one that was signed: an editor could rewrite the
        //     crypto profile, the recipient binding or any count and `verify`
        //     still reported `intact=true signature_verified=true`.
        //
        //     `manifest.sig` signs the 32 raw bytes of `content_digest`, and
        //     `content_digest` is `sha256(JCS(manifest minus {created_at_ms,
        //     recipient_key_id, bundle_id, content_digest}))` — so this check is
        //     the link that makes the signature a signature OVER THE MANIFEST.
        result.checksRun.append("content_digest ↔ manifest members")
        let parsedManifest = MIFCanonicalJSON.parse(manifestData)
        if let parsedManifest {
            if let contentDigest {
                let recomputed = MemoryExportManifestDigest.digest(of: parsedManifest)
                if recomputed != contentDigest {
                    let covered = MemoryExportManifestDigest.coveredMembers(of: parsedManifest)
                    result.problems.append(
                        "manifest.json does not reproduce its declared content_digest "
                            + "(declared \(contentDigest), recomputed \(recomputed)) — one of the "
                            + "\(covered.count) members manifest.sig covers was edited after signing: "
                            + covered.joined(separator: ", ")
                    )
                    // WHICH one, wherever the bundle carries a second,
                    // independent witness of the same fact. The digest can only
                    // say THAT a member moved.
                    result.problems.append(contentsOf: namedManifestEdits(parsedManifest, bundleAt: url))
                }
            }
        } else {
            result.problems.append("manifest.json is not JSON this format can canonicalise")
        }

        // 3. `hashtree.json` against the manifest. The tree is keyed, so this is
        //    an agreement check between two documents rather than a recompute —
        //    which is exactly what it is worth, and all it claims to be.
        result.checksRun.append("hashtree.json ↔ manifest")
        let headers = manifest["sections"] as? [[String: Any]] ?? []
        if let treeData = try? Data(contentsOf: url.appendingPathComponent("hashtree.json")),
           let tree = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any] {
            let manifestTree = manifest["hashtree"] as? [String: Any]
            if (tree["root"] as? String) != (manifestTree?["root"] as? String) {
                result.problems.append("hashtree.json's root disagrees with the manifest's")
            }
            // `$defs/hashtree_file`'s member name [D-0039 ruling 8].
            let subroots = tree["subroots"] as? [String: String] ?? [:]
            for header in headers {
                guard let name = header["name"] as? String else { continue }
                if subroots[name] != header["subroot"] as? String {
                    result.problems.append("\(name): hashtree.json's subroot disagrees with the section header")
                }
            }
        } else {
            result.problems.append("hashtree.json is missing or unreadable")
        }

        // 4. The section files themselves. A truncated or partly-copied bundle
        //    is what an operator's own disk most plausibly produces, and it is
        //    caught here without a key.
        result.checksRun.append("section segments on disk")
        for header in headers {
            guard let name = header["name"] as? String else { continue }
            let directory = url.appendingPathComponent("sections").appendingPathComponent(name)
            let declaredSegments = header["segments"] as? Int ?? 1
            let declaredBytes = header["bytes"] as? Int ?? 0
            var onDisk = 0
            for index in 0..<max(1, declaredSegments) {
                let file = directory.appendingPathComponent(MemoryExportBundleWriter.segmentFilename(index))
                guard let attributes = try? manager.attributesOfItem(atPath: file.path),
                      let size = attributes[.size] as? Int else {
                    result.problems.append("\(name): segment \(index) is missing")
                    continue
                }
                // Every declared segment is a sealed unit an importer can open,
                // an empty section's included — it seals the empty string, so it
                // is never shorter than the nonce and tag (F-3).
                if size < MemoryExportCrypto.sealOverheadBytes {
                    result.problems.append(
                        "\(name): segment \(index) is \(size) bytes — shorter than an AEAD seal, "
                            + "so no importer can open it"
                    )
                }
                onDisk += size
            }
            // And nothing BESIDE them: a section directory holding more `.seg`
            // files than the manifest declares is a bundle merged with another.
            let extra = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".seg") }
                .count - max(1, declaredSegments)
            if extra > 0 {
                result.problems.append("\(name): \(extra) segment file(s) the manifest does not declare")
            }
            if onDisk != declaredBytes {
                result.problems.append(
                    "\(name): \(onDisk) bytes on disk, \(declaredBytes) declared — the bundle is truncated or edited"
                )
            }
        }

        // 4b. The segment bytes themselves, against `hashtree.json`'s unkeyed
        //     `chunk_sha256` (Q-56). Sizes (check 4) catch truncation; this
        //     catches modification at the same size — the one-bit flip check 4
        //     is blind to (review R5). Streamed in small reads against 4 MiB
        //     chunk boundaries, so a large segment never sits whole in memory
        //     here. The comparison is per section, in segment-index order over
        //     the flat chunk stream the writer sealed; the message names the
        //     file and its chunk within that file.
        result.checksRun.append("chunk_sha256 \u{2194} files on disk")
        if manager.fileExists(atPath: url.appendingPathComponent("segments.sha256.json").path) {
            // Q-60 closed the directory: the sidecar is not read — a stale one
            // beside a current tree would let a verifier bless tampered bytes
            // — it is named, and the bundle is the importer's held
            // `MANIFEST_INVALID:bundle/segments.sha256.json`.
            result.problems.append(
                "segments.sha256.json is present; Q-56 moved the per-chunk hashes into "
                    + "hashtree.json's chunk_sha256 and Q-60 closed the directory — re-export it"
            )
        }
        if let treeData = try? Data(contentsOf: url.appendingPathComponent("hashtree.json")),
           let tree = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
           let chunkSHA = tree["chunk_sha256"] as? [String: [String]] {
            let chunkBytes = MemoryExportCrypto.hashTreeChunkBytes
            for header in headers {
                guard let name = header["name"] as? String else { continue }
                let expected = chunkSHA[name] ?? []
                let declaredSegments = header["segments"] as? Int ?? 1
                var cursor = 0
                var matched = true
                for segmentIndex in 0..<max(1, declaredSegments) {
                    let relative = "sections/\(name)/" + MemoryExportBundleWriter.segmentFilename(segmentIndex)
                    guard let handle = try? FileHandle(
                        forReadingFrom: url.appendingPathComponent(relative)
                    ) else {
                        // Check 4 already reports a missing segment; there is
                        // nothing further to hash here.
                        matched = false
                        break
                    }
                    var fileChunk = 0
                    while matched {
                        // `readData(ofLength:)` is the portable read:
                        // `read(upToCount:)` is unavailable on the Linux
                        // corelibs this package still builds.
                        let data = handle.readData(ofLength: chunkBytes)
                        if data.isEmpty { break }
                        if cursor >= expected.count
                            || MemoryExportDigest.sha256Hex(data) != expected[cursor] {
                            result.problems.append(
                                "\(relative): chunk \(fileChunk) (byte offset \(fileChunk * chunkBytes)) "
                                    + "does not match hashtree.json — the segment was modified after sealing"
                            )
                            matched = false
                        }
                        cursor += 1
                        fileChunk += 1
                    }
                    try? handle.close()
                    if matched == false { break }
                }
                if matched, cursor != expected.count {
                    result.problems.append(
                        "\(name): \(cursor) chunks on disk, \(expected.count) in hashtree.json's "
                            + "chunk_sha256 — the section was truncated or extended after sealing"
                    )
                }
            }
        } else {
            result.problems.append(
                "hashtree.json carries no chunk_sha256; segment tampering is undetectable — the bundle "
                    + "predates tamper-evident segments, re-export it"
            )
        }

        // 5. The wrapped key's shape. Its CONTENT cannot be checked here; that
        //    the recipient can open it is the importer's first act.
        result.checksRun.append("keys/wrapped-bundle-key")
        if let wrapped = try? String(contentsOf: url.appendingPathComponent("keys/wrapped-bundle-key"), encoding: .utf8) {
            let parts = wrapped.split(separator: ".", omittingEmptySubsequences: false)
            let enc = parts.count == 2 ? MemoryExportBase64URL.decode(String(parts[0])) : nil
            if parts.count != 2 || enc?.count != 32 || MemoryExportBase64URL.decode(String(parts[1])) == nil {
                result.problems.append(
                    "keys/wrapped-bundle-key is not b64url(enc) \".\" b64url(ct) with a 32-byte encapsulated key"
                )
            }
        } else {
            result.problems.append("keys/wrapped-bundle-key is missing; nobody could open this bundle")
        }

        // 6. Who it is addressed to, against the descriptor rather than against
        //    the exporter's memory of it.
        result.recipientKeyID = manifest["recipient_key_id"] as? String
        result.recipientStoreID = manifest["recipient_store_id"] as? String
        // M-10: a `recipient_store_id` the target's DDL forbids is a bundle no
        // store can accept, and the contract's `["string", "null"]` typing does
        // not catch it. A rehearsal bundle is exempt: it is sealed to nobody by
        // design, says so in its manifest, and an importer refuses it outright.
        result.checksRun.append("recipient_store_id shape")
        if (manifest["rehearsal"] as? Bool) != true,
           let storeID = result.recipientStoreID,
           MemoryExportRecipient.isValidStoreID(storeID) == false {
            result.problems.append(
                "recipient_store_id \(storeID) is not a store id (`sto_` + 32 lowercase hex): no store "
                    + "can exist under it, so every importer answers RECIPIENT_MISMATCH"
            )
        }
        if let recipient {
            result.checksRun.append("recipient binding")
            if result.recipientKeyID != recipient.manifestKeyID {
                result.problems.append("this bundle is addressed to a different recipient key")
            }
            if result.recipientStoreID != recipient.storeID {
                result.problems.append("this bundle is addressed to a different target store")
            }
        }

        // 7. §10's closed sums, recomputed from `report.json` rather than
        //    believed, and D-0039 ruling 5's coverage: every section the
        //    manifest declares rows for has a lane in the report that accounts
        //    for them. Interop run 1 found three sections (00, 02, 09) whose
        //    rows belonged to no lane at all, so `balanced` could be true of
        //    every lane while the bundle carried rows nobody had counted (M-8).
        result.checksRun.append("report.json lanes ↔ section rows")
        result.problems.append(contentsOf: reconciliationProblems(bundleAt: url, headers: headers))

        return result
    }

    /// The closed sums and the section coverage, read off the two files.
    ///
    /// `table_reconciliation` is `additionalProperties: false`, so a lane cannot
    /// carry the section it writes into; the binding is
    /// `MIFReconciliationLane.sections`, and the lane NAME is what the report
    /// gives a verifier to look it up with. A name outside the vocabulary is
    /// therefore a lane this build cannot reason about — reported, not ignored.
    static func reconciliationProblems(bundleAt url: URL, headers: [[String: Any]]) -> [String] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("report.json")),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = report["tables"] as? [[String: Any]] else {
            return ["report.json is missing or carries no tables[], so no count can be reconciled"]
        }
        var problems: [String] = []
        var present: Set<MIFReconciliationLane> = []

        for table in tables {
            guard let name = table["name"] as? String else {
                problems.append("report.json carries a table with no name")
                continue
            }
            guard let lane = MIFReconciliationLane(rawValue: name) else {
                problems.append("report.json's lane `\(name)` is not one this build knows")
                continue
            }
            present.insert(lane)

            let sourceRows = table["source_rows"] as? Int ?? 0
            let exported = table["exported"] as? Int ?? 0
            let notExported = (table["not_exported"] as? [String: Int] ?? [:]).values.reduce(0, +)
            let rejected = (table["rejected"] as? [String: Int] ?? [:]).values.reduce(0, +)
            let accounted = exported + notExported + rejected
            let balanced = sourceRows == accounted
            if balanced == false {
                problems.append(
                    "\(name): \(sourceRows) source row(s), \(accounted) accounted "
                        + "(\(exported) exported + \(notExported) not exported + \(rejected) rejected)"
                )
            }
            if let declared = table["balanced"] as? Bool, declared != balanced {
                problems.append("\(name): declares balanced=\(declared) and its own numbers say \(balanced)")
            }
        }

        for header in headers {
            guard let name = header["name"] as? String,
                  let section = MIFSection(rawValue: name) else { continue }
            let rows = header["row_count"] as? Int ?? 0
            let lanes = section.lanes
            if lanes.isEmpty {
                problems.append("\(name): no reconciliation lane covers this section")
                continue
            }
            if rows > 0, lanes.contains(where: present.contains) == false {
                problems.append(
                    "\(name): \(rows) row(s) carried and report.json has none of the lanes that "
                        + "account for them (\(lanes.map(\.rawValue).joined(separator: ", ")))"
                )
            }
        }
        return problems
    }

    /// The manifest members a second artefact in the same bundle can
    /// contradict. Every one of these is inside `content_digest`, so a
    /// disagreement here always arrives beside the digest problem above — this
    /// exists to NAME the member, not to detect the edit.
    ///
    /// `crypto`, `user_id` and the other members the bundle witnesses only once
    /// are caught by the digest and named by it as a group; naming those
    /// individually would need a second copy of the manifest, which a verifier
    /// on the operator's own disk does not have.
    static func namedManifestEdits(_ manifest: MIFJSON, bundleAt url: URL) -> [String] {
        guard case .object(let fields) = manifest else { return [] }
        var problems: [String] = []

        // `rollups[]` and `sections[]` carry the same two facts per section: the
        // writer computes each roll-up digest once and puts it in both, and a
        // section's `row_count` is the number of roll-up tuples it digested.
        var headerDigests: [String: String] = [:]
        var headerRowCounts: [String: Int] = [:]
        if case .array(let headers)? = fields["sections"] {
            for header in headers {
                guard case .object(let member) = header,
                      case .string(let name)? = member["name"] else { continue }
                if case .string(let digest)? = member["rollup_digest"] { headerDigests[name] = digest }
                if case .int(let rows)? = member["row_count"] { headerRowCounts[name] = rows }
            }
        }
        if case .array(let rollups)? = fields["rollups"] {
            for (index, rollup) in rollups.enumerated() {
                guard case .object(let member) = rollup,
                      case .string(let name)? = member["section"] else { continue }
                if case .string(let digest)? = member["rollup_digest"], let header = headerDigests[name],
                   digest != header {
                    problems.append(
                        "rollups[\(index)].rollup_digest disagrees with sections[\(name)].rollup_digest"
                    )
                }
                if case .int(let rows)? = member["row_count"], let header = headerRowCounts[name],
                   rows != header {
                    problems.append(
                        "sections[\(name)].row_count is \(header) but rollups[\(index)] digested "
                            + "\(rows) rows"
                    )
                }
            }
        }
        // `not_exported` is the per-reason SUM over every logical table's own
        // not-exported source rows, and `report.json` carries that same view per
        // table (§10's closed sum is per table). So the two documents witness
        // one fact twice, and a manifest edited to hide rows disagrees with the
        // report beside it.
        if case .object(let declared)? = fields["not_exported"],
           let reportData = try? Data(contentsOf: url.appendingPathComponent("report.json")),
           case .object(let report)? = MIFCanonicalJSON.parse(reportData),
           case .array(let tables)? = report["tables"] {
            var summed: [String: Int] = [:]
            for table in tables {
                guard case .object(let member) = table,
                      case .object(let notExported)? = member["not_exported"] else { continue }
                for (reason, count) in notExported {
                    guard case .int(let rows) = count else { continue }
                    summed[reason, default: 0] += rows
                }
            }
            for reason in Set(summed.keys).union(declared.keys).sorted() {
                let manifestCount: Int
                if case .int(let value)? = declared[reason] { manifestCount = value } else { manifestCount = 0 }
                if manifestCount != summed[reason, default: 0] {
                    problems.append(
                        "not_exported.\(reason) is \(manifestCount) but report.json's tables account for "
                            + "\(summed[reason, default: 0]) source row(s)"
                    )
                }
            }
        }
        return problems
    }

    /// The operator-facing rendering. It says what was checked AND what was not,
    /// because a verify that quietly checks less than it seems to is the failure
    /// mode this replaced.
    public static func format(_ verification: MemoryExportVerification, at url: URL) -> String {
        var lines = ["bundle:      \(url.path)"]
        if let bundleID = verification.bundleID { lines.append("id:          \(bundleID)") }
        if let digest = verification.contentDigest { lines.append("digest:      \(digest)") }
        if let keyID = verification.recipientKeyID { lines.append("sealed to:   \(keyID)") }
        if let storeID = verification.recipientStoreID { lines.append("target store:\(storeID)") }
        lines.append("signature:   \(verification.signatureVerified ? "verified" : "NOT verified")")
        lines.append("checked:     \(verification.checksRun.joined(separator: ", "))")
        if verification.problems.isEmpty {
            lines.append("result:      intact as far as this side can see")
        } else {
            lines.append("result:      \(verification.problems.count) problem(s)")
            lines.append(contentsOf: verification.problems.map { "  - \($0)" })
        }
        lines.append(
            "not checked: the plaintext. Segment BYTES are checked — one unkeyed sha256 per 4 MiB chunk "
                + "of every segment file — but the records and the keyed hash tree can only be verified by "
                + "`memoryctl memory import --dry-run <bundle>, which holds the bundle key."
        )
        return lines.joined(separator: "\n")
    }
}
