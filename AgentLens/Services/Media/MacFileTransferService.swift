import CryptoKit
import Darwin
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
///   3. Service emits a `media.blob.advertise` frame on the media-control
///      stream bound to the same connection that owns the ticket.
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
    private static let maxAtRestSealPlaintextBytes: Int64 = FileSealAEAD.maxPlaintextBytes
    private static let maxAtRestSealEnvelopeBytes: Int64 = maxAtRestSealPlaintextBytes + 64
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
        case admissionDenied(String)

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
            case .admissionDenied(let reason):
                return "Media admission denied: \(reason)"
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
        _ controlStreamID: UUID,
        _ remotePeerNodeID: String?,
        _ replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async -> Void
    typealias MercuryControlStreamCloseHandler = @Sendable (
        _ uid: String,
        _ connectionID: String,
        _ controlStreamID: UUID,
        _ removedLastStreamForConnection: Bool
    ) async -> Void

    private let service: MediaFileTransferService
    private let settingsProvider: @MainActor () -> Bool
    private let controlStreams: MediaControlStreamRegistry?
    /// RR-18 — authoritative media admission gate (entitlement + daily cap +
    /// kill switch + concurrency). Inbound file receive and outbound send both
    /// consult it for `.fileTransfer` exactly as `MediaSessionCoordinator` does
    /// for `.screenShare` / `.videoCall`, instead of only bumping the active
    /// session count. Optional so loopback/dev builds without a wired gate keep
    /// working (they pass `AlwaysAllowMediaCapabilityGate`).
    private let capabilityGate: any MediaCapabilityGate
    /// RR-18 — when a media-seal session key exists for the receiving
    /// connection, received blob bytes are sealed at rest (AES-256-GCM under the
    /// same F7 session key the screen lane uses, manifest-bound AAD) instead of
    /// landing as plaintext in the sandbox Caches inbox. Returns nil when no
    /// session key is negotiated; in that case the file keeps only the
    /// quarantine xattr, matching pre-F7 behaviour.
    private let frameSealKeyProvider: @MainActor (_ uid: String, _ connectionID: String) -> SymmetricKey?
    private let frameSealAEAD = MediaFrameAEAD()
    private let advertiseTimeout: TimeInterval
    private var advertiseSenderOverride: AdvertiseSender?
    private var mercuryDispatcher: MercuryControlFrameDispatcher?
    private var mercuryControlStreamCloseHandler: MercuryControlStreamCloseHandler?
    private var computerUseControlDispatcher: ControlFrameDispatcher?

    @Published private(set) var lastError: Failure?
    @Published private(set) var inFlightCount: Int = 0
    @Published private(set) var lastReceivedManifestID: String?
    /// Last completed outbound publish — surfaced as a Mercury toast
    /// confirmation in the chat input.
    @Published private(set) var lastSentManifestID: String?

    init(
        service: MediaFileTransferService,
        settingsProvider: @escaping @MainActor () -> Bool,
        controlStreams: MediaControlStreamRegistry? = nil,
        capabilityGate: any MediaCapabilityGate = AlwaysAllowMediaCapabilityGate(),
        frameSealKeyProvider: @escaping @MainActor (_ uid: String, _ connectionID: String) -> SymmetricKey? = { _, _ in nil },
        advertiseTimeout: TimeInterval = 6.0
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
        self.controlStreams = controlStreams
        self.capabilityGate = capabilityGate
        self.frameSealKeyProvider = frameSealKeyProvider
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

    /// Notifies the Mercury router that a peer's long-lived control stream
    /// really closed. Registry invalidation alone is not enough because the
    /// router also owns active mirror/ringing state.
    func setMercuryControlStreamCloseHandler(
        _ handler: @escaping MercuryControlStreamCloseHandler
    ) {
        self.mercuryControlStreamCloseHandler = handler
    }

    /// Android's screen-share viewer shares the long-lived Mercury
    /// control stream for signed phone-control input. Forward those
    /// `control.*` frames into the same Computer Use dispatcher used by
    /// dedicated control streams so Android stays at iOS parity.
    func setComputerUseControlDispatcher(_ dispatcher: ControlFrameDispatcher?) {
        self.computerUseControlDispatcher = dispatcher
    }

    func bootstrapBlobEndpoint() async throws -> IrohEndpointIdentity {
        try await service.bootstrap()
    }

    /// Publish a file from the Mac and emit an advertise frame to the
    /// paired iPhone. Resolution order for the advertise send:
    ///   1. Explicit override (`setAdvertiseSender`) — tests only.
    ///   2. Persistent media control stream via connection-scoped
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
        let snapshot: (url: URL, directory: URL)
        do {
            snapshot = try Self.snapshotForPublish(originalURL: fileURL)
        } catch let failure as Failure {
            lastError = failure
            throw failure
        } catch {
            let failure = Failure.publishFailed(error.localizedDescription)
            lastError = failure
            throw failure
        }
        defer { Self.removeSnapshotDirectory(snapshot.directory) }

        let outboundByteBudget: Int64
        do {
            outboundByteBudget = try Self.fileSizeBytes(at: snapshot.url)
        } catch let failure as Failure {
            lastError = failure
            throw failure
        } catch {
            let failure = Failure.publishFailed(error.localizedDescription)
            lastError = failure
            throw failure
        }
        let admission = await capabilityGate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: outboundByteBudget,
            transferDirection: .outbound
        )
        if case .denied(let reason) = admission {
            let failure = Failure.admissionDenied(reason.rawValue)
            lastError = failure
            throw failure
        }

        incrementFileTransferCount()
        defer { decrementFileTransferCount() }

        let publish: MediaFileTransferService.PublishResult
        do {
            publish = try await service.publish(localFile: snapshot.url, peerDeviceID: peerDeviceID)
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
            try await emitAdvertise(frame: frame, uid: uid, connectionID: connectionID)
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
        uid: String,
        connectionID: String
    ) async throws {
        if let advertiseSenderOverride {
            try await advertiseSenderOverride(frame)
            return
        }
        guard let registry = controlStreams else {
            lastError = .dispatchUnavailable
            throw Failure.dispatchUnavailable
        }
        guard let stream = await registry.awaitStream(
            uid: uid,
            connectionID: connectionID,
            timeout: advertiseTimeout
        ) else {
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
        guard let registry = controlStreams else {
            // Misconfigured — no registry to register with. Close
            // defensively so we don't leak the stream.
            await stream.close()
            return
        }
        let lease = await registry.register(stream: stream, uid: uid, connectionID: connectionID)
        Self.log.info("mac_control_stream_mounted connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("mac_control_stream_mounted connectionID=\(connectionID)")
        let sendGate = MercuryControlStreamSendGate(stream: stream)
        // Bind a Sendable ack-sender to the same stream so inbound
        // advertise frames can write their ack back over the same path
        // the dispatcher expects. The gate is shared by mirror acks,
        // presence replies, Remote Unlock responses, and video frames so
        // concurrent writers cannot corrupt the single bi-stream.
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { [sendGate] outbound in
            try await sendGate.send(outbound)
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
                     .mediaMirrorDisplaySelect,
                     .mediaPresenceHeartbeat,
                     .mediaLongTermReferenceAck,
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
                        await mercuryDispatcher(frame, lease.id, lease.remotePeerNodeId, ackSender)
                    } else {
                        Self.log.error("mac_control_stream_missing_mercury_dispatcher type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public)")
                        Self.debugTrace("mac_control_stream_missing_mercury_dispatcher type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "")")
                    }
                case .controlClassify,
                     .controlActionLogEntry,
                     .controlInputIntent,
                     .controlApprovalRequest,
                     .controlApprovalResponse,
                     .controlAgentGrantRequest,
                     .controlAgentGrantReceipt,
                     .controlClipboardRequest,
                     .controlClipboardResponse,
                     .controlAgentContextTarget,
                     .remoteUnlockSession,
                     .remoteUnlockState,
                     .remoteUnlockInput,
                     .remoteUnlockCredential,
                     .remoteUnlockResult,
                     .remoteUnlockDenied,
                     .controlDenied:
                    if let computerUseControlDispatcher {
                        Self.log.info("mac_control_stream_dispatch_computer_use type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public)")
                        Self.debugTrace("mac_control_stream_dispatch_computer_use type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "")")
                        await computerUseControlDispatcher(frame, ackSender)
                    } else {
                        Self.log.error("mac_control_stream_missing_computer_use_dispatcher type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public)")
                        Self.debugTrace("mac_control_stream_missing_computer_use_dispatcher type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "")")
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
        let invalidation = await registry.invalidateWithResult(lease)
        if let mercuryControlStreamCloseHandler {
            await mercuryControlStreamCloseHandler(
                uid,
                connectionID,
                lease.id,
                invalidation.didInvalidate
                    ? invalidation.removedLastStreamForConnection
                    : false
            )
        }
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

        // RR-18 — admit the inbound transfer through the authoritative gate
        // (entitlement + daily cap + kill switch + concurrency) before touching
        // the blob backend, exactly as screen-share/video sessions are admitted.
        // The advertised manifest size feeds the per-day byte cap so a transfer
        // that would blow the daily-in budget is refused with a denial ack
        // rather than fetched first and charged after.
        let admission = await capabilityGate.check(
            feature: .fileTransfer,
            sessionDurationLimitSeconds: nil,
            sessionByteBudget: manifest.size,
            transferDirection: .inbound
        )
        if case .denied(let reason) = admission {
            await sendDenialAck(
                for: manifest,
                frame: frame,
                reason: "media admission denied: \(reason.rawValue)",
                ackSender: ackSender
            )
            return
        }

        let sealKey = frameSealKeyProvider(frame.uid, frame.connectionId)
        guard sealKey != nil else {
            await sendDenialAck(
                for: manifest,
                frame: frame,
                reason: "refusing plaintext landing without a file/session key",
                ackSender: ackSender
            )
            return
        }
        if manifest.size > Self.maxAtRestSealPlaintextBytes {
            await sendDenialAck(
                for: manifest,
                frame: frame,
                reason: "received file is too large for streaming at-rest sealing (\(manifest.size) bytes > \(Self.maxAtRestSealPlaintextBytes) bytes)",
                ackSender: ackSender
            )
            return
        }

        incrementFileTransferCount()
        defer { decrementFileTransferCount() }

        var status: HermesRealtimeRelayMediaAck.Status = .received
        var reason: String?

        var fetchedDestinationURL: URL?
        do {
            let result = try await service.fetch(ticketText: ticket, manifest: manifest)
            fetchedDestinationURL = result.destinationURL
            try Self.applyInboundQuarantine(to: result.destinationURL, manifest: manifest)
            // RR-18 — seal the received bytes at rest under the media session
            // key when one is negotiated, so the file is not plaintext in the
            // sandbox Caches inbox. No key ⇒ keep the prior quarantine-only
            // behaviour rather than failing the transfer. Apply quarantine
            // before sealing so an oversized or malformed plaintext fetch is
            // quarantined even if sealing fails, then re-apply after the atomic
            // replace so the sealed file carries the xattr that survives.
            if let sealKey {
                try sealReceivedFileAtRest(at: result.destinationURL, manifest: manifest, key: sealKey)
                try Self.applyInboundQuarantine(to: result.destinationURL, manifest: manifest)
            }
            lastReceivedManifestID = manifest.manifestId
        } catch let serviceError as MediaFileTransferService.ServiceError {
            status = .rejected
            reason = String(describing: serviceError)
            lastError = .fetchFailed(reason ?? "")
            if let fetchedDestinationURL {
                try? FileManager.default.removeItem(at: fetchedDestinationURL) // try?-ok(best-effort failed fetch cleanup)
            }
        } catch {
            status = .rejected
            reason = error.localizedDescription
            lastError = .fetchFailed(reason ?? "")
            if let fetchedDestinationURL {
                try? FileManager.default.removeItem(at: fetchedDestinationURL) // try?-ok(best-effort failed fetch cleanup)
            }
        }

        await sendAck(
            for: manifest,
            frame: frame,
            status: status,
            reason: reason,
            ackSender: ackSender
        )
    }

    /// Emit a `.rejected` ack without touching the blob backend — used when the
    /// capability gate refuses the inbound transfer (RR-18). The peer sees the
    /// same denial-reason shape it would for a fetch failure, so the chat row
    /// surfaces "media paused" instead of silently dropping the advertise.
    private func sendDenialAck(
        for manifest: HermesRealtimeRelayAttachmentManifest,
        frame: HermesRealtimeRelayFrame,
        reason: String,
        ackSender: AdvertiseSender
    ) async {
        lastError = .fetchFailed(reason)
        await sendAck(
            for: manifest,
            frame: frame,
            status: .rejected,
            reason: reason,
            ackSender: ackSender
        )
    }

    private func sendAck(
        for manifest: HermesRealtimeRelayAttachmentManifest,
        frame: HermesRealtimeRelayFrame,
        status: HermesRealtimeRelayMediaAck.Status,
        reason: String?,
        ackSender: AdvertiseSender
    ) async {
        do {
            try await ackSender(Self.makeAckFrame(
                for: manifest,
                frame: frame,
                status: status,
                reason: reason
            ))
        } catch {
            Self.log.error("media_blob_ack_send_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func makeAckFrame(
        for manifest: HermesRealtimeRelayAttachmentManifest,
        frame: HermesRealtimeRelayFrame,
        status: HermesRealtimeRelayMediaAck.Status,
        reason: String?
    ) -> HermesRealtimeRelayFrame {
        let ack = HermesRealtimeRelayMediaAck(
            manifestId: manifest.manifestId,
            status: status,
            reason: reason
        )
        return HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                ack: ack
            )
        )
    }

    private func incrementFileTransferCount() {
        inFlightCount += 1
        MacMediaActiveSessionRegistry.shared.setCount(inFlightCount, for: .fileTransfer)
    }

    private func decrementFileTransferCount() {
        inFlightCount = max(0, inFlightCount - 1)
        MacMediaActiveSessionRegistry.shared.setCount(inFlightCount, for: .fileTransfer)
    }

    private static func fileSizeBytes(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw Failure.publishFailed("unable to read file size")
        }
        return size.int64Value
    }

    private static func snapshotForPublish(originalURL: URL) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-media-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshotURL = directory.appendingPathComponent(originalURL.lastPathComponent, isDirectory: false)
        do {
            try FileManager.default.copyItem(at: originalURL, to: snapshotURL)
            return (snapshotURL, directory)
        } catch {
            removeSnapshotDirectory(directory)
            throw Failure.publishFailed("snapshot file for publish: \(error.localizedDescription)")
        }
    }

    private static func removeSnapshotDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            AppLogger.sync.error(
                "media_file_transfer_snapshot_cleanup_failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    /// Stream-seal the fetched blob with OBFS1. Never load the whole plaintext.
    private func sealReceivedFileAtRest(
        at url: URL,
        manifest: HermesRealtimeRelayAttachmentManifest,
        key: SymmetricKey
    ) throws {
        let byteCount = try Self.fileSizeBytes(at: url)
        if byteCount <= 64 * 1024 * 1024,
           fileAuthenticatesAsSealedEnvelope(at: url, manifest: manifest, key: key, byteCount: byteCount) {
            return
        }
        guard byteCount <= Self.maxAtRestSealPlaintextBytes else {
            throw Failure.fetchFailed(
                "received file is too large for streaming at-rest sealing (\(byteCount) bytes > \(Self.maxAtRestSealPlaintextBytes) bytes)"
            )
        }
        let chunks = max(1, Int((byteCount + Int64(FileSealAEAD.chunkPlaintextBytes) - 1) / Int64(FileSealAEAD.chunkPlaintextBytes)))
        let header = FileSealAEAD.Header(
            attachmentId: manifest.manifestId,
            totalChunks: chunks,
            plaintextSize: byteCount,
            contentBlake3: manifest.blobHash
        )
        let keyData = PlatformCrypto.symmetricKeyData(key)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).obfs1-tmp")
        try FileSealAEAD.sealFile(from: url, to: tempURL, contentKey: keyData, header: header)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard try FileManager.default.replaceItemAt(url, withItemAt: tempURL) != nil else {
            throw Failure.fetchFailed("at-rest seal atomic replace failed")
        }
    }

    private func fileAuthenticatesAsSealedEnvelope(
        at url: URL,
        manifest: HermesRealtimeRelayAttachmentManifest,
        key: SymmetricKey,
        byteCount: Int64
    ) -> Bool {
        guard byteCount <= Self.maxAtRestSealEnvelopeBytes else { return false }
        do {
            let envelope = try Data(contentsOf: url, options: .mappedIfSafe)
            _ = try frameSealAEAD.open(
                envelope: envelope,
                key: key,
                streamClass: MediaStreamClass.blob.rawValue,
                kind: 0,
                gopID: Self.atRestGopID(for: manifest),
                frameIndex: 0
            )
            return true
        } catch {
            return false
        }
    }

    /// Stable 32-bit AAD discriminator derived from the manifest id so the
    /// at-rest seal is bound to this exact transfer.
    private static func atRestGopID(for manifest: HermesRealtimeRelayAttachmentManifest) -> UInt32 {
        var hash: UInt32 = 2_166_136_261 // FNV-1a offset basis
        for byte in manifest.manifestId.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    private static func applyInboundQuarantine(
        to url: URL,
        manifest: HermesRealtimeRelayAttachmentManifest
    ) throws {
        let timestampHex = String(Int(Date().timeIntervalSince1970), radix: 16)
        let origin = quarantineSafeToken(manifest.peerDeviceId ?? manifest.manifestId)
        let value = "0081;\(timestampHex);OpenBurnBar;\(origin)"
        let data = Data(value.utf8)
        let result = data.withUnsafeBytes { rawBuffer in
            setxattr(
                url.path,
                "com.apple.quarantine",
                rawBuffer.baseAddress,
                data.count,
                0,
                0
            )
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func quarantineSafeToken(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value == 0x2d || scalar.value == 0x5f
                ? String(scalar)
                : "_"
        }.joined()
        return String(filtered.prefix(80))
    }
}

/// Sends encoded Mercury media frames over the already-live `media.control`
/// stream that iOS opened to the Mac. Approval stays on the control stream,
/// and accepted video frames follow as `media.stream.frame` envelopes. When
/// both peers negotiate v2, the base64 payload carries the v2 binary envelope;
/// v1 remains the fallback for older viewers and non-video control surfaces.
final class MercuryControlStreamMediaSink: MediaStreamSink, Sendable {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")
    typealias StreamingCapabilityProvider = @Sendable () -> MercuryStreamingCapabilitySnapshot

    private static let maxInlineEncodedFrameBytes = 320 * 1024
    private static let maxEncodedFrameChunkBytes = 256 * 1024
    private static let cachedStreamingCapabilities =
        MercuryVideoToolboxCapabilityProbe.snapshot(mediaFrameVersions: .v1AndV2)
    static let defaultStreamingCapabilityProvider: StreamingCapabilityProvider = {
        MercuryControlStreamMediaSink.cachedStreamingCapabilities
    }

    enum SinkError: Error, LocalizedError {
        case streamUnavailable

        var errorDescription: String? {
            switch self {
            case .streamUnavailable:
                return "No live Mercury control stream is available."
            }
        }
    }

    private let sendGate: MercuryControlStreamSendGate
    private let uid: String
    private let connectionID: String
    private let streamClass: MediaStreamClass
    private let heartbeatInterval: TimeInterval
    private let extraHeartbeatCapabilities: [String]
    private let streamingCapabilityProvider: StreamingCapabilityProvider
    private let codec = MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes)
    private let frameV2Codec = MediaFrameV2Codec()
    /// F7 — when present, every encoded frame is sealed (MediaFrameAEAD,
    /// position-bound AAD) before chunking; nil keeps the legacy plaintext
    /// lane (pre-F7 peers, or no negotiated media-seal session).
    private let frameSealKey: SymmetricKey?
    private let frameSealAEAD = MediaFrameAEAD()
    private let heartbeatTask = Locked<Task<Void, Never>?>(nil)

    init(
        stream: any IrohRelayStream,
        uid: String,
        connectionID: String,
        streamClass: MediaStreamClass,
        heartbeatInterval: TimeInterval = 2.5,
        extraHeartbeatCapabilities: [String] = [],
        streamingCapabilityProvider: @escaping StreamingCapabilityProvider =
            MercuryControlStreamMediaSink.defaultStreamingCapabilityProvider,
        frameSealKey: SymmetricKey? = nil
    ) {
        self.sendGate = MercuryControlStreamSendGate(stream: stream)
        self.uid = uid
        self.connectionID = connectionID
        self.streamClass = streamClass
        self.heartbeatInterval = heartbeatInterval
        self.extraHeartbeatCapabilities = extraHeartbeatCapabilities
        self.streamingCapabilityProvider = streamingCapabilityProvider
        self.frameSealKey = frameSealKey
        startHeartbeatLoop()
    }

    init(
        sender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void,
        uid: String,
        connectionID: String,
        streamClass: MediaStreamClass,
        heartbeatInterval: TimeInterval = 2.5,
        extraHeartbeatCapabilities: [String] = [],
        streamingCapabilityProvider: @escaping StreamingCapabilityProvider =
            MercuryControlStreamMediaSink.defaultStreamingCapabilityProvider,
        frameSealKey: SymmetricKey? = nil
    ) {
        self.sendGate = MercuryControlStreamSendGate(sender: sender)
        self.uid = uid
        self.connectionID = connectionID
        self.streamClass = streamClass
        self.heartbeatInterval = heartbeatInterval
        self.extraHeartbeatCapabilities = extraHeartbeatCapabilities
        self.streamingCapabilityProvider = streamingCapabilityProvider
        self.frameSealKey = frameSealKey
        startHeartbeatLoop()
    }

    deinit {
        cancelHeartbeatLoop()
    }

    static func make(
        registry: MediaControlStreamRegistry,
        uid: String,
        connectionID: String,
        streamClass: MediaStreamClass,
        extraHeartbeatCapabilities: [String] = []
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
            streamClass: streamClass,
            extraHeartbeatCapabilities: extraHeartbeatCapabilities
        )
    }

    func write(frame: MediaFrame) async {
        do {
            var encoded = try codec.encode(frame)
            var position: HermesRealtimeRelaySealedMediaFramePosition?
            if let frameSealKey {
                encoded = try frameSealAEAD.seal(
                    plaintext: encoded,
                    key: frameSealKey,
                    streamClass: streamClass.rawValue,
                    kind: frame.kind.rawValue,
                    gopID: frame.gopID,
                    frameIndex: frame.frameIndex
                )
                position = HermesRealtimeRelaySealedMediaFramePosition(
                    kind: frame.kind.rawValue,
                    gopId: frame.gopID,
                    frameIndex: frame.frameIndex
                )
            }
            try await sendEncodedFrame(encoded, frameIndex: frame.frameIndex, sealedPosition: position)
        } catch {
            // `MediaStreamSink.write` is intentionally fire-and-forget. The
            // session coordinator owns teardown; a failed send drops this
            // frame without crashing the host app.
            Self.log.error("control_stream_media_frame_send_failed version=v1 connectionID=\(self.connectionID, privacy: .public) frameIndex=\(frame.frameIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func write(frameV2: MediaFrameV2) async {
        do {
            var encoded = try frameV2Codec.encode(frameV2, negotiatedVersion: .v2)
            var position: HermesRealtimeRelaySealedMediaFramePosition?
            if let frameSealKey {
                encoded = try frameSealAEAD.seal(
                    plaintext: encoded,
                    key: frameSealKey,
                    streamClass: streamClass.rawValue,
                    kind: frameV2.kind.rawValue,
                    gopID: frameV2.gopID,
                    frameIndex: frameV2.frameIndex
                )
                position = HermesRealtimeRelaySealedMediaFramePosition(
                    kind: frameV2.kind.rawValue,
                    gopId: frameV2.gopID,
                    frameIndex: frameV2.frameIndex
                )
            }
            try await sendEncodedFrame(encoded, frameIndex: frameV2.frameIndex, sealedPosition: position)
        } catch {
            // `MediaStreamSink.write` is intentionally fire-and-forget. The
            // session coordinator owns teardown; a failed send drops this
            // frame without crashing the host app.
            Self.log.error("control_stream_media_frame_send_failed version=v2 connectionID=\(self.connectionID, privacy: .public) frameIndex=\(frameV2.frameIndex, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func close() async {
        cancelHeartbeatLoop()
    }

    private func cancelHeartbeatLoop() {
        heartbeatTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func sendEncodedFrame(
        _ encoded: Data,
        frameIndex: UInt32,
        sealedPosition: HermesRealtimeRelaySealedMediaFramePosition? = nil
    ) async throws {
        if encoded.count <= Self.maxInlineEncodedFrameBytes {
            try await sendGate.send(makeRelayFrame(
                encodedFrameBase64: encoded.base64EncodedString(),
                sealedPosition: sealedPosition
            ))
            return
        }

        let chunkId = UUID().uuidString
        let chunkCount = Int(ceil(Double(encoded.count) / Double(Self.maxEncodedFrameChunkBytes)))
        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * Self.maxEncodedFrameChunkBytes
            let end = min(encoded.count, start + Self.maxEncodedFrameChunkBytes)
            let chunk = encoded.subdata(in: start..<end)
            let metadata = HermesRealtimeRelayMediaFrameChunk(
                chunkId: chunkId,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount,
                totalBytes: encoded.count
            )
            try await sendGate.send(makeRelayFrame(
                encodedFrameBase64: chunk.base64EncodedString(),
                frameChunk: metadata,
                sealedPosition: sealedPosition
            ))
        }
        Self.log.info("control_stream_media_frame_chunked connectionID=\(self.connectionID, privacy: .public) frameIndex=\(frameIndex, privacy: .public) bytes=\(encoded.count, privacy: .public) chunks=\(chunkCount, privacy: .public)")
    }

    private func makeRelayFrame(
        encodedFrameBase64: String,
        frameChunk: HermesRealtimeRelayMediaFrameChunk? = nil,
        sealedPosition: HermesRealtimeRelaySealedMediaFramePosition? = nil
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaStreamFrame,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: streamClass.rawValue,
                encodedFrameBase64: encodedFrameBase64,
                frameChunk: frameChunk,
                sealedFramePosition: sealedPosition
            )
        )
    }

    private func startHeartbeatLoop() {
        guard heartbeatInterval > 0 else { return }
        heartbeatTask.write(Task { [sendGate, uid, connectionID, streamClass, heartbeatInterval, extraHeartbeatCapabilities, streamingCapabilityProvider] in
            let streamingCapabilities = streamingCapabilityProvider().wireValue
            await Self.sendMirrorHealthHeartbeat(
                sendGate: sendGate,
                uid: uid,
                connectionID: connectionID,
                streamClass: streamClass,
                extraCapabilities: extraHeartbeatCapabilities,
                streamingCapabilities: streamingCapabilities
            )

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval * 1_000_000_000)) // try?-ok(cancellation-only sleep)
                guard !Task.isCancelled else { return }
                await Self.sendMirrorHealthHeartbeat(
                    sendGate: sendGate,
                    uid: uid,
                    connectionID: connectionID,
                    streamClass: streamClass,
                    extraCapabilities: extraHeartbeatCapabilities,
                    streamingCapabilities: streamingCapabilities
                )
            }
        })
    }

    private static func sendMirrorHealthHeartbeat(
        sendGate: MercuryControlStreamSendGate,
        uid: String,
        connectionID: String,
        streamClass: MediaStreamClass,
        extraCapabilities: [String],
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities
    ) async {
        let capabilities = Array(Set([
            MercuryPeer.Feature.mirrorHost.rawValue,
            streamClass.rawValue
        ] + extraCapabilities)).sorted()
        do {
            try await sendGate.send(HermesRealtimeRelayFrame(
                type: .mediaPresenceHeartbeat,
                uid: uid,
                connectionId: connectionID,
                media: HermesRealtimeRelayMediaPayload(
                    presence: HermesRealtimeRelayPresenceHeartbeat(
                        sentAt: Date(),
                        deviceDisplayName: Host.current().localizedName ?? "Mac",
                        capabilities: capabilities,
                        streamingCapabilities: streamingCapabilities
                    )
                )
            ))
        } catch {
            Self.log.error("control_stream_media_heartbeat_failed connectionID=\(connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

private actor MercuryControlStreamSendGate {
    private let sender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    init(stream: any IrohRelayStream) {
        self.sender = { [stream] frame in
            try await stream.send(frame)
        }
    }

    init(sender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void) {
        self.sender = sender
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        try await sender(frame)
    }
}
