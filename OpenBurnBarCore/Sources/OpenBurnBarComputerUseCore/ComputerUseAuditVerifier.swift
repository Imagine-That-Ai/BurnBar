import Foundation

/// Standalone offline verifier for exported Computer Use audit chains (integrity, prefix, head signature, OTS).
public struct ComputerUseAuditVerifier: Sendable {
    public struct VerificationReport: Sendable, Equatable {
        public var chainValid: Bool
        public var entryCount: Int
        public var headHashHex: String?
        public var headSignatureValid: Bool?
        public var noEntriesAfterIndex: Bool?
        public var openTimestampsVerified: Bool?
        public var openTimestampsDetail: String?
        public var firstInvalidReason: ComputerUseAuditChain.InvalidReason?

        public var isFullyVerified: Bool {
            chainValid
                && (headSignatureValid ?? true)
                && (noEntriesAfterIndex ?? true)
                && (openTimestampsVerified ?? true)
        }
    }

    public let chainValidator: ComputerUseAuditChain
    public let openTimestampsVerifier: ComputerUseOpenTimestampsProofVerifier

    public init(
        hasher: ComputerUseAuditHasher = .current,
        openTimestampsVerifier: ComputerUseOpenTimestampsProofVerifier? = nil
    ) {
        let ots = openTimestampsVerifier ?? ComputerUseOpenTimestampsProofVerifier()
        self.chainValidator = ComputerUseAuditChain(hasher: hasher)
        self.openTimestampsVerifier = ots
    }

    public func verify(
        chainJSONL: Data,
        sessionManifestHashHex: String,
        signedHead: ComputerUseAuditSignedHead?,
        maxEntryIndexInclusive: Int? = nil,
        openTimestampsProofURL: URL? = nil
    ) -> VerificationReport {
        let chainResult = chainValidator.validate(
            rawJSONLines: chainJSONL,
            sessionManifestHashHex: sessionManifestHashHex,
            expectedHeadHashHex: signedHead?.headHashHex
        )

        var headSignatureValid: Bool?
        if let signedHead {
            headSignatureValid = (try? signedHead.verifySignature()) ?? false
        }

        var noEntriesAfterIndex: Bool?
        if let maxEntryIndexInclusive {
            let lastIndex = signedHead?.lastEntryIndex ?? (chainResult.entryCount > 0 ? chainResult.entryCount - 1 : -1)
            noEntriesAfterIndex = chainResult.entryCount <= maxEntryIndexInclusive + 1
                && lastIndex <= maxEntryIndexInclusive
        }

        var openTimestampsVerified: Bool?
        var openTimestampsDetail: String?
        if let openTimestampsProofURL {
            let ots = openTimestampsVerifier.verify(proofAt: openTimestampsProofURL)
            openTimestampsDetail = ots.output
            switch ots.status {
            case .verified:
                openTimestampsVerified = true
            case .proofMissing:
                openTimestampsVerified = nil
            case .verifierUnavailable, .verifyFailed:
                openTimestampsVerified = false
            }
        }

        return VerificationReport(
            chainValid: chainResult.isValid,
            entryCount: chainResult.entryCount,
            headHashHex: chainResult.headHashHex,
            headSignatureValid: headSignatureValid,
            noEntriesAfterIndex: noEntriesAfterIndex,
            openTimestampsVerified: openTimestampsVerified,
            openTimestampsDetail: openTimestampsDetail,
            firstInvalidReason: chainResult.firstInvalidReason
        )
    }

    /// Verify an on-disk session directory (`manifest.json`, `chain.jsonl`, optional `signed_head.json`, `.ots`).
    public func verifySessionDirectory(
        _ sessionDirectory: URL,
        maxEntryIndexInclusive: Int? = nil,
        verifyOpenTimestamps: Bool = true,
        fileManager: FileManager = .default
    ) throws -> VerificationReport {
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let chainURL = sessionDirectory.appendingPathComponent("chain.jsonl")
        let manifest = try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            ComputerUseSessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let manifestHash = try chainValidator.hashSessionManifest(manifest)
        let chainData = try Data(contentsOf: chainURL)
        let signedHead = try ComputerUseAuditHeadFinalizer.loadSignedHead(from: sessionDirectory, fileManager: fileManager)
        let proofURL = verifyOpenTimestamps
            ? ComputerUseOpenTimestampsClient.proofFilename(forChainAt: chainURL)
            : nil
        return verify(
            chainJSONL: chainData,
            sessionManifestHashHex: manifestHash,
            signedHead: signedHead,
            maxEntryIndexInclusive: maxEntryIndexInclusive,
            openTimestampsProofURL: proofURL
        )
    }
}
