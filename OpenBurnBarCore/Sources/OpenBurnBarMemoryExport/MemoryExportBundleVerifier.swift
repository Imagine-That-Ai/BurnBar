// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBundleVerifier — what `openburnbar-cli memory verify` can honestly
// check on the operator's own disk, before a bundle is handed over.
//
// It cannot decrypt anything and it cannot recompute the hash tree: both need
// the bundle key, which is ephemeral, wrapped to the recipient, and never
// retained here. `verify` used to return a sentence pointing at the importer for
// that reason — which left a corrupted or truncated bundle undetectable until
// it reached the other side (review F-16).
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
//   * `keys/wrapped-bundle-key` is the two-part b64url form §2.1 states, with a
//     32-byte encapsulated key;
//   * given the recipient descriptor, `recipient_key_id` and
//     `recipient_store_id` are the ones the bundle is addressed to — the
//     substituted-`--recipient` check, run against the artefact rather than
//     against the exporter's memory.
//
// What it deliberately does NOT claim: that the plaintext is intact. Only the
// importer can say that, and `verify` says so rather than implying otherwise.

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
    public var signatureVerified = false

    public var isIntact: Bool { problems.isEmpty }
}

public enum MemoryExportBundleVerifier {

    public enum VerifyError: Error, Equatable {
        case unreadable(String)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity reason: one branch per artefact the bundle is made of
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
        result.checksRun.append("manifest.sig")
        let signatureURL = url.appendingPathComponent("manifest.sig")
        if let signature = try? Data(contentsOf: signatureURL) {
            if let signingPublicKey {
                let digest = Data(SHA256.hash(data: manifestData))
                result.signatureVerified = signingPublicKey.isValidSignature(signature, for: digest)
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
        if let contentDigest, let bundleID {
            let expected = MemoryExportIdentity.bundleID(contentDigest: contentDigest)
            if expected != bundleID {
                result.problems.append("bundle_id \(bundleID) does not follow from content_digest")
            }
        } else {
            result.problems.append("the manifest is missing bundle_id or content_digest")
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
            let subroots = tree["sections"] as? [String: String] ?? [:]
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
                onDisk += size
            }
            if onDisk != declaredBytes {
                result.problems.append(
                    "\(name): \(onDisk) bytes on disk, \(declaredBytes) declared — the bundle is truncated or edited"
                )
            }
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
        if let recipient {
            result.checksRun.append("recipient binding")
            if result.recipientKeyID != recipient.manifestKeyID {
                result.problems.append("this bundle is addressed to a different recipient key")
            }
            if result.recipientStoreID != recipient.storeID {
                result.problems.append("this bundle is addressed to a different target store")
            }
        }

        return result
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
            "not checked: the plaintext. The bundle key is wrapped to the recipient and never kept here, "
                + "so the records and the keyed hash tree can only be verified by "
                + "`memoryctl memory import --dry-run <bundle>`."
        )
        return lines.joined(separator: "\n")
    }
}
