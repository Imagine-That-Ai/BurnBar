import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Mac-side outbound + inbound file transfer driver. Wraps the
/// platform-agnostic `MediaFileTransferService` and adds the chat-stream
/// integration: emit `media.blob.advertise` after a publish, dispatch
/// inbound `media.blob.advertise` to a fetch, emit `media.blob.ack` after
/// the transfer settles.
///
/// Outbound flow (Mac → iOS):
///   1. UI calls `sendFile(_:peerDeviceID:)`.
///   2. Service publishes the file to its blob store, gets a ticket.
///   3. Service emits a `media.blob.advertise` frame on whichever inbound
///      chat stream is currently bound to that peer (the chat connection
///      is iOS-dialed; we piggyback on the same connection by opening a
///      new media-control stream).
///   4. iOS sees the advertise on the chat side, calls back
///      `IrohBlobBackend.fetchBlob` on its own blob endpoint.
///   5. iOS emits `media.blob.ack` once the bytes land.
///
/// Inbound flow (iOS → Mac, used by Phase 2 reverse direction):
///   1. iOS publishes a blob, sends `media.blob.advertise` to Mac.
///   2. Mac receives the frame inside `IrohRelayRequestHandler`,
///      forwards it to this service via `handleAdvertise`.
///   3. Service runs the fetch into the local inbox.
///   4. Service emits `media.blob.ack` back on the same chat stream.
@MainActor
final class MacFileTransferService: ObservableObject {
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
                return "No active iroh stream is available to advertise the file on."
            case .settingDisabled:
                return "media_blob_transfer_enabled is off."
            }
        }
    }

    /// Closure handed in by the chat-stream owner. Sending side: emits a
    /// `media.blob.advertise` frame on the active chat stream for the
    /// given peer. The owner injects this so the file-transfer service
    /// stays decoupled from the iroh transport object.
    typealias AdvertiseSender = @MainActor (HermesRealtimeRelayFrame) async throws -> Void

    private let service: MediaFileTransferService
    private let settingsProvider: @MainActor () -> Bool
    private let controlStreamRegistry: MediaControlStreamRegistry?
    private let advertiseTimeout: TimeInterval
    private var advertiseSenderOverride: AdvertiseSender?

    @Published private(set) var lastError: Failure?
    @Published private(set) var inFlightCount: Int = 0
    @Published private(set) var lastReceivedManifestID: String?
    /// Last completed outbound publish — surfaced as a Mercury toast
    /// confirmation in the chat input.
    @Published private(set) var lastSentManifestID: String?

    init(
        service: MediaFileTransferService,
        settingsProvider: @escaping @MainActor () -> Bool,
        controlStreamRegistry: MediaControlStreamRegistry? = nil,
        advertiseTimeout: TimeInterval = 6.0
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
        self.controlStreamRegistry = controlStreamRegistry
        self.advertiseTimeout = advertiseTimeout
    }

    /// Test seam — production code leaves this `nil` and relies on the
    /// persistent control-stream registry. Tests inject a recording
    /// closure here to capture the advertise frame without spinning up
    /// a real iroh stream.
    func setAdvertiseSender(_ sender: @escaping AdvertiseSender) {
        self.advertiseSenderOverride = sender
    }

    func bootstrapBlobEndpoint() async throws -> IrohEndpointIdentity {
        try await service.bootstrap()
    }

    /// Publish a file from the Mac and emit an advertise frame to the
    /// paired iPhone. Resolution order for the advertise send:
    ///   1. Explicit override (`setAdvertiseSender`) — tests only.
    ///   2. Persistent media control stream via
    ///      `MediaControlStreamRegistry.awaitStream`, blocking up to
    ///      `advertiseTimeout` seconds so a freshly-typed attachment
    ///      doesn't race iOS's control-stream dial.
    ///   3. Failure with `.dispatchUnavailable` and a user-readable
    ///      message — surfaced by the chat input as a Mercury toast.
    func sendFile(
        at fileURL: URL,
        uid: String,
        connectionID: String,
        peerDeviceID: String?
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

        do {
            try await emitAdvertise(frame: frame, uid: uid)
        } catch {
            let failure = Failure.publishFailed("advertise emit: \(error.localizedDescription)")
            lastError = failure
            throw failure
        }

        lastSentManifestID = publish.manifest.manifestId
        return publish.manifest
    }

    private func emitAdvertise(
        frame: HermesRealtimeRelayFrame,
        uid: String
    ) async throws {
        if let advertiseSenderOverride {
            try await advertiseSenderOverride(frame)
            return
        }
        guard let registry = controlStreamRegistry else {
            lastError = .dispatchUnavailable
            throw Failure.dispatchUnavailable
        }
        guard let stream = await registry.awaitStream(uid: uid, timeout: advertiseTimeout) else {
            lastError = .dispatchUnavailable
            throw Failure.dispatchUnavailable
        }
        try await stream.send(frame)
    }

    /// Take ownership of a freshly-classified iOS-side media-control
    /// stream: register it with the registry, then drive a long-lived
    /// read loop that dispatches inbound advertise/ack frames. When the
    /// stream closes (peer disconnect, app background timeout, etc.),
    /// invalidate the registry entry so the next outbound send re-waits
    /// for a fresh dial.
    func mountControlStream(
        _ stream: any IrohRelayStream,
        uid: String,
        connectionID: String
    ) async {
        guard let registry = controlStreamRegistry else {
            // Misconfigured — no registry to register with. Close
            // defensively so we don't leak the stream.
            await stream.close()
            return
        }
        await registry.register(stream: stream, uid: uid, connectionID: connectionID)
        // Bind a Sendable ack-sender to the same stream so inbound
        // advertise frames can write their ack back over the same path
        // the dispatcher expects.
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = {
            [stream] outbound in
            try await stream.send(outbound)
        }
        do {
            while let frame = try await stream.receive() {
                guard frame.uid == uid, frame.connectionId == connectionID else { continue }
                switch frame.type {
                case .mediaBlobAdvertise:
                    await handleAdvertise(frame: frame, ackSender: ackSender)
                case .mediaBlobAck:
                    // Mac is the originator of the ack-emitting flow's
                    // counterpart frame; if iOS acks one of OUR sends,
                    // surface the manifest id so the chat row can flip
                    // from "in flight" to "delivered". Phase 2 polish
                    // will hook this into per-row state.
                    if let manifestID = frame.media?.ack?.manifestId {
                        lastReceivedManifestID = manifestID
                    }
                case .mediaClassify:
                    // Re-classification mid-stream is a protocol
                    // violation; ignore rather than abort.
                    continue
                default:
                    continue
                }
            }
        } catch {
            lastError = .publishFailed("control stream read: \(error.localizedDescription)")
        }
        await registry.invalidate(uid: uid, connectionID: connectionID)
        await stream.close()
    }

    /// Handle an inbound `media.blob.advertise` frame from a peer (iOS).
    /// Issues the fetch, then sends `media.blob.ack`.
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
            _ = try await service.fetch(ticketText: ticket, manifest: manifest)
            lastReceivedManifestID = manifest.manifestId
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
}
