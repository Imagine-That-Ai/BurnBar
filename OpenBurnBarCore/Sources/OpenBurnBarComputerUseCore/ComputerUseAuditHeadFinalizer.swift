import Foundation

/// Writes the WS3 terminal `signed_head.json` for a closed Computer Use audit session.
public enum ComputerUseAuditHeadFinalizer {
    public static let signedHeadFilename = "signed_head.json"

    public enum FinalizerError: Error, Sendable, Equatable {
        case headMarkerMissing
        case invalidHeadMarker
        case signingFailed
    }

    /// Sign the current logger head and persist `signed_head.json` beside the chain.
    @discardableResult
    public static func finalize(
        logger: ComputerUseAuditLogger,
        closedAt: Date = Date(),
        signer: ComputerUseAuditExportSigning
    ) throws -> ComputerUseAuditSignedHead {
        let lastEntryIndex = logger.nextEntryIndex > 0 ? logger.nextEntryIndex - 1 : -1
        let signed = try sign(
            sessionId: logger.sessionId.rawValue,
            lastEntryIndex: lastEntryIndex,
            headHashHex: logger.headHashHex,
            closedAt: closedAt,
            signer: signer
        )
        try write(signed, to: logger.directory)
        return signed
    }

    /// Sign using the live `head.json` marker in an on-disk session directory.
    @discardableResult
    public static func finalizeSessionDirectory(
        _ sessionDirectory: URL,
        closedAt: Date = Date(),
        signer: ComputerUseAuditExportSigning,
        fileManager: FileManager = .default
    ) throws -> ComputerUseAuditSignedHead {
        let headURL = sessionDirectory.appendingPathComponent("head.json")
        guard fileManager.fileExists(atPath: headURL.path) else {
            throw FinalizerError.headMarkerMissing
        }
        struct HeadMarker: Decodable {
            let index: Int
            let hashHex: String
            let sessionId: String
        }
        let head = try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            HeadMarker.self,
            from: Data(contentsOf: headURL)
        )
        guard !head.hashHex.isEmpty, !head.sessionId.isEmpty else {
            throw FinalizerError.invalidHeadMarker
        }
        let lastEntryIndex = head.index > 0 ? head.index - 1 : -1
        let signed = try sign(
            sessionId: head.sessionId,
            lastEntryIndex: lastEntryIndex,
            headHashHex: head.hashHex,
            closedAt: closedAt,
            signer: signer
        )
        try write(signed, to: sessionDirectory)
        return signed
    }

    public static func loadSignedHead(
        from sessionDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ComputerUseAuditSignedHead? {
        let url = sessionDirectory.appendingPathComponent(signedHeadFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            ComputerUseAuditSignedHead.self,
            from: Data(contentsOf: url)
        )
    }

    public static func sign(
        sessionId: String,
        lastEntryIndex: Int,
        headHashHex: String,
        closedAt: Date,
        signer: ComputerUseAuditExportSigning
    ) throws -> ComputerUseAuditSignedHead {
        guard let publicKeyBase64 = signer.publicKeyBase64 else {
            throw FinalizerError.signingFailed
        }
        let draft = ComputerUseAuditSignedHead(
            sessionId: sessionId,
            lastEntryIndex: lastEntryIndex,
            headHashHex: headHashHex,
            closedAt: closedAt,
            signatureEd25519Base64: "",
            signerPublicKeyEd25519Base64: publicKeyBase64
        )
        let payload = try draft.signingPayload
        let signature = try signer.signCanonicalPayload(payload)
        return ComputerUseAuditSignedHead(
            sessionId: sessionId,
            lastEntryIndex: lastEntryIndex,
            headHashHex: headHashHex,
            closedAt: closedAt,
            signatureEd25519Base64: signature.base64EncodedString(),
            signerPublicKeyEd25519Base64: publicKeyBase64
        )
    }

    public static func write(
        _ signedHead: ComputerUseAuditSignedHead,
        to sessionDirectory: URL
    ) throws {
        let data = try ComputerUseAuditHasher.canonicalJSONEncoder.encode(signedHead)
        try data.write(
            to: sessionDirectory.appendingPathComponent(signedHeadFilename),
            options: .atomic
        )
    }
}
