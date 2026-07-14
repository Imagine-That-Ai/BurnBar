#if os(Linux)
import Foundation
import OpenBurnBarEngine
import OpenBurnBarMedia

public typealias MercuryLinuxMediaReplySender = @Sendable (HermesRealtimeRelayFrame) async throws -> Void

public actor MercuryLinuxMediaSessionController {
    private struct PendingSession: Sendable {
        var kind: DaemonMediaSessionKind
        var requestID: String
        var uid: String
        var connectionID: String
        var streamClass: String
        var requesterDisplayName: String
        var remotePeerNodeID: String?
        var replySender: MercuryLinuxMediaReplySender?
        var mirrorRequest: HermesRealtimeRelayMirrorRequest?
        var mirrorFrame: HermesRealtimeRelayFrame?
        var requestedAt: Date
    }

    private struct MercuryControlRoute: Sendable {
        var uid: String
        var connectionID: String
        var remotePeerNodeID: String?
        var replySender: MercuryLinuxMediaReplySender?
    }

    private struct FileTransferRecord: Sendable {
        var transferID: String
        var manifestID: String
        var direction: DaemonMediaFileTransferDirection
        var phase: DaemonMediaFileTransferPhase
        var filename: String
        var mime: String
        var size: Int64
        var peer: DaemonMediaPeerSnapshot?
        var progress: DaemonMediaFileTransferProgress
        var localPath: String?
        var errorCode: DaemonMediaFileTransferErrorCode?
        var detail: String?
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
        var manifest: HermesRealtimeRelayAttachmentManifest
        var ticketText: String?
        var route: MercuryControlRoute?
    }

    private let logger: BurnBarDaemonLogger
    private let channel: MercuryLinuxMediaChannel?
    private let fileTransferService: MediaFileTransferService?
    private let downloadDirectoryProvider: @Sendable () -> URL
    private let captureEngine: MercuryLinuxCaptureEngine
    private let captureAdapter: any MercuryLinuxCaptureAdapterProtocol
    private let sealKeyOpener: any MercuryLinuxMediaSealKeyOpening
    private let packetCodec = MediaPacketCodec()
    private let frameAEAD = MediaFrameAEAD()
    private var bitrateController = BitrateController(steps: .screenShare)
    private var mediaFrameSealKey: PlatformSymmetricKey?
    private var phase: DaemonMediaSessionPhase = .idle
    private var pending: PendingSession?
    private var active: PendingSession?
    private var sessionID: String?
    private var startedAt: Date?
    private var updatedAt = Date()
    private var cooldownUntil: Date?
    private var lastPeer: MercuryPeer?
    private var lastControlRoute: MercuryControlRoute?
    private var fileTransfers: [String: FileTransferRecord] = [:]
    private var transferIDsByManifestID: [String: String] = [:]
    private var outboundGOPID: UInt32 = 0
    private var outboundFrameIndex: UInt32 = 0
    private var captureFrameQueue: MercuryLinuxCaptureFrameQueue?
    private var captureFrameConsumerTask: Task<Void, Never>?

    public init(
        channel: MercuryLinuxMediaChannel? = nil,
        fileTransferService: MediaFileTransferService? = nil,
        downloadDirectoryProvider: @escaping @Sendable () -> URL = {
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
        },
        captureEngine: MercuryLinuxCaptureEngine = MercuryLinuxCaptureEngine(),
        captureAdapter: (any MercuryLinuxCaptureAdapterProtocol)? = nil,
        sealKeyOpener: any MercuryLinuxMediaSealKeyOpening = MercuryLinuxMediaSealKeyOpener(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-media")
    ) {
        self.logger = logger
        self.channel = channel ?? (try? MercuryLinuxMediaChannel())
        self.fileTransferService = fileTransferService
        self.downloadDirectoryProvider = downloadDirectoryProvider
        self.captureEngine = captureEngine
        self.captureAdapter = captureAdapter ?? MercuryLinuxCaptureAdapter(captureEngine: captureEngine)
        self.sealKeyOpener = sealKeyOpener
    }

    public func start() throws {
        guard let channel else {
            throw MercuryLinuxMediaChannel.ChannelError.runtimeDirectoryUnavailable
        }
        try channel.start()
    }

    public func stop() {
        stopCaptureFramePump()
        captureAdapter.stopOutboundCapture()
        captureEngine.stop()
        channel?.stop()
        phase = .idle
        pending = nil
        active = nil
        sessionID = nil
        startedAt = nil
        cooldownUntil = nil
        lastControlRoute = nil
        mediaFrameSealKey = nil
        outboundGOPID = 0
        outboundFrameIndex = 0
        updatedAt = Date()
    }

    public func setMediaFrameSealKey(_ key: PlatformSymmetricKey?) {
        mediaFrameSealKey = key
    }

    public func ingestMercuryFrame(
        _ frame: HermesRealtimeRelayFrame,
        remotePeerNodeID: String? = nil,
        replySender: MercuryLinuxMediaReplySender? = nil
    ) async {
        recordControlRoute(frame: frame, remotePeerNodeID: remotePeerNodeID, replySender: replySender)
        switch frame.type {
        case .mediaPresenceHeartbeat:
            ingestPresence(frame)
        case .mediaMirrorRequest:
            ingestMirrorRequest(frame, remotePeerNodeID: remotePeerNodeID, replySender: replySender)
        case .mediaCallInvite:
            ingestCallInvite(frame, remotePeerNodeID: remotePeerNodeID, replySender: replySender)
        case .mediaMirrorStop:
            transitionToCooldown(reason: "mirror_stop")
        case .mediaStreamFrame:
            ingestStreamFrame(frame)
        case .mediaBlobAdvertise:
            await ingestFileOffer(frame, remotePeerNodeID: remotePeerNodeID, replySender: replySender)
        case .mediaBlobAck:
            ingestFileAck(frame)
        default:
            break
        }
    }

    public func capability() -> DaemonMediaCapabilityResponse {
        guard let channel else {
            return DaemonMediaCapabilityResponse(
                platform: "linux",
                available: false,
                mediaSocketPath: nil,
                supportsDaemonToShellFrames: false,
                supportsShellToDaemonControl: false,
                codecsKnown: false,
                codecs: [:],
                source: "MercuryLinuxCapabilityProbe.stub",
                detail: "XDG_RUNTIME_DIR is not set; media socket is unavailable."
            )
        }
        return MercuryLinuxCapabilityProbe.snapshot(mediaSocketPath: channel.snapshot().socketPath)
    }

    public func status() -> DaemonMediaStatusResponse {
        DaemonMediaStatusResponse(
            capability: capability(),
            session: sessionSnapshot()
        )
    }

    public func sessionSnapshot() -> DaemonMediaSessionSnapshot {
        let channelSnapshot = channel?.snapshot()
        let current = active ?? pending
        return DaemonMediaSessionSnapshot(
            phase: effectivePhase(now: Date()),
            kind: current?.kind,
            sessionID: sessionID,
            requestID: current?.requestID,
            streamClass: current?.streamClass,
            peer: peerSnapshot(for: current),
            startedAt: startedAt,
            updatedAt: updatedAt,
            cooldownUntil: cooldownUntil,
            shellConnected: channelSnapshot?.shellConnected ?? false,
            queuedFrameCount: channelSnapshot?.queuedFrameCount ?? 0,
            droppedFrameCount: channelSnapshot?.droppedFrameCount ?? 0
        )
    }

    public func accept(_ request: DaemonMediaCallAcceptRequest) async -> DaemonMediaCallActionResponse {
        guard let pending, phase == .ringing else {
            return DaemonMediaCallActionResponse(
                accepted: false,
                session: sessionSnapshot(),
                detail: "No pending Mercury media session is ringing."
            )
        }
        if let requestedID = request.requestID, requestedID != pending.requestID {
            return DaemonMediaCallActionResponse(
                accepted: false,
                session: sessionSnapshot(),
                detail: "Pending Mercury request id does not match."
            )
        }

        let resolvedSessionID = request.sessionID ?? UUID().uuidString
        var establishedSealKey: PlatformSymmetricKey?
        if pending.kind == .mirror {
            guard let mirrorRequest = pending.mirrorRequest,
                  let mirrorFrame = pending.mirrorFrame else {
                await sendDecision(
                    for: pending,
                    accepted: false,
                    sessionID: nil,
                    detail: "Mirror request metadata is unavailable."
                )
                transitionToCooldown(reason: "missing_mirror_request")
                return DaemonMediaCallActionResponse(
                    accepted: false,
                    session: sessionSnapshot(),
                    detail: "Mirror request metadata is unavailable."
                )
            }
            do {
                establishedSealKey = try await sealKeyOpener.openMediaFrameSealKey(
                    for: mirrorRequest,
                    frame: mirrorFrame
                )
            } catch {
                await sendDecision(
                    for: pending,
                    accepted: false,
                    sessionID: nil,
                    detail: "Media frame seal key was not established."
                )
                transitionToCooldown(reason: "seal_not_established")
                return DaemonMediaCallActionResponse(
                    accepted: false,
                    session: sessionSnapshot(),
                    detail: "Media frame seal key was not established."
                )
            }
        }

        self.pending = nil
        self.active = pending
        self.sessionID = resolvedSessionID
        self.phase = .streaming
        self.startedAt = Date()
        self.cooldownUntil = nil
        self.mediaFrameSealKey = establishedSealKey
        self.outboundGOPID = 0
        self.outboundFrameIndex = 0
        self.updatedAt = Date()
        if pending.kind == .mirror {
            do {
                try await startPortalCaptureForActiveMirror()
            } catch {
                await sendDecision(
                    for: pending,
                    accepted: false,
                    sessionID: nil,
                    detail: "Linux ScreenCast capture did not start."
                )
                transitionToCooldown(reason: "capture_start_failed")
                return DaemonMediaCallActionResponse(
                    accepted: false,
                    session: sessionSnapshot(),
                    detail: "Linux ScreenCast capture did not start."
                )
            }
        }
        await sendDecision(for: pending, accepted: true, sessionID: resolvedSessionID, detail: nil)
        return DaemonMediaCallActionResponse(accepted: true, session: sessionSnapshot())
    }

    public func startOutboundCapture(_ request: MercuryLinuxCaptureRequest) throws {
        guard phase == .streaming,
              let active,
              active.kind == .mirror else {
            throw MercuryLinuxCaptureError.sessionNotStreaming
        }
        let queue = startCaptureFramePump()
        try captureEngine.start(
            request,
            onFrame: { frame in
                queue.offer(frame)
            },
            onStopped: { [weak self] _ in
                Task { await self?.capturePipelineEnded(reason: "capture_pipeline_ended") }
            }
        )
        updatedAt = Date()
    }

    public func stopOutboundCapture() {
        stopCaptureFramePump()
        captureAdapter.stopOutboundCapture()
        captureEngine.stop()
    }

    public func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws {
        try captureAdapter.setOutboundCaptureBitrate(targetBitrateBps)
        updatedAt = Date()
    }

    public func ingestBandwidthSample(_ sample: BitrateController.Sample) throws {
        let next = bitrateController.apply(sample: sample)
        try setOutboundCaptureBitrate(UInt32(max(0, next)))
    }

    private func startPortalCaptureForActiveMirror() async throws {
        let queue = startCaptureFramePump()
        try await captureAdapter.startOutboundCapture(
            targetBitrateBps: UInt32(max(0, bitrateController.currentBitsPerSecond)),
            codec: .vp9,
            onFrame: { frame in
                queue.offer(frame)
            },
            onStopped: { [weak self] _ in
                Task { await self?.capturePipelineEnded(reason: "capture_pipeline_ended") }
            }
        )
    }

    private func startCaptureFramePump() -> MercuryLinuxCaptureFrameQueue {
        stopCaptureFramePump()
        let queue = MercuryLinuxCaptureFrameQueue(bufferingNewest: 30)
        captureFrameQueue = queue
        captureFrameConsumerTask = Task { [weak self, queue] in
            for await frame in queue.stream {
                await self?.ingestCapturedFrame(frame)
            }
        }
        return queue
    }

    private func stopCaptureFramePump() {
        captureFrameQueue?.finish()
        captureFrameQueue = nil
        captureFrameConsumerTask?.cancel()
        captureFrameConsumerTask = nil
    }

    private func capturePipelineEnded(reason: String) {
        _ = reason
        transitionToCooldown(reason: "capture_pipeline_ended")
    }

    public func ingestCapturedFrame(_ frame: MediaFrame) async {
        guard phase == .streaming,
              let active,
              active.kind == .mirror,
              let replySender = active.replySender else {
            return
        }

        var outbound = frame
        if outbound.flags.contains(.keyframe) {
            outboundGOPID &+= 1
            outboundFrameIndex = 0
        }
        outbound.gopID = outboundGOPID
        outbound.frameIndex = outboundFrameIndex
        outboundFrameIndex &+= 1

        // Fail closed: never egress a captured frame unsealed. If the media
        // seal key was not established for this session, drop to cooldown
        // rather than send plaintext over the relay (mirrors the inbound path).
        guard let mediaFrameSealKey else {
            logger.error("linux_media_outbound_seal_key_absent; ending capture session")
            transitionToCooldown(reason: "seal_not_established")
            return
        }

        do {
            var encoded = try packetCodec.encode(outbound)
            var sealedPosition: HermesRealtimeRelaySealedMediaFramePosition?
            do {
                encoded = try frameAEAD.seal(
                    plaintext: encoded,
                    key: mediaFrameSealKey,
                    streamClass: active.streamClass,
                    kind: outbound.kind.rawValue,
                    gopID: outbound.gopID,
                    frameIndex: outbound.frameIndex
                )
                sealedPosition = HermesRealtimeRelaySealedMediaFramePosition(
                    kind: outbound.kind.rawValue,
                    gopId: outbound.gopID,
                    frameIndex: outbound.frameIndex
                )
            }
            try await replySender(HermesRealtimeRelayFrame(
                type: .mediaStreamFrame,
                uid: active.uid,
                connectionId: active.connectionID,
                media: HermesRealtimeRelayMediaPayload(
                    streamClass: active.streamClass,
                    encodedFrameBase64: encoded.base64EncodedString(),
                    sealedFramePosition: sealedPosition
                )
            ))
            updatedAt = Date()
        } catch {
            logger.warning(
                "linux_media_capture_frame_forward_failed",
                metadata: ["error": "\(error)"]
            )
        }
    }

    public func decline(_ request: DaemonMediaCallDeclineRequest) async -> DaemonMediaCallActionResponse {
        guard let pending, phase == .ringing else {
            return DaemonMediaCallActionResponse(
                accepted: false,
                session: sessionSnapshot(),
                detail: "No pending Mercury media session is ringing."
            )
        }
        if let requestedID = request.requestID, requestedID != pending.requestID {
            return DaemonMediaCallActionResponse(
                accepted: false,
                session: sessionSnapshot(),
                detail: "Pending Mercury request id does not match."
            )
        }
        await sendDecision(for: pending, accepted: false, sessionID: nil, detail: request.reason)
        transitionToCooldown(reason: request.reason ?? "declined")
        return DaemonMediaCallActionResponse(accepted: true, session: sessionSnapshot())
    }

    public func end(_ request: DaemonMediaCallEndRequest) -> DaemonMediaCallActionResponse {
        if let requestedSession = request.sessionID,
           let currentSession = sessionID,
           requestedSession != currentSession {
            return DaemonMediaCallActionResponse(
                accepted: false,
                session: sessionSnapshot(),
                detail: "Active Mercury session id does not match."
            )
        }
        transitionToCooldown(reason: request.reason ?? "ended")
        return DaemonMediaCallActionResponse(accepted: true, session: sessionSnapshot())
    }

    public func fileOfferList() -> DaemonMediaFileOfferListResponse {
        let sorted = fileTransfers.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.transferID < rhs.transferID
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        return DaemonMediaFileOfferListResponse(
            capabilityAvailable: fileTransferService != nil,
            downloadDirectory: fileTransferService == nil ? nil : downloadDirectoryProvider().path,
            transfers: sorted.map(snapshot(for:)),
            detail: fileTransferService == nil ? "Linux Mercury file transfer engine is unavailable." : nil
        )
    }

    public func acceptFile(_ request: DaemonMediaFileAcceptRequest) async -> DaemonMediaFileActionResponse {
        guard fileTransferService != nil else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .capabilityAbsent,
                detail: "Linux Mercury file transfer engine is unavailable."
            )
        }
        guard let transferID = resolveTransferID(transferID: request.transferID, manifestID: request.manifestID),
              var record = fileTransfers[transferID],
              record.direction == .inbound,
              record.phase == .pendingAccept else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .transferNotFound,
                detail: "No pending Mercury file offer matches the request."
            )
        }
        guard record.ticketText != nil else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                transfer: snapshot(for: record),
                errorCode: .invalidRequest,
                detail: "The pending file offer is missing an iroh blob ticket."
            )
        }
        guard record.route?.replySender != nil else {
            record.phase = .failed
            record.errorCode = .noControlRoute
            record.detail = "No Mercury control route is available for the file acknowledgement."
            record.updatedAt = Date()
            fileTransfers[transferID] = record
            return DaemonMediaFileActionResponse(
                accepted: false,
                transfer: snapshot(for: record),
                errorCode: .noControlRoute,
                detail: record.detail
            )
        }

        let destinationURL: URL
        do {
            destinationURL = try Self.collisionSafeDownloadURL(
                filename: record.filename,
                in: downloadDirectoryProvider()
            )
        } catch {
            record.phase = .failed
            record.errorCode = .ioFailed
            record.detail = "Could not reserve a destination path in Downloads."
            record.updatedAt = Date()
            fileTransfers[transferID] = record
            return DaemonMediaFileActionResponse(
                accepted: false,
                transfer: snapshot(for: record),
                errorCode: .ioFailed,
                detail: record.detail
            )
        }

        let now = Date()
        record.phase = .downloading
        record.localPath = destinationURL.path
        record.errorCode = nil
        record.detail = nil
        record.updatedAt = now
        record.progress = Self.progress(bytesTransferred: 0, bytesTotal: record.size)
        fileTransfers[transferID] = record

        Task { [transferID, destinationURL] in
            await self.performAcceptedFileDownload(transferID: transferID, destinationURL: destinationURL)
        }

        return DaemonMediaFileActionResponse(accepted: true, transfer: snapshot(for: record))
    }

    public func declineFile(_ request: DaemonMediaFileDeclineRequest) async -> DaemonMediaFileActionResponse {
        guard let transferID = resolveTransferID(transferID: request.transferID, manifestID: request.manifestID),
              var record = fileTransfers[transferID],
              record.direction == .inbound,
              record.phase == .pendingAccept else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .transferNotFound,
                detail: "No pending Mercury file offer matches the request."
            )
        }

        let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        record.phase = .declined
        record.detail = reason?.isEmpty == false ? reason : "Declined on Linux."
        record.errorCode = nil
        record.updatedAt = now
        record.completedAt = now
        fileTransfers[transferID] = record

        await sendFileAck(
            route: record.route,
            manifest: record.manifest,
            status: .rejected,
            reason: record.detail
        )
        return DaemonMediaFileActionResponse(accepted: true, transfer: snapshot(for: record))
    }

    public func sendFile(_ request: DaemonMediaFileSendRequest) async -> DaemonMediaFileActionResponse {
        guard let service = fileTransferService else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .capabilityAbsent,
                detail: "Linux Mercury file transfer engine is unavailable."
            )
        }
        let trimmedPath = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .invalidRequest,
                detail: "A local file path is required."
            )
        }

        let fileURL = URL(fileURLWithPath: trimmedPath, isDirectory: false)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .localFileMissing,
                detail: "The selected local file does not exist."
            )
        }
        guard let route = lastControlRoute, route.replySender != nil else {
            return DaemonMediaFileActionResponse(
                accepted: false,
                errorCode: .noControlRoute,
                detail: "No Mercury control route is available for file advertise."
            )
        }

        let transferID = "file_" + UUID().uuidString.lowercased()
        let now = Date()
        let size = Self.fileSize(at: fileURL)
        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: transferID,
            blobHash: "",
            filename: fileURL.lastPathComponent,
            mime: Self.inferMime(for: fileURL),
            size: size,
            peerDeviceId: request.peerID,
            createdAt: now
        )
        let record = FileTransferRecord(
            transferID: transferID,
            manifestID: manifest.manifestId,
            direction: .outbound,
            phase: .sending,
            filename: manifest.filename,
            mime: manifest.mime,
            size: manifest.size,
            peer: peerSnapshot(for: route),
            progress: Self.progress(bytesTransferred: 0, bytesTotal: manifest.size),
            localPath: fileURL.path,
            errorCode: nil,
            detail: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            manifest: manifest,
            ticketText: nil,
            route: route
        )
        fileTransfers[transferID] = record
        transferIDsByManifestID[manifest.manifestId] = transferID

        Task { [service, transferID, fileURL, peerDeviceID = request.peerID, route] in
            await self.performOutboundFileSend(
                transferID: transferID,
                fileURL: fileURL,
                peerDeviceID: peerDeviceID,
                route: route,
                service: service
            )
        }

        return DaemonMediaFileActionResponse(accepted: true, transfer: snapshot(for: record))
    }

    private func recordControlRoute(
        frame: HermesRealtimeRelayFrame,
        remotePeerNodeID: String?,
        replySender: MercuryLinuxMediaReplySender?
    ) {
        guard replySender != nil else { return }
        lastControlRoute = MercuryControlRoute(
            uid: frame.uid,
            connectionID: frame.connectionId,
            remotePeerNodeID: remotePeerNodeID,
            replySender: replySender
        )
    }

    private func ingestFileOffer(
        _ frame: HermesRealtimeRelayFrame,
        remotePeerNodeID: String?,
        replySender: MercuryLinuxMediaReplySender?
    ) async {
        guard let media = frame.media,
              let manifest = media.attachment,
              let ticket = media.blobTicket,
              ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }

        let now = Date()
        let transferID = transferIDsByManifestID[manifest.manifestId] ?? "file_" + manifest.manifestId
        let route = MercuryControlRoute(
            uid: frame.uid,
            connectionID: frame.connectionId,
            remotePeerNodeID: remotePeerNodeID,
            replySender: replySender
        )
        let peer = peerSnapshot(for: route)
        var record = FileTransferRecord(
            transferID: transferID,
            manifestID: manifest.manifestId,
            direction: .inbound,
            phase: .pendingAccept,
            filename: manifest.filename,
            mime: manifest.mime,
            size: manifest.size,
            peer: peer,
            progress: Self.progress(bytesTransferred: 0, bytesTotal: manifest.size),
            localPath: nil,
            errorCode: nil,
            detail: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            manifest: manifest,
            ticketText: ticket,
            route: route
        )

        transferIDsByManifestID[manifest.manifestId] = transferID
        if fileTransferService == nil {
            record.phase = .failed
            record.errorCode = .capabilityAbsent
            record.detail = "Linux Mercury file transfer engine is unavailable."
            record.completedAt = now
            fileTransfers[transferID] = record
            await sendFileAck(
                route: route,
                manifest: manifest,
                status: .rejected,
                reason: "capability absent"
            )
            return
        }

        fileTransfers[transferID] = record
        updatedAt = now
    }

    private func ingestFileAck(_ frame: HermesRealtimeRelayFrame) {
        guard let ack = frame.media?.ack,
              let transferID = transferIDsByManifestID[ack.manifestId],
              var record = fileTransfers[transferID],
              record.direction == .outbound else {
            return
        }

        let now = Date()
        switch ack.status {
        case .received:
            record.phase = .completed
            record.progress = Self.progress(bytesTransferred: record.size, bytesTotal: record.size)
            record.errorCode = nil
            record.detail = nil
            record.completedAt = now
        case .rejected:
            record.phase = .failed
            record.errorCode = .peerRejected
            record.detail = ack.reason ?? "Peer rejected the file transfer."
            record.completedAt = now
        }
        record.updatedAt = now
        fileTransfers[transferID] = record
    }

    private func performAcceptedFileDownload(transferID: String, destinationURL: URL) async {
        guard let service = fileTransferService,
              let record = fileTransfers[transferID],
              let ticket = record.ticketText else {
            return
        }

        let manifest = record.manifest
        let route = record.route
        let progressTask = Task { [transferID, destinationURL, totalBytes = record.size] in
            await self.pollDownloadProgress(
                transferID: transferID,
                destinationURL: destinationURL,
                totalBytes: totalBytes
            )
        }
        defer { progressTask.cancel() }

        do {
            let result = try await service.fetch(
                ticketText: ticket,
                manifest: manifest,
                destinationURL: destinationURL
            )
            let completedBytes = Int64(max(
                result.stats.bytesTotal,
                UInt64(max(0, Self.fileSize(at: result.destinationURL)))
            ))
            var completed = fileTransfers[transferID] ?? record
            let now = Date()
            completed.phase = .completed
            completed.progress = Self.progress(bytesTransferred: completedBytes, bytesTotal: completed.size)
            completed.localPath = result.destinationURL.path
            completed.errorCode = nil
            completed.detail = nil
            completed.updatedAt = now
            completed.completedAt = now
            fileTransfers[transferID] = completed
            await sendFileAck(route: route, manifest: manifest, status: .received, reason: nil)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            var failed = fileTransfers[transferID] ?? record
            let now = Date()
            failed.phase = .failed
            failed.errorCode = .fetchFailed
            failed.detail = "Fetch failed."
            failed.updatedAt = now
            failed.completedAt = now
            fileTransfers[transferID] = failed
            await sendFileAck(route: route, manifest: manifest, status: .rejected, reason: "fetch failed")
        }
    }

    private func performOutboundFileSend(
        transferID: String,
        fileURL: URL,
        peerDeviceID: String?,
        route: MercuryControlRoute,
        service: MediaFileTransferService
    ) async {
        do {
            let publish = try await service.publish(localFile: fileURL, peerDeviceID: peerDeviceID)
            let frame = HermesRealtimeRelayFrame(
                type: .mediaBlobAdvertise,
                uid: route.uid,
                connectionId: route.connectionID,
                requestId: publish.manifest.manifestId,
                media: HermesRealtimeRelayMediaPayload(
                    streamClass: MediaStreamClass.blobAdvertise.rawValue,
                    attachment: publish.manifest,
                    blobTicket: publish.ticketText
                )
            )
            guard let replySender = route.replySender else {
                throw FileTransferRuntimeError.noControlRoute
            }
            try await replySender(frame)

            var record = fileTransfers[transferID]
            if var updated = record {
                transferIDsByManifestID.removeValue(forKey: updated.manifestID)
                transferIDsByManifestID[publish.manifest.manifestId] = transferID
                updated.manifestID = publish.manifest.manifestId
                updated.manifest = publish.manifest
                updated.ticketText = publish.ticketText
                updated.filename = publish.manifest.filename
                updated.mime = publish.manifest.mime
                updated.size = publish.manifest.size
                updated.phase = .offered
                updated.progress = Self.progress(
                    bytesTransferred: publish.manifest.size,
                    bytesTotal: publish.manifest.size
                )
                updated.updatedAt = Date()
                updated.errorCode = nil
                updated.detail = nil
                record = updated
            }
            if let record {
                fileTransfers[transferID] = record
            }
        } catch let error as MediaFileTransferService.ServiceError {
            markOutboundTransferFailed(transferID: transferID, errorCode: Self.errorCode(for: error))
        } catch FileTransferRuntimeError.noControlRoute {
            markOutboundTransferFailed(transferID: transferID, errorCode: .noControlRoute)
        } catch {
            markOutboundTransferFailed(transferID: transferID, errorCode: .publishFailed)
        }
    }

    private func pollDownloadProgress(
        transferID: String,
        destinationURL: URL,
        totalBytes: Int64
    ) async {
        while Task.isCancelled == false {
            if var record = fileTransfers[transferID], record.phase == .downloading {
                let bytes = Self.fileSize(at: destinationURL)
                record.progress = Self.progress(bytesTransferred: bytes, bytesTotal: totalBytes)
                record.updatedAt = Date()
                fileTransfers[transferID] = record
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private enum FileTransferRuntimeError: Error {
        case noControlRoute
    }

    private func ingestPresence(_ frame: HermesRealtimeRelayFrame) {
        guard let presence = frame.media?.presence else { return }
        lastPeer = MercuryPeer(
            connectionID: frame.connectionId,
            displayName: presence.deviceDisplayName,
            isOnline: true,
            lastSeenAt: Date(),
            capabilities: Set(presence.capabilities.compactMap(MercuryPeer.Feature.init(rawValue:))),
            blurredWallpaperBase64: presence.blurredWallpaperBase64
        )
        updatedAt = Date()
    }

    private func ingestMirrorRequest(
        _ frame: HermesRealtimeRelayFrame,
        remotePeerNodeID: String?,
        replySender: MercuryLinuxMediaReplySender?
    ) {
        guard let request = frame.media?.mirrorRequest else { return }
        let now = Date()
        guard effectivePhase(now: now) != .streaming else {
            Task { await sendBusyMirrorAck(frame: frame, request: request, replySender: replySender) }
            return
        }
        pending = PendingSession(
            kind: .mirror,
            requestID: request.requestId,
            uid: frame.uid,
            connectionID: frame.connectionId,
            streamClass: request.streamClass,
            requesterDisplayName: request.requesterDisplayName,
            remotePeerNodeID: remotePeerNodeID,
            replySender: replySender,
            mirrorRequest: request,
            mirrorFrame: frame,
            requestedAt: request.requestedAt
        )
        lastPeer = MercuryPeer(
            connectionID: frame.connectionId,
            displayName: request.requesterDisplayName,
            isOnline: true,
            lastSeenAt: now,
            capabilities: MercuryPeer.iphoneFallbackCapabilities
        )
        phase = .ringing
        sessionID = nil
        startedAt = nil
        cooldownUntil = nil
        outboundGOPID = 0
        outboundFrameIndex = 0
        updatedAt = now
    }

    private func ingestCallInvite(
        _ frame: HermesRealtimeRelayFrame,
        remotePeerNodeID: String?,
        replySender: MercuryLinuxMediaReplySender?
    ) {
        guard let invite = frame.media?.callInvite else { return }
        let now = Date()
        guard effectivePhase(now: now) != .streaming else {
            Task { await sendBusyCallAck(frame: frame, invite: invite, replySender: replySender) }
            return
        }
        pending = PendingSession(
            kind: .call,
            requestID: invite.requestId,
            uid: frame.uid,
            connectionID: frame.connectionId,
            streamClass: "media.video.in",
            requesterDisplayName: invite.requesterDisplayName,
            remotePeerNodeID: remotePeerNodeID,
            replySender: replySender,
            mirrorRequest: nil,
            mirrorFrame: nil,
            requestedAt: invite.requestedAt
        )
        lastPeer = MercuryPeer(
            connectionID: frame.connectionId,
            displayName: invite.requesterDisplayName,
            isOnline: true,
            lastSeenAt: now,
            capabilities: MercuryPeer.iphoneFallbackCapabilities
        )
        phase = .ringing
        sessionID = nil
        startedAt = nil
        cooldownUntil = nil
        outboundGOPID = 0
        outboundFrameIndex = 0
        updatedAt = now
    }

    private func ingestStreamFrame(_ frame: HermesRealtimeRelayFrame) {
        guard phase == .streaming,
              let media = frame.media,
              let streamClass = media.streamClass,
              let encodedBase64 = media.encodedFrameBase64,
              let encodedData = Data(base64Encoded: encodedBase64) else {
            return
        }

        let packetData: Data
        if let position = media.sealedFramePosition,
           MediaFrameAEAD.isSealedEnvelope(encodedData) {
            guard let mediaFrameSealKey else {
                return
            }
            do {
                packetData = try frameAEAD.open(
                    envelope: encodedData,
                    key: mediaFrameSealKey,
                    streamClass: streamClass,
                    kind: position.kind,
                    gopID: position.gopId,
                    frameIndex: position.frameIndex
                )
            } catch {
                return
            }
        } else {
            packetData = encodedData
        }

        guard let decoded = try? packetCodec.decode(packetData).frame else {
            return
        }
        _ = channel?.offer(decoded)
        updatedAt = Date()
    }

    private func effectivePhase(now: Date) -> DaemonMediaSessionPhase {
        if phase == .cooldown,
           let cooldownUntil,
           cooldownUntil <= now {
            return .idle
        }
        return phase
    }

    private func transitionToCooldown(reason: String) {
        _ = reason
        stopCaptureFramePump()
        captureAdapter.stopOutboundCapture()
        captureEngine.stop()
        phase = .cooldown
        pending = nil
        active = nil
        sessionID = nil
        startedAt = nil
        cooldownUntil = Date().addingTimeInterval(2)
        mediaFrameSealKey = nil
        outboundGOPID = 0
        outboundFrameIndex = 0
        updatedAt = Date()
    }

    private func resolveTransferID(transferID: String?, manifestID: String?) -> String? {
        if let transferID = transferID?.trimmingCharacters(in: .whitespacesAndNewlines),
           transferID.isEmpty == false,
           fileTransfers[transferID] != nil {
            return transferID
        }
        if let manifestID = manifestID?.trimmingCharacters(in: .whitespacesAndNewlines),
           manifestID.isEmpty == false {
            return transferIDsByManifestID[manifestID]
        }
        return nil
    }

    private func snapshot(for record: FileTransferRecord) -> DaemonMediaFileTransferSnapshot {
        DaemonMediaFileTransferSnapshot(
            transferID: record.transferID,
            manifestID: record.manifestID,
            direction: record.direction,
            phase: record.phase,
            filename: record.filename,
            mime: record.mime,
            size: record.size,
            peer: record.peer,
            progress: record.progress,
            localPath: record.localPath,
            errorCode: record.errorCode,
            detail: record.detail,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            completedAt: record.completedAt
        )
    }

    private func peerSnapshot(for current: PendingSession?) -> DaemonMediaPeerSnapshot? {
        if let peer = lastPeer {
            return DaemonMediaPeerSnapshot(
                connectionID: peer.connectionID,
                displayName: peer.displayName,
                isOnline: peer.isOnline,
                lastSeenAt: peer.lastSeenAt,
                capabilities: peer.capabilities.map(\.rawValue).sorted()
            )
        }
        guard let current else { return nil }
        return DaemonMediaPeerSnapshot(
            connectionID: current.connectionID,
            displayName: current.requesterDisplayName,
            isOnline: true,
            lastSeenAt: updatedAt,
            capabilities: MercuryPeer.iphoneFallbackCapabilities.map(\.rawValue).sorted()
        )
    }

    private func peerSnapshot(for route: MercuryControlRoute) -> DaemonMediaPeerSnapshot? {
        if let peer = lastPeer, peer.connectionID == route.connectionID {
            return DaemonMediaPeerSnapshot(
                connectionID: peer.connectionID,
                displayName: peer.displayName,
                isOnline: peer.isOnline,
                lastSeenAt: peer.lastSeenAt,
                capabilities: peer.capabilities.map(\.rawValue).sorted()
            )
        }
        return DaemonMediaPeerSnapshot(
            connectionID: route.connectionID,
            displayName: route.remotePeerNodeID ?? "Mercury peer",
            isOnline: true,
            lastSeenAt: Date(),
            capabilities: MercuryPeer.iphoneFallbackCapabilities.map(\.rawValue).sorted()
        )
    }

    private func sendFileAck(
        route: MercuryControlRoute?,
        manifest: HermesRealtimeRelayAttachmentManifest,
        status: HermesRealtimeRelayMediaAck.Status,
        reason: String?
    ) async {
        guard let route,
              let replySender = route.replySender else {
            logger.warning("linux_media_file_ack_route_missing", metadata: ["manifest_id": manifest.manifestId])
            return
        }
        let ack = HermesRealtimeRelayMediaAck(
            manifestId: manifest.manifestId,
            status: status,
            reason: reason
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: route.uid,
            connectionId: route.connectionID,
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                ack: ack
            )
        )
        do {
            try await replySender(frame)
        } catch {
            logger.warning("linux_media_file_ack_failed", metadata: ["manifest_id": manifest.manifestId])
        }
    }

    private func markOutboundTransferFailed(
        transferID: String,
        errorCode: DaemonMediaFileTransferErrorCode
    ) {
        guard var record = fileTransfers[transferID] else { return }
        let now = Date()
        record.phase = .failed
        record.errorCode = errorCode
        record.detail = Self.detail(for: errorCode)
        record.updatedAt = now
        record.completedAt = now
        fileTransfers[transferID] = record
    }

    static func collisionSafeDownloadURL(
        filename rawFilename: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = sanitizedFilename(rawFilename)
        let pathExtension = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        let first = directory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: first.path) else {
            return first
        }

        for index in 1...9999 {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(stem) (\(index))"
            } else {
                candidateName = "\(stem) (\(index)).\(pathExtension)"
            }
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) == false {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Mercury File"
        let base = trimmed.isEmpty ? fallback : trimmed
        let scalars = base.unicodeScalars.map { scalar -> Character in
            if scalar.value == 0 || scalar.value == 47 || scalar.value == 58 || scalar.value == 92 {
                return "-"
            }
            return Character(scalar)
        }
        let sanitized = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return sanitized.isEmpty ? fallback : sanitized
    }

    private static func progress(
        bytesTransferred: Int64,
        bytesTotal: Int64
    ) -> DaemonMediaFileTransferProgress {
        let total = max(0, bytesTotal)
        let transferred = min(max(0, bytesTransferred), total == 0 ? max(0, bytesTransferred) : total)
        return DaemonMediaFileTransferProgress(
            bytesTransferred: transferred,
            bytesTotal: total
        )
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func inferMime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "json": return "application/json"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func errorCode(
        for error: MediaFileTransferService.ServiceError
    ) -> DaemonMediaFileTransferErrorCode {
        switch error {
        case .backendUnavailable, .notBootstrapped:
            return .capabilityAbsent
        case .publishFailed:
            return .publishFailed
        case .fetchFailed, .invalidTicket:
            return .fetchFailed
        case .localFileMissing:
            return .localFileMissing
        }
    }

    private static func detail(for errorCode: DaemonMediaFileTransferErrorCode) -> String {
        switch errorCode {
        case .capabilityAbsent:
            return "Linux Mercury file transfer engine is unavailable."
        case .invalidRequest:
            return "The file transfer request is invalid."
        case .transferNotFound:
            return "No matching Mercury file transfer was found."
        case .localFileMissing:
            return "The selected local file does not exist."
        case .noControlRoute:
            return "No Mercury control route is available."
        case .publishFailed:
            return "Publish failed."
        case .fetchFailed:
            return "Fetch failed."
        case .ioFailed:
            return "File system operation failed."
        case .peerRejected:
            return "Peer rejected the file transfer."
        }
    }

    private func sendDecision(
        for pending: PendingSession,
        accepted: Bool,
        sessionID: String?,
        detail: String?
    ) async {
        guard let replySender = pending.replySender else { return }
        let frame: HermesRealtimeRelayFrame
        switch pending.kind {
        case .mirror:
            frame = HermesRealtimeRelayFrame(
                type: .mediaMirrorAck,
                uid: pending.uid,
                connectionId: pending.connectionID,
                requestId: pending.requestID,
                media: HermesRealtimeRelayMediaPayload(
                    mirrorAck: HermesRealtimeRelayMirrorAck(
                        requestId: pending.requestID,
                        decision: accepted ? .accepted : .denied,
                        detail: detail,
                        sessionId: sessionID,
                        streamingCapabilities: nil,
                        mediaFrameSealEstablished: mediaFrameSealKey != nil
                    )
                )
            )
        case .call:
            frame = HermesRealtimeRelayFrame(
                type: .mediaCallAck,
                uid: pending.uid,
                connectionId: pending.connectionID,
                requestId: pending.requestID,
                media: HermesRealtimeRelayMediaPayload(
                    callAck: HermesRealtimeRelayCallAck(
                        requestId: pending.requestID,
                        decision: accepted ? .accepted : .denied,
                        detail: detail
                    )
                )
            )
        }
        do {
            try await replySender(frame)
        } catch {
            logger.warning("linux_media_reply_failed", metadata: ["error": "\(error)"])
        }
    }

    private func sendBusyMirrorAck(
        frame: HermesRealtimeRelayFrame,
        request: HermesRealtimeRelayMirrorRequest,
        replySender: MercuryLinuxMediaReplySender?
    ) async {
        guard let replySender else { return }
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaMirrorAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: request.requestId,
            media: HermesRealtimeRelayMediaPayload(
                mirrorAck: HermesRealtimeRelayMirrorAck(
                    requestId: request.requestId,
                    decision: .busy,
                    detail: "Linux Mercury media is already streaming."
                )
            )
        )
        try? await replySender(outbound)
    }

    private func sendBusyCallAck(
        frame: HermesRealtimeRelayFrame,
        invite: HermesRealtimeRelayCallInvite,
        replySender: MercuryLinuxMediaReplySender?
    ) async {
        guard let replySender else { return }
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaCallAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: invite.requestId,
            media: HermesRealtimeRelayMediaPayload(
                callAck: HermesRealtimeRelayCallAck(
                    requestId: invite.requestId,
                    decision: .busy,
                    detail: "Linux Mercury media is already streaming."
                )
            )
        )
        try? await replySender(outbound)
    }
}
#endif
