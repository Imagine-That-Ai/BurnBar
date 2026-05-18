import Foundation
import CryptoKit

/// Pure-Swift OpenTimestamps client for Phase 13 chain notarization.
///
/// The OpenTimestamps protocol bundles a target digest with a chain of
/// operations (concatenations, hash invocations) that fold the digest
/// into a Bitcoin block-header Merkle root. For our use case we
/// submit `digest = SHA-256(chain.jsonl bytes)` to a public calendar
/// server, persist the returned `.ots` blob alongside the chain, and
/// later verify by replaying the operations and confirming the Bitcoin
/// attestation.
///
/// The full OTS binary format is substantial (calendar URLs +
/// operations + pending-attestation markers). Rather than reimplement
/// every opcode, this client speaks the **calendar HTTP API** —
/// `POST /digest` returns the raw OTS blob the caller stores as
/// `chain.jsonl.ots`. Verification calls out to the public `ots verify`
/// CLI shipped by the OpenTimestamps team (documented in
/// `docs/runbooks/computer-use-audit-disputes.md`).
///
/// We do not vendor or parse the OTS blob — we treat it as opaque and
/// hand it to `ots verify`. This intentionally narrow scope keeps the
/// client small and removes a class of protocol-version risk.
public final class ComputerUseOpenTimestampsClient: Sendable {
    public enum ClientError: Error, Sendable, Equatable {
        case digestTooLong(actual: Int, max: Int)
        case calendarUnreachable(String)
        case calendarHTTPError(Int)
        case emptyResponse
    }

    public struct Configuration: Sendable {
        public let calendarURL: URL
        public let userAgent: String

        public init(
            calendarURL: URL = URL(string: "https://a.pool.opentimestamps.org/digest")!,
            userAgent: String = "OpenBurnBar-ComputerUse/1.0"
        ) {
            self.calendarURL = calendarURL
            self.userAgent = userAgent
        }
    }

    public let configuration: Configuration
    private let urlSession: URLSession

    public init(
        configuration: Configuration = Configuration(),
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    /// Hash + submit the audit chain file to the calendar server. Returns
    /// the raw OTS proof bytes. Caller persists them next to the chain as
    /// `chain.jsonl.ots`; the official `ots verify chain.jsonl.ots`
    /// command expects the adjacent `chain.jsonl` file to hash to the
    /// digest stamped here.
    public func notarize(chainFileAt chainURL: URL) async throws -> Data {
        let chainBytes = try Data(contentsOf: chainURL)
        let digest = SHA256.hash(data: chainBytes)
        return try await notarize(digest: Data(digest))
    }

    /// Hash + submit the chain-head hash to the calendar server.
    ///
    /// Prefer `notarize(chainFileAt:)` for `.ots` sidecars named after
    /// `chain.jsonl`. This remains available for callers that explicitly
    /// persist and verify a head-hash payload instead of the chain file.
    public func notarize(auditChainHeadHashHex: String) async throws -> Data {
        let digest = SHA256.hash(data: Data(auditChainHeadHashHex.utf8))
        return try await notarize(digest: Data(digest))
    }

    /// Submit a raw 32-byte digest. OTS calendar servers reject longer
    /// inputs.
    public func notarize(digest: Data) async throws -> Data {
        guard digest.count <= 32 else {
            throw ClientError.digestTooLong(actual: digest.count, max: 32)
        }
        var request = URLRequest(url: configuration.calendarURL)
        request.httpMethod = "POST"
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.opentimestamps.v1", forHTTPHeaderField: "Accept")
        request.httpBody = digest
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ClientError.calendarUnreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.calendarHTTPError(http.statusCode)
        }
        if data.isEmpty { throw ClientError.emptyResponse }
        return data
    }

    /// Build the canonical `.ots` filename for an audit chain.
    public static func proofFilename(forChainAt chainURL: URL) -> URL {
        chainURL.deletingPathExtension().appendingPathExtension(chainURL.pathExtension + ".ots")
    }
}

/// Filesystem helper for the Phase 13 notarization flow. Pure I/O —
/// no networking; the caller does the calendar submission via
/// `ComputerUseOpenTimestampsClient`.
public enum ComputerUseOpenTimestampsArchive {
    /// Persist the proof bytes next to `chainURL` and write a
    /// metadata sidecar that records when the proof was minted and
    /// against which calendar.
    public static func writeProof(
        proofBytes: Data,
        sourceChainURL: URL,
        calendarURL: URL,
        notarizedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let proofURL = ComputerUseOpenTimestampsClient.proofFilename(forChainAt: sourceChainURL)
        try proofBytes.write(to: proofURL, options: .atomic)

        struct ProofSidecar: Encodable {
            let chainFile: String
            let calendar: String
            let notarizedAt: Date
            let proofSizeBytes: Int
        }
        let sidecar = ProofSidecar(
            chainFile: sourceChainURL.lastPathComponent,
            calendar: calendarURL.absoluteString,
            notarizedAt: notarizedAt,
            proofSizeBytes: proofBytes.count
        )
        let sidecarURL = sourceChainURL.deletingPathExtension().appendingPathExtension(sourceChainURL.pathExtension + ".ots.json")
        let data = try ComputerUseAuditHasher.canonicalJSONEncoder.encode(sidecar)
        try data.write(to: sidecarURL, options: [.atomic])
        _ = fileManager  // unused but keeps the signature stable for tests
        return proofURL
    }
}
