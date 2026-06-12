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
        XCTAssertEqual(try quarantineValue(at: downloaded).contains("OpenBurnBar"), true)
        XCTAssertEqual(acks.count, 1)
        XCTAssertEqual(acks.first?.media?.ack?.status, .received)
        XCTAssertEqual(backend.fetchedTickets, ["blob1ticket"])
        XCTAssertEqual(MacMediaActiveSessionRegistry.shared.count(for: .fileTransfer), 0)

        try? FileManager.default.removeItem(at: temp)
        MacMediaActiveSessionRegistry.shared.resetForTesting()
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
