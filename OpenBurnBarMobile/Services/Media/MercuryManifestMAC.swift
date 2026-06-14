import CryptoKit
import Foundation
import OpenBurnBarCore

/// T-ATT-04 — sender-bound MAC over the inbound Mercury manifest's identity
/// fields `(blobHash, filename, mime, size)`.
///
/// The blob bytes are fetched by content hash, but a compromised relay can still
/// rewrite the *advertised* manifest (swap the filename, mime, or claimed size,
/// or point at a different blob hash) before it reaches iOS. This helper computes
/// / verifies an HMAC-SHA256 over a canonical, length-delimited encoding of those
/// four fields under the negotiated media-session key (the same F7 key the
/// at-rest seal uses — derived from the two pinned relay identities, so it is
/// bound to *these* two paired devices). Only a peer holding the session key can
/// produce a valid tag, so a relay cannot forge or tamper with the manifest.
///
/// Pure and `@Sendable`; constant-time comparison via CryptoKit so verification
/// is unit-testable and timing-safe.
///
/// NOTE (Deferred wire carrier): the MAC must travel in the advertise frame for
/// end-to-end enforcement. The relay media payload wire type
/// (`HermesRealtimeRelayMediaPayload`, owned by OpenBurnBarCore) has no field to
/// carry it yet, so the receive path verifies the MAC only when one is supplied
/// (e.g. via the manifest peer-id-bound channel or a future payload field). The
/// primitive + verification gate land here; adding the wire field is tracked as
/// the Deferred cross-package portion of T-ATT-04.
enum MercuryManifestMAC {
    private static let domain = "OpenBurnBar-MercuryManifestMAC-v1"

    /// Canonical, length-delimited transcript of the manifest identity fields so a
    /// MAC cannot be replayed across a manifest with the same fields concatenated
    /// differently (e.g. filename "a" + mime "b" vs filename "ab" + mime "").
    static func transcript(
        blobHash: String,
        filename: String,
        mime: String,
        size: Int64
    ) -> Data {
        var data = Data(domain.utf8)
        appendPart(&data, Data(blobHash.utf8))
        appendPart(&data, Data(filename.utf8))
        appendPart(&data, Data(mime.utf8))
        var beSize = UInt64(bitPattern: size).bigEndian
        withUnsafeBytes(of: &beSize) { appendPart(&data, Data($0)) }
        return data
    }

    /// Compute the HMAC-SHA256 tag (base64) for a manifest under `key`.
    static func tag(
        blobHash: String,
        filename: String,
        mime: String,
        size: Int64,
        key: SymmetricKey
    ) -> String {
        let message = transcript(blobHash: blobHash, filename: filename, mime: mime, size: size)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).base64EncodedString()
    }

    /// Convenience over a manifest.
    static func tag(
        manifest: HermesRealtimeRelayAttachmentManifest,
        key: SymmetricKey
    ) -> String {
        tag(
            blobHash: manifest.blobHash,
            filename: manifest.filename,
            mime: manifest.mime,
            size: manifest.size,
            key: key
        )
    }

    /// Verify a base64 MAC for a manifest in constant time. Returns `false` for a
    /// malformed (non-base64) tag so a garbled tag fails closed.
    static func verify(
        expectedTagBase64: String,
        manifest: HermesRealtimeRelayAttachmentManifest,
        key: SymmetricKey
    ) -> Bool {
        guard let expected = Data(base64Encoded: expectedTagBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let message = transcript(
            blobHash: manifest.blobHash,
            filename: manifest.filename,
            mime: manifest.mime,
            size: manifest.size
        )
        return HMAC<SHA256>.isValidAuthenticationCode(expected, authenticating: message, using: key)
    }

    private static func appendPart(_ data: inout Data, _ part: Data) {
        var length = UInt64(part.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(part)
    }
}
