import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

#if canImport(UIKit)
import UIKit
#endif

/// iOS-side file transfer driver. Mirror of `MacFileTransferService` but
/// inverted: the typical Phase 1 flow is **Mac → iOS**, so this class is
/// primarily a receiver. Sending iOS → Mac is a Phase 2 stretch.
///
/// Receive flow:
///   1. iOS sees `media.blob.advertise` on the active chat response
///      stream (the chat connection iOS dialed to Mac).
///   2. `HermesIrohRelayTransport` routes the frame to
///      `handleAdvertise(frame:ackSender:)`.
///   3. Service runs `MediaFileTransferService.fetch` to download the
///      blob into the per-blob inbox.
///   4. Service emits `media.blob.ack` back on the same chat stream.
///   5. UI surfaces (Phase 2) read the `lastReceivedManifest` publisher.
@MainActor
final class iOSFileTransferService: ObservableObject {
    enum Failure: Error, LocalizedError {
        case backendUnavailable
        case fileMissing(URL)
        case publishFailed(String)
        case fetchFailed(String)
        case dispatchUnavailable
        case settingDisabled

        var errorDescription: String? {
            switch self {
            case .backendUnavailable:
                return "Mercury file transfer is unavailable on this build."
            case .fileMissing(let url):
                return "File missing: \(url.path)"
            case .publishFailed(let message):
                return "Publish failed: \(message)"
            case .fetchFailed(let message):
                return "Fetch failed: \(message)"
            case .dispatchUnavailable:
                return "No active iroh stream is available."
            case .settingDisabled:
                return "media_blob_transfer_enabled is off."
            }
        }
    }

    typealias AdvertiseSender = @MainActor (HermesRealtimeRelayFrame) async throws -> Void

    struct ReceivedAttachment: Identifiable, Equatable {
        let id: String
        let manifest: HermesRealtimeRelayAttachmentManifest
        let destinationURL: URL
        let stats: BlobTransferStats
    }

    private let service: MediaFileTransferService
    private let settingsProvider: @MainActor () -> Bool

    @Published private(set) var lastError: Failure?
    @Published private(set) var inFlightCount: Int = 0
    @Published private(set) var lastReceivedAttachment: ReceivedAttachment?

    init(
        service: MediaFileTransferService,
        settingsProvider: @escaping @MainActor () -> Bool
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
    }

    func bootstrapBlobEndpoint() async throws -> IrohEndpointIdentity {
        try await service.bootstrap()
    }

    /// Phase 1 receive entry point. iOS sees a `media.blob.advertise` on
    /// the active chat response stream, calls in here, fetch happens,
    /// ack goes back on the same chat stream via `ackSender`.
    func handleAdvertise(
        frame: HermesRealtimeRelayFrame,
        ackSender: AdvertiseSender
    ) async {
        guard settingsProvider() else { return }
        guard let media = frame.media,
              let manifest = media.attachment,
              let ticket = media.blobTicket else {
            return
        }

        inFlightCount += 1
        defer { inFlightCount -= 1 }

        var status: HermesRealtimeRelayMediaAck.Status = .received
        var reason: String?

        do {
            let (destination, stats) = try await service.fetch(
                ticketText: ticket,
                manifest: manifest
            )
            lastReceivedAttachment = ReceivedAttachment(
                id: manifest.manifestId,
                manifest: manifest,
                destinationURL: destination,
                stats: stats
            )
        } catch let serviceError as MediaFileTransferService.ServiceError {
            status = .rejected
            reason = String(describing: serviceError)
            lastError = .fetchFailed(reason ?? "")
        } catch {
            status = .rejected
            reason = error.localizedDescription
            lastError = .fetchFailed(reason ?? "")
        }

        let ack = HermesRealtimeRelayMediaAck(
            manifestId: manifest.manifestId,
            status: status,
            reason: reason
        )
        let ackFrame = HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                ack: ack
            )
        )
        try? await ackSender(ackFrame)
    }

    /// Reverse direction (Phase 2 stretch): iOS publishes a file and
    /// emits an advertise frame so the Mac fetches it.
    func sendFile(
        at fileURL: URL,
        uid: String,
        connectionID: String,
        peerDeviceID: String?,
        advertiseSender: @escaping AdvertiseSender
    ) async throws -> HermesRealtimeRelayAttachmentManifest {
        guard settingsProvider() else { throw Failure.settingDisabled }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Failure.fileMissing(fileURL)
        }

        inFlightCount += 1
        defer { inFlightCount -= 1 }

        let publish: MediaFileTransferService.PublishResult
        do {
            publish = try await service.publish(localFile: fileURL, peerDeviceID: peerDeviceID)
        } catch let serviceError as MediaFileTransferService.ServiceError {
            let failure = Failure.publishFailed(String(describing: serviceError))
            lastError = failure
            throw failure
        }

        let frame = HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: uid,
            connectionId: connectionID,
            requestId: publish.manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: publish.manifest,
                blobTicket: publish.ticketText
            )
        )

        try await advertiseSender(frame)
        return publish.manifest
    }
}
