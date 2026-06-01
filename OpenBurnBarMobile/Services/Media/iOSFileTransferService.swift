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
    /// Mercury Phase 8 — singleton accessor populated by `AppDelegate`
    /// after `configureMercuryFileTransfer()` builds the receiver. Lets
    /// the Mercury Live sheet drive outbound sends without threading
    /// the receiver through the SwiftUI tree.
    static var current: iOSFileTransferService?

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

    /// Lightweight notification emitted from `sendFile` and
    /// `handleAdvertise` success paths so callers (today: the Mercury
    /// transfer-history store) can record a row without reaching into
    /// the service's `@Published` state. Stays out of `OpenBurnBarCore`
    /// — this is a UI concern.
    struct TransferCompletion: Sendable, Equatable {
        enum Direction: String, Sendable, Equatable {
            case sent
            case received
        }
        let id: String
        let connectionID: String
        let direction: Direction
        let filename: String
        let mime: String
        let sizeBytes: Int64
        let completedAt: Date
        let bytesPerSecond: Double?
        let didResume: Bool
        let localURL: URL?
    }

    private let service: MediaFileTransferService?
    private let settingsProvider: @MainActor () -> Bool
    /// Long-lived media control stream owners, keyed by Hermes connection.
    /// Set via `attachControlStream(_:connectionID:)` once iOS auth +
    /// Hermes connection reach an authenticated state. Optional so tests
    /// can drive the receive path without spinning up an iroh dialer.
    private var controlCoordinatorsByConnectionID: [String: MediaControlStreamCoordinator] = [:]

    @Published private(set) var lastError: Failure?
    @Published private(set) var inFlightCount: Int = 0
    @Published private(set) var lastReceivedAttachment: ReceivedAttachment?
    @Published private(set) var lastSentManifestID: String?

    /// Fires on every successful send + receive. Set by `AppDelegate`
    /// after the Mercury transfer-history store is wired up.
    var onTransferCompleted: ((TransferCompletion) -> Void)?

    init(
        service: MediaFileTransferService?,
        settingsProvider: @escaping @MainActor () -> Bool
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
    }

    func attachControlStream(_ coordinator: MediaControlStreamCoordinator, connectionID: String) {
        controlCoordinatorsByConnectionID[connectionID] = coordinator
    }

    func detachControlStream(connectionID: String? = nil) async {
        if let connectionID {
            guard let coordinator = controlCoordinatorsByConnectionID.removeValue(forKey: connectionID) else { return }
            await coordinator.stop()
            return
        }
        let coordinators = Array(controlCoordinatorsByConnectionID.values)
        controlCoordinatorsByConnectionID.removeAll()
        for coordinator in coordinators {
            await coordinator.stop()
        }
    }

    func bootstrapBlobEndpoint() async throws -> IrohEndpointIdentity {
        guard let service else { throw Failure.backendUnavailable }
        return try await service.bootstrap()
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
            guard let service else { throw Failure.backendUnavailable }
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
            let bps: Double? = stats.durationMillis > 0
                ? Double(stats.bytesTotal) * 1000.0 / Double(stats.durationMillis)
                : nil
            onTransferCompleted?(TransferCompletion(
                id: manifest.manifestId,
                connectionID: frame.connectionId,
                direction: .received,
                filename: manifest.filename,
                mime: manifest.mime,
                sizeBytes: manifest.size,
                completedAt: Date(),
                bytesPerSecond: bps,
                didResume: stats.didResume,
                localURL: destination
            ))
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

    /// Publish a file from iOS and emit a `media.blob.advertise` frame
    /// to Mac. Resolution order:
    ///   1. Explicit `advertiseSender` override (tests).
    ///   2. The persistent media-control coordinator (production).
    ///   3. `.dispatchUnavailable` failure — never silently drops a
    ///      user-initiated send.
    func sendFile(
        at fileURL: URL,
        uid: String,
        connectionID: String,
        peerDeviceID: String?,
        advertiseSender: AdvertiseSender? = nil
    ) async throws -> HermesRealtimeRelayAttachmentManifest {
        guard settingsProvider() else { throw Failure.settingDisabled }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Failure.fileMissing(fileURL)
        }

        inFlightCount += 1
        defer { inFlightCount -= 1 }

        let publishStart = Date()
        let publish: MediaFileTransferService.PublishResult
        do {
            guard let service else { throw Failure.backendUnavailable }
            publish = try await service.publish(localFile: fileURL, peerDeviceID: peerDeviceID)
        } catch let failure as Failure {
            lastError = failure
            throw failure
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

        do {
            if let advertiseSender {
                try await advertiseSender(frame)
            } else if let controlCoordinator = controlCoordinatorsByConnectionID[connectionID] {
                try await controlCoordinator.send(frame: frame)
            } else {
                lastError = .dispatchUnavailable
                throw Failure.dispatchUnavailable
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            let failure = Failure.publishFailed("advertise emit: \(error.localizedDescription)")
            lastError = failure
            throw failure
        }

        lastSentManifestID = publish.manifest.manifestId

        let elapsed = Date().timeIntervalSince(publishStart)
        let bps: Double? = elapsed > 0 ? Double(publish.manifest.size) / elapsed : nil
        onTransferCompleted?(TransferCompletion(
            id: publish.manifest.manifestId,
            connectionID: connectionID,
            direction: .sent,
            filename: publish.manifest.filename,
            mime: publish.manifest.mime,
            sizeBytes: publish.manifest.size,
            completedAt: Date(),
            bytesPerSecond: bps,
            didResume: false,
            localURL: fileURL
        ))

        return publish.manifest
    }
}
