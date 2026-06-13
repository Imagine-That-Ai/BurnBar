import CryptoKit
import Darwin
import Foundation
import XCTest
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBar

@MainActor
final class MacFileTransferSecurityTests: XCTestCase {
    func testInboundAdvertiseQuarantinesFetchedFileAndClearsActiveTransferCount() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-security-\(UUID().uuidString)", isDirectory: true)
        let inboxURL = temp.appendingPathComponent("inbox", isDirectory: true)
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: inboxURL,
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true }
        )
        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_quarantine",
            blobHash: "blob_quarantine_hash",
            filename: "payload.txt",
            mime: "text/plain",
            size: 12,
            peerDeviceId: "iphone-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: "uid-1",
            connectionId: "connection-1",
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: manifest,
                blobTicket: "blob1ticket"
            )
        )
        var acks: [HermesRealtimeRelayFrame] = []

        await adapter.handleAdvertise(frame: frame) { ack in
            acks.append(ack)
        }

        let downloaded = inboxURL.appendingPathComponent("blob_quarantine_hash.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
        XCTAssertTrue(try quarantineValue(at: downloaded).contains("OpenBurnBar"))
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks.first?.media?.ack?.status, .received)
        XCTAssertEqual(backend.fetchedTickets, ["blob1ticket"])
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 0)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testInboundAdvertiseDeniedByCapabilityGateSkipsFetchAndAcksRejected() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-gate-\(UUID().uuidString)", isDirectory: true)
        let inboxURL = temp.appendingPathComponent("inbox", isDirectory: true)
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: inboxURL,
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true },
            capabilityGate: DenyingCapabilityGate(reason: .killSwitchActive)
        )
        let manifest = Self.manifest()
        let frame = Self.advertiseFrame(manifest: manifest)
        var acks: [HermesRealtimeRelayFrame] = []

        await adapter.handleAdvertise(frame: frame) { ack in
            acks.append(ack)
        }

        // RR-18 — gate denial must short-circuit before the blob backend runs.
        XCTAssertTrue(backend.fetchedTickets.isEmpty, "denied transfer must not fetch")
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks.first?.media?.ack?.status, .rejected)
        XCTAssertEqual(acks.first?.media?.ack?.reason, "media admission denied: killSwitchActive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.path))
        // The in-flight count is balanced (never incremented for a denied transfer).
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 0)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testInboundAdvertiseSealsReceivedBytesAtRestWhenSessionKeyAvailable() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-seal-\(UUID().uuidString)", isDirectory: true)
        let inboxURL = temp.appendingPathComponent("inbox", isDirectory: true)
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: inboxURL,
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let sessionKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true },
            frameSealKeyProvider: { _, _ in sessionKey }
        )
        let manifest = Self.manifest()
        let frame = Self.advertiseFrame(manifest: manifest)
        var acks: [HermesRealtimeRelayFrame] = []

        await adapter.handleAdvertise(frame: frame) { ack in
            acks.append(ack)
        }

        let downloaded = inboxURL.appendingPathComponent("blob_quarantine_hash.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
        let onDisk = try Data(contentsOf: downloaded)
        // RR-18 — the bytes on disk are a sealed OBMFA1 envelope, not plaintext.
        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(onDisk), "received file must be sealed at rest")
        XCTAssertFalse(onDisk.contains(Data("downloaded".utf8)), "plaintext must not remain on disk")
        // Quarantine xattr is still applied to the sealed file.
        XCTAssertTrue(try quarantineValue(at: downloaded).contains("OpenBurnBar"))
        XCTAssertEqual(acks.first?.media?.ack?.status, .received)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testInboundAdvertiseKeepsPlaintextWhenNoSessionKey() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-nokey-\(UUID().uuidString)", isDirectory: true)
        let inboxURL = temp.appendingPathComponent("inbox", isDirectory: true)
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: inboxURL,
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        // No seal key negotiated — pre-F7 behaviour: quarantine xattr only.
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true }
        )
        let frame = Self.advertiseFrame(manifest: Self.manifest())
        await adapter.handleAdvertise(frame: frame) { _ in }

        let downloaded = inboxURL.appendingPathComponent("blob_quarantine_hash.txt")
        let onDisk = try Data(contentsOf: downloaded)
        XCTAssertFalse(MediaFrameAEAD.isSealedEnvelope(onDisk))
        XCTAssertEqual(String(decoding: onDisk, as: UTF8.self), "downloaded")

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    private static func manifest() -> HermesRealtimeRelayAttachmentManifest {
        HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_quarantine",
            blobHash: "blob_quarantine_hash",
            filename: "payload.txt",
            mime: "text/plain",
            size: 12,
            peerDeviceId: "iphone-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func advertiseFrame(
        manifest: HermesRealtimeRelayAttachmentManifest
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: "uid-1",
            connectionId: "connection-1",
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: manifest,
                blobTicket: "blob1ticket"
            )
        )
    }

    private func quarantineValue(at url: URL) throws -> String {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let dataCount = data.count
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(url.path, name, buffer.baseAddress, dataCount, 0, 0)
        }
        guard read == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Always-deny gate so the inbound-receive admission path can be exercised
/// without standing up the full `MacMediaCapabilityGate` signal chain.
private struct DenyingCapabilityGate: MediaCapabilityGate {
    let reason: MediaCapabilityDenialReason

    func check(
        feature _: MediaStreamClass.Feature,
        sessionDurationLimitSeconds _: Int?,
        sessionByteBudget _: Int64?
    ) async -> MediaCapabilityCheck {
        .denied(reason: reason)
    }
}

private final class QuarantineBlobBackend: IrohBlobBackend, @unchecked Sendable {
    var fetchedTickets: [String] = []

    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "quarantine_node", rawPublicKey: Data(secret.prefix(32)))
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob1unused"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        fetchedTickets.append(ticketText)
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("downloaded".utf8).write(to: url)
        return BlobTransferStats(
            bytesTotal: 10,
            blake3Hash: "blake3:quarantine",
            durationMillis: 5,
            didResume: false
        )
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "quarantine_node", rawPublicKey: Data(repeating: 0x42, count: 32))
    }

    func shutdown() async {}
}
