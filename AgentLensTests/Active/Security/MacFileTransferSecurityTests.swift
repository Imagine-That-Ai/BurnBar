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
        let fetchedTickets = await backend.fetchedTickets
        XCTAssertEqual(fetchedTickets, ["blob1ticket"])
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
        let fetchedTickets = await backend.fetchedTickets
        XCTAssertTrue(fetchedTickets.isEmpty, "denied transfer must not fetch")
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks.first?.media?.ack?.status, .rejected)
        XCTAssertEqual(acks.first?.media?.ack?.reason, "media admission denied: killSwitchActive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxURL.path))
        // The in-flight count is balanced (never incremented for a denied transfer).
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 0)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testOutboundSendDeniedByCapabilityGateSkipsPublishAndAdvertise() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-send-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let outboundURL = temp.appendingPathComponent("outbound.txt")
        try Data("outbound".utf8).write(to: outboundURL)

        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: temp.appendingPathComponent("inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true },
            capabilityGate: DenyingCapabilityGate(reason: .killSwitchActive)
        )
        var advertisedFrames: [HermesRealtimeRelayFrame] = []
        adapter.setAdvertiseSender { frame in
            advertisedFrames.append(frame)
        }

        do {
            _ = try await adapter.sendFile(
                at: outboundURL,
                uid: "uid-1",
                connectionID: "connection-1",
                peerDeviceID: "iphone-1"
            )
            XCTFail("expected outbound admission denial")
        } catch let failure as MacFileTransferService.Failure {
            guard case .admissionDenied(let reason) = failure else {
                XCTFail("expected admissionDenied, got \(failure)")
                return
            }
            XCTAssertEqual(reason, MediaCapabilityDenialReason.killSwitchActive.rawValue)
        }

        let publishedPaths = await backend.publishedPaths
        XCTAssertTrue(publishedPaths.isEmpty, "denied send must not publish a blob")
        XCTAssertTrue(advertisedFrames.isEmpty, "denied send must not advertise a ticket")
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 0)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testOutboundSendPublishesImmutableSnapshotAfterAdmission() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-send-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let outboundURL = temp.appendingPathComponent("outbound.txt")
        try Data("small".utf8).write(to: outboundURL)

        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: temp.appendingPathComponent("inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let gate = MutatingAllowGate(fileURL: outboundURL)
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true },
            capabilityGate: gate
        )
        var advertisedFrames: [HermesRealtimeRelayFrame] = []
        adapter.setAdvertiseSender { frame in
            advertisedFrames.append(frame)
        }

        let manifest = try await adapter.sendFile(
            at: outboundURL,
            uid: "uid-1",
            connectionID: "connection-1",
            peerDeviceID: "iphone-1"
        )

        let publishedPayloads = await backend.publishedPayloads
        let publishedPaths = await backend.publishedPaths
        XCTAssertEqual(gate.requestedBudgets, [Int64(5)])
        XCTAssertEqual(publishedPayloads, [Data("small".utf8)])
        XCTAssertFalse(publishedPaths.contains(outboundURL.path), "publish must use the immutable snapshot, not the mutable caller path")
        XCTAssertEqual(manifest.size, 5)
        XCTAssertEqual(manifest.filename, "outbound.txt")
        XCTAssertEqual(advertisedFrames.first?.media?.attachment?.size, 5)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testOutboundSendAdvertisesOnMatchingConnectionStreamOnly() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let backend = QuarantineBlobBackend()
        let registry = MediaControlStreamRegistry(pollIntervalNanoseconds: 10_000_000)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-send-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let outboundURL = temp.appendingPathComponent("outbound.txt")
        try Data("bound".utf8).write(to: outboundURL)

        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: temp.appendingPathComponent("inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let targetStream = FileTransferRecordingIrohStream()
        let siblingStream = FileTransferRecordingIrohStream()
        await registry.register(stream: targetStream, uid: "uid-1", connectionID: "connection-1")
        await registry.register(stream: siblingStream, uid: "uid-1", connectionID: "connection-2")
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true },
            controlStreams: registry,
            advertiseTimeout: 0.2
        )

        _ = try await adapter.sendFile(
            at: outboundURL,
            uid: "uid-1",
            connectionID: "connection-1",
            peerDeviceID: "iphone-1"
        )

        let targetFrames = await targetStream.sentFrames()
        let siblingFrames = await siblingStream.sentFrames()
        XCTAssertEqual(targetFrames.count, 1)
        XCTAssertTrue(siblingFrames.isEmpty)
        XCTAssertEqual(targetFrames.first?.connectionId, "connection-1")
        XCTAssertEqual(targetFrames.first?.type, .mediaBlobAdvertise)
        XCTAssertNotNil(targetFrames.first?.media?.blobTicket)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testMountControlStreamRoutesExactCloseAfterRegistryAlreadyRemovedLease() async {
        let backend = QuarantineBlobBackend()
        let registry = MediaControlStreamRegistry(pollIntervalNanoseconds: 10_000_000)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-stale-close-\(UUID().uuidString)", isDirectory: true)
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: temp.appendingPathComponent("inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x42, count: 32) }
            )
        )
        let adapter = MacFileTransferService(
            service: service,
            settingsProvider: { true },
            controlStreams: registry
        )
        let stream = CloseBlockingIrohStream()
        let closeEvents = ControlStreamCloseEventLedger()
        adapter.setMercuryControlStreamCloseHandler { uid, connectionID, controlStreamID, removedLast in
            await closeEvents.record(
                uid: uid,
                connectionID: connectionID,
                controlStreamID: controlStreamID,
                removedLastStreamForConnection: removedLast
            )
        }

        let mountTask = Task {
            await adapter.mountControlStream(
                stream,
                uid: "uid-1",
                connectionID: "shared-mac"
            )
        }

        for _ in 0..<100 {
            if await registry.activeStreamCount() == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let mountedStreamCount = await registry.activeStreamCount()
        XCTAssertEqual(mountedStreamCount, 1)

        // Simulate policy/reconnect cleanup winning the race before the
        // mounted read loop reaches its own lease invalidation.
        let invalidated = await registry.invalidate(uid: "uid-1", connectionID: "shared-mac")
        XCTAssertTrue(invalidated)
        await mountTask.value

        let events = await closeEvents.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.uid, "uid-1")
        XCTAssertEqual(events.first?.connectionID, "shared-mac")
        XCTAssertNotNil(events.first?.controlStreamID)
        XCTAssertEqual(events.first?.removedLastStreamForConnection, false)

        try? FileManager.default.removeItem(at: temp)
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

    func testInboundAdvertiseDoesNotTrustForgedSealedEnvelopeMagicBytes() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        var forgedPlaintext = MediaFrameAEAD.magic
        forgedPlaintext.append(MediaFrameAEAD.version)
        forgedPlaintext.append(Data("attacker plaintext after public magic".utf8))
        let backend = QuarantineBlobBackend(payload: forgedPlaintext)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-forged-seal-\(UUID().uuidString)", isDirectory: true)
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
        let manifest = Self.manifest(size: Int64(forgedPlaintext.count))
        let frame = Self.advertiseFrame(manifest: manifest)
        var acks: [HermesRealtimeRelayFrame] = []

        await adapter.handleAdvertise(frame: frame) { ack in
            acks.append(ack)
        }

        let downloaded = inboxURL.appendingPathComponent("blob_quarantine_hash.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
        let onDisk = try Data(contentsOf: downloaded)
        XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(onDisk), "received file must be sealed at rest")
        XCTAssertFalse(
            onDisk.contains(Data("attacker plaintext after public magic".utf8)),
            "public magic bytes must not let attacker-controlled plaintext bypass at-rest sealing"
        )
        XCTAssertEqual(acks.first?.media?.ack?.status, .received)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testInboundAdvertiseRejectsOversizedFileInsteadOfInMemorySealing() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let plaintextBytes = Int64(64 * 1024 * 1024 + 1)
        let backend = OversizedSparseBlobBackend(byteCount: plaintextBytes)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-seal-large-\(UUID().uuidString)", isDirectory: true)
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
        let manifest = Self.manifest(size: plaintextBytes)
        let frame = Self.advertiseFrame(manifest: manifest)
        var acks: [HermesRealtimeRelayFrame] = []

        await adapter.handleAdvertise(frame: frame) { ack in
            acks.append(ack)
        }

        let downloaded = inboxURL.appendingPathComponent("blob_quarantine_hash.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
        let fetchedTickets = await backend.fetchedTickets
        XCTAssertEqual(fetchedTickets, [])
        XCTAssertEqual(acks.first?.media?.ack?.status, .rejected)
        XCTAssertEqual(
            acks.first?.media?.ack?.reason?.contains("too large"),
            true,
            "oversized at-rest sealing rejection should be visible to the sender"
        )

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
    }

    func testInboundAdvertiseCleansFetchedPlaintextWhenPeerUnderreportsSize() async throws {
        MacMediaActiveSessionRegistry.shared.resetForTesting()

        let plaintextBytes = Int64(64 * 1024 * 1024 + 1)
        let backend = OversizedSparseBlobBackend(byteCount: plaintextBytes)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-file-transfer-underreported-large-\(UUID().uuidString)", isDirectory: true)
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
        let underreportedManifest = Self.manifest(size: 12)
        let frame = Self.advertiseFrame(manifest: underreportedManifest)
        var acks: [HermesRealtimeRelayFrame] = []

        await adapter.handleAdvertise(frame: frame) { ack in
            acks.append(ack)
        }

        let downloaded = inboxURL.appendingPathComponent("blob_quarantine_hash.txt")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: downloaded.path),
            "seal failure after fetch must not leave attacker-supplied plaintext in the inbox"
        )
        let fetchedTickets = await backend.fetchedTickets
        XCTAssertEqual(fetchedTickets, ["blob1ticket"])
        XCTAssertEqual(acks.first?.media?.ack?.status, .rejected)
        XCTAssertEqual(
            acks.first?.media?.ack?.reason?.contains("exceeded expected size"),
            true,
            "underreported blob rejection should identify the manifest size mismatch"
        )

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

    private static func manifest(size: Int64 = 12) -> HermesRealtimeRelayAttachmentManifest {
        HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_quarantine",
            blobHash: "blob_quarantine_hash",
            filename: "payload.txt",
            mime: "text/plain",
            size: size,
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

    private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
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

private actor QuarantineBlobBackend: IrohBlobBackend {
    private let payload: Data
    private var fetchedTicketStorage: [String] = []
    private var publishedPathStorage: [String] = []
    private var publishedPayloadStorage: [Data] = []

    init(payload: Data = Data("downloaded".utf8)) {
        self.payload = payload
    }

    var fetchedTickets: [String] {
        fetchedTicketStorage
    }

    var publishedPaths: [String] {
        publishedPathStorage
    }

    var publishedPayloads: [Data] {
        publishedPayloadStorage
    }

    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "quarantine_node", rawPublicKey: Data(secret.prefix(32)))
    }

    func publishBlob(localPath: String) async throws -> String {
        publishedPathStorage.append(localPath)
        publishedPayloadStorage.append(try Data(contentsOf: URL(fileURLWithPath: localPath)))
        return "blob1unused"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        fetchedTicketStorage.append(ticketText)
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: url)
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

private actor OversizedSparseBlobBackend: IrohBlobBackend {
    let byteCount: Int64
    private var fetchedTicketStorage: [String] = []

    init(byteCount: Int64) {
        self.byteCount = byteCount
    }

    var fetchedTickets: [String] {
        fetchedTicketStorage
    }

    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "oversized_node", rawPublicKey: Data(secret.prefix(32)))
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob1unused"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        fetchedTicketStorage.append(ticketText)
        let url = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: UInt64(byteCount))
        try? handle.close()
        return BlobTransferStats(
            bytesTotal: UInt64(byteCount),
            blake3Hash: "blake3:oversized",
            durationMillis: 5,
            didResume: false
        )
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "oversized_node", rawPublicKey: Data(repeating: 0x42, count: 32))
    }

    func shutdown() async {}
}

private actor FileTransferRecordingIrohStream: IrohRelayStream {
    nonisolated let remotePeerNodeId: String? = nil
    private var storedFrames: [HermesRealtimeRelayFrame] = []

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        storedFrames.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        nil
    }

    func close() async {}

    func sentFrames() -> [HermesRealtimeRelayFrame] {
        storedFrames
    }
}

private actor CloseBlockingIrohStream: IrohRelayStream {
    nonisolated let remotePeerNodeId: String? = "ios-peer"
    private var isClosed = false

    func send(_: HermesRealtimeRelayFrame) async throws {}

    func receive() async throws -> HermesRealtimeRelayFrame? {
        while !isClosed {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func close() async {
        isClosed = true
    }
}

private actor ControlStreamCloseEventLedger {
    struct Event: Sendable {
        let uid: String
        let connectionID: String
        let controlStreamID: UUID
        let removedLastStreamForConnection: Bool
    }

    private var events: [Event] = []

    func record(
        uid: String,
        connectionID: String,
        controlStreamID: UUID,
        removedLastStreamForConnection: Bool
    ) {
        events.append(
            Event(
                uid: uid,
                connectionID: connectionID,
                controlStreamID: controlStreamID,
                removedLastStreamForConnection: removedLastStreamForConnection
            )
        )
    }

    func snapshot() -> [Event] {
        events
    }
}

private final class MutatingAllowGate: MediaCapabilityGate, @unchecked Sendable {
    private let fileURL: URL
    private(set) var requestedBudgets: [Int64?] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds: Int?,
        sessionByteBudget: Int64?
    ) async -> MediaCapabilityCheck {
        await check(
            feature: feature,
            sessionDurationLimitSeconds: sessionDurationLimitSeconds,
            sessionByteBudget: sessionByteBudget,
            transferDirection: nil
        )
    }

    func check(
        feature: MediaStreamClass.Feature,
        sessionDurationLimitSeconds _: Int?,
        sessionByteBudget: Int64?,
        transferDirection _: MediaCapabilityTransferDirection?
    ) async -> MediaCapabilityCheck {
        requestedBudgets.append(sessionByteBudget)
        try? Data(repeating: 0x41, count: 64).write(to: fileURL)
        return .allowed(envelope: MediaCapabilityEnvelope(feature: feature))
    }
}
