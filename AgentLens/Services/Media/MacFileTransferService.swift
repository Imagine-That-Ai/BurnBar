import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
import OSLog

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
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")
    private static func debugTrace(_ message: String) {
        #if DEBUG
        NSLog("OpenBurnBarMercury \(message)")
        #endif
    }

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

    /// Mercury Phase 8 — side-band dispatcher for mirror / presence frames
    /// that ride the same `media.control` stream as file transfer.
    /// `MacFileTransferService` owns the read loop; this closure hands
    /// non-blob frames off to `MercuryRouter` (or any other consumer)
    /// without coupling the file-transfer service to the router type.
    typealias MercuryControlFrameDispatcher = @Sendable (
        _ frame: HermesRealtimeRelayFrame,
        _ replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async -> Void

    private let service: MediaFileTransferService
    private let settingsProvider: @MainActor () -> Bool
    private let controlStreamRegistry: MediaControlStreamRegistry?
    private let advertiseTimeout: TimeInterval
    private var advertiseSenderOverride: AdvertiseSender?
    private var mercuryDispatcher: MercuryControlFrameDispatcher?

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

    /// Mercury Phase 8 — attach the side-band dispatcher that routes
    /// `media.mirror.request`, `media.mirror.ack`, and
    /// `media.presence.heartbeat` frames to `MercuryRouter`. Called
    /// once from `CloudSyncService` after `MercuryRouter` exists.
    /// Subsequent frames seen by the read loop fan out to both the
    /// blob dispatcher (file traffic) and the Mercury dispatcher
    /// (mirror/presence traffic) based on `frame.type`.
    func setMercuryDispatcher(_ dispatcher: @escaping MercuryControlFrameDispatcher) {
        self.mercuryDispatcher = dispatcher
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
        Self.log.info("mac_control_stream_mounted connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("mac_control_stream_mounted connectionID=\(connectionID)")
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
                Self.log.info("mac_control_stream_receive type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
                Self.debugTrace("mac_control_stream_receive type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "") connectionID=\(frame.connectionId)")
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
                case .mediaMirrorRequest,
                     .mediaMirrorAck,
                     .mediaMirrorStop,
                     .mediaPresenceHeartbeat,
                     .mediaCallInvite,
                     .mediaCallAck,
                     .mediaStreamFrame:
                    // Mercury Phase 8 — fan out to `MercuryRouter` if
                    // one is attached. Same ackSender shape so the
                    // router can write a `media.mirror.ack` back on the
                    // same stream the request arrived on.
                    if let mercuryDispatcher {
                        Self.log.info("mac_control_stream_dispatch_mercury type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public)")
                        Self.debugTrace("mac_control_stream_dispatch_mercury type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "")")
                        await mercuryDispatcher(frame, ackSender)
                    } else {
                        Self.log.error("mac_control_stream_missing_mercury_dispatcher type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public)")
                        Self.debugTrace("mac_control_stream_missing_mercury_dispatcher type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "")")
                    }
                default:
                    continue
                }
            }
        } catch {
            Self.log.error("mac_control_stream_read_failed connectionID=\(connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mac_control_stream_read_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
            lastError = .publishFailed("control stream read: \(error.localizedDescription)")
        }
        await registry.invalidate(uid: uid, connectionID: connectionID)
        Self.log.info("mac_control_stream_closed connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("mac_control_stream_closed connectionID=\(connectionID)")
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

/// Sends encoded Mercury media frames over the already-live `media.control`
/// stream that iOS opened to the Mac. This is the v1 mirror transport used by
/// phone-initiated "Ask to Mirror": approval stays on the control stream, and
/// accepted video frames follow as `media.stream.frame` envelopes.
final class MercuryControlStreamMediaSink: MediaStreamSink, @unchecked Sendable {
    enum SinkError: Error, LocalizedError {
        case streamUnavailable

        var errorDescription: String? {
            switch self {
            case .streamUnavailable:
                return "No live Mercury control stream is available."
            }
        }
    }

    private let stream: any IrohRelayStream
    private let uid: String
    private let connectionID: String
    private let streamClass: MediaStreamClass
    private let codec = MediaPacketCodec()

    init(
        stream: any IrohRelayStream,
        uid: String,
        connectionID: String,
        streamClass: MediaStreamClass
    ) {
        self.stream = stream
        self.uid = uid
        self.connectionID = connectionID
        self.streamClass = streamClass
    }

    static func make(
        registry: MediaControlStreamRegistry,
        uid: String,
        connectionID: String,
        streamClass: MediaStreamClass
    ) async throws -> MercuryControlStreamMediaSink {
        let exactStream = await registry.stream(uid: uid, connectionID: connectionID)
        let latestStream = await registry.latestStream(uid: uid)?.stream
        guard let stream = exactStream ?? latestStream else {
            throw SinkError.streamUnavailable
        }
        return MercuryControlStreamMediaSink(
            stream: stream,
            uid: uid,
            connectionID: connectionID,
            streamClass: streamClass
        )
    }

    func write(frame: MediaFrame) async {
        do {
            let encoded = try codec.encode(frame)
            let outbound = HermesRealtimeRelayFrame(
                type: .mediaStreamFrame,
                uid: uid,
                connectionId: connectionID,
                media: HermesRealtimeRelayMediaPayload(
                    streamClass: streamClass.rawValue,
                    encodedFrameBase64: encoded.base64EncodedString()
                )
            )
            try await stream.send(outbound)
        } catch {
            // `MediaStreamSink.write` is intentionally fire-and-forget. The
            // session coordinator owns teardown; a failed send drops this
            // frame without crashing the host app.
        }
    }

    func close() async {}
}
