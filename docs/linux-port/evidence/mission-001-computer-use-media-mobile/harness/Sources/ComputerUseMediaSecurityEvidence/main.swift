import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

struct EvidenceSummary: Codable {
    var generatedAt: String
    var audit: AuditEvidence
    var media: MediaEvidence
    var panic: PanicEvidence
}

struct AuditEvidence: Codable {
    var sessionId: String
    var sessionDirectory: String
    var archivePath: String
    var signaturePath: String?
    var entryCount: Int
    var signedHeadPath: String
    var headHashHex: String
    var panicEntryIndex: Int
    var generatedBy: String
}

struct MediaEvidence: Codable {
    var generatedBy: String
    var capability: String
    var screenVideoDecision: String
    var fileTransferDecision: String
    var sealedEnvelopeBytes: Int
    var openedPlaintext: String
    var decoderConfigCodec: String
    var decoderConfigRoundTrip: Bool
    var liveInteropStatus: String
    var blocker: String
}

struct PanicEvidence: Codable {
    var generatedBy: String
    var panicEntryIndex: Int
    var liveHaltStatus: String
    var blocker: String
}

@main
struct ComputerUseMediaSecurityEvidenceMain {
    static func main() throws {
        let output = try outputDirectory()
        let audit = try generateAuditEvidence(in: output)
        let media = try generateMediaEvidence()
        let panic = PanicEvidence(
            generatedBy: "ComputerUseAuditLogger panic-approved audit entry; live halt paths are probed by run-computer-use-evidence.mjs",
            panicEntryIndex: audit.panicEntryIndex,
            liveHaltStatus: "blocked",
            blocker: "No live Linux app UI, daemon session, mobile control path, or global/system hook was supplied to this worker."
        )
        let summary = EvidenceSummary(
            generatedAt: iso8601(Date()),
            audit: audit,
            media: media,
            panic: panic
        )
        try writeJSON(summary, named: "product-evidence-summary.json", in: output)
        print("product_evidence_summary=\(output.appendingPathComponent("product-evidence-summary.json").path)")
        print("audit_session=\(audit.sessionDirectory)")
        print("audit_archive=\(audit.archivePath)")
        if let signaturePath = audit.signaturePath {
            print("audit_signature=\(signaturePath)")
        }
    }

    private static func outputDirectory() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["OPENBURNBAR_CU_MEDIA_SECURITY_EVIDENCE_DIR"]
            ?? ProcessInfo.processInfo.environment["OB_EVIDENCE_OUT"]
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func generateAuditEvidence(in output: URL) throws -> AuditEvidence {
        let fileManager = FileManager.default
        let base = output.appendingPathComponent("audit-product", isDirectory: true)
        try? fileManager.removeItem(at: base)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)

        let sessionId = "sec-003-product-audit-session"
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID(sessionId),
            baseDirectory: base,
            macAppVersion: "linux-port-mission-001"
        )
        let manifest = ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID(sessionId),
            mode: .browser,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            userId: "linux-evidence-user",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1800
        )
        try logger.beginSession(manifest: manifest)

        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "#start-capture")),
            timestamp: Date(timeIntervalSince1970: 1_777_000_001),
            approvalId: "approval-capture",
            approvedBy: .mac,
            beforeScreenshotHashHex: sha256("capture-before"),
            afterScreenshotHashHex: sha256("capture-after"),
            macHostNodeId: "linux-product-peer"
        ))
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "#deny-region")),
            timestamp: Date(timeIntervalSince1970: 1_777_000_002),
            approvalId: "approval-denied-region",
            approvedBy: .denied,
            scopeRuleId: "deny-password-fields",
            denyReason: "deny_region",
            beforeScreenshotHashHex: sha256("deny-before"),
            macHostNodeId: "linux-product-peer"
        ))
        try logger.append(try logger.makeEntry(
            for: .macInspect(MacInspectAction(kind: .accessibility)),
            timestamp: Date(timeIntervalSince1970: 1_777_000_003),
            approvalId: "approval-panic-hotkey",
            approvedBy: .panic,
            denyReason: "panic_hotkey",
            beforeScreenshotHashHex: sha256("panic-before"),
            afterScreenshotHashHex: sha256("panic-after"),
            macHostNodeId: "linux-product-peer"
        ))

        let signer = ComputerUseEd25519AuditExportSigner(
            privateKey: PlatformCrypto.ed25519PrivateKey(),
            signerIdentifier: "linux-sec-003-product-signer"
        )
        let signedHead = try ComputerUseAuditHeadFinalizer.finalize(
            logger: logger,
            closedAt: Date(timeIntervalSince1970: 1_777_000_004),
            signer: signer
        )
        let sessionDirectory = base.appendingPathComponent(sessionId, isDirectory: true)
        let archive = output.appendingPathComponent("computer-use-audit-export.product.tar.gz")
        let exportResult = try ComputerUseAuditExportWriter().export(
            sessionDirectory: sessionDirectory,
            destinationURL: archive,
            includeScreenshots: false,
            signer: signer
        )

        return AuditEvidence(
            sessionId: sessionId,
            sessionDirectory: sessionDirectory.path,
            archivePath: archive.path,
            signaturePath: exportResult.signatureURL?.path,
            entryCount: exportResult.entryCount,
            signedHeadPath: sessionDirectory.appendingPathComponent(ComputerUseAuditHeadFinalizer.signedHeadFilename).path,
            headHashHex: signedHead.headHashHex,
            panicEntryIndex: 2,
            generatedBy: "ComputerUseAuditLogger + ComputerUseAuditHeadFinalizer + ComputerUseAuditExportWriter"
        )
    }

    private static func generateMediaEvidence() throws -> MediaEvidence {
        let aead = MediaFrameAEAD()
        let key = aead.deriveSessionKey(
            sharedSecret: Data("linux-product-media-shared-secret".utf8),
            salt: Data("mission-001-sec-003".utf8)
        )
        let plaintext = Data("OBMF2 H.264 keyframe payload from product harness".utf8)
        let sealed = try aead.seal(
            plaintext: plaintext,
            key: key,
            streamClass: "media.screen.video",
            kind: 0x01,
            gopID: 7,
            frameIndex: 11
        )
        let opened = try aead.open(
            envelope: sealed,
            key: key,
            streamClass: "media.screen.video",
            kind: 0x01,
            gopID: 7,
            frameIndex: 11
        )
        let config = VideoDecoderConfigurationPayload(
            codec: .h264,
            parameterSets: [Data([0x67, 0x42, 0x00, 0x1F]), Data([0x68, 0xCE, 0x06, 0xE2])],
            samplePayload: plaintext
        )
        let encoded = try config.encoded()
        let decoded = try VideoDecoderConfigurationPayload.decodeIfPresent(encoded)
        return MediaEvidence(
            generatedBy: "OpenBurnBarMedia MediaFrameAEAD + VideoDecoderConfigurationPayload",
            capability: MediaFrameAeadNegotiation.capability,
            screenVideoDecision: String(describing: MediaFrameAeadNegotiation.resolveSealingDecision(
                streamClass: .screenVideo,
                localSupports: true,
                remoteSupports: true,
                sessionKeyAvailable: true
            )),
            fileTransferDecision: String(describing: MediaFrameAeadNegotiation.resolveSealingDecision(
                streamClass: .blobAdvertise,
                localSupports: true,
                remoteSupports: false,
                sessionKeyAvailable: false
            )),
            sealedEnvelopeBytes: sealed.count,
            openedPlaintext: String(data: opened, encoding: .utf8) ?? "",
            decoderConfigCodec: "h264",
            decoderConfigRoundTrip: decoded == config,
            liveInteropStatus: "blocked",
            blocker: "No non-loopback LAN/mobile/mac/simulator endpoint was supplied for ADR-008 call/file/screen-share interop."
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T, named name: String, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func sha256(_ value: String) -> String {
        PlatformCrypto.sha256Hex(Data(value.utf8))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
