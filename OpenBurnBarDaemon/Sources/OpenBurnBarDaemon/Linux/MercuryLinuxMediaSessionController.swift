#if os(Linux)
import Foundation
import OpenBurnBarCore
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
        var requestedAt: Date
    }

    private let logger: BurnBarDaemonLogger
    private let channel: MercuryLinuxMediaChannel?
    private let captureEngine: MercuryLinuxCaptureEngine
    private let packetCodec = MediaPacketCodec()
    private let frameAEAD = MediaFrameAEAD()
    private var mediaFrameSealKey: PlatformSymmetricKey?
    private var phase: DaemonMediaSessionPhase = .idle
    private var pending: PendingSession?
    private var active: PendingSession?
    private var sessionID: String?
    private var startedAt: Date?
    private var updatedAt = Date()
    private var cooldownUntil: Date?
    private var lastPeer: MercuryPeer?
    private var outboundGOPID: UInt32 = 0
    private var outboundFrameIndex: UInt32 = 0

    public init(
        channel: MercuryLinuxMediaChannel? = nil,
        captureEngine: MercuryLinuxCaptureEngine = MercuryLinuxCaptureEngine(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "linux-media")
    ) {
        self.logger = logger
        self.channel = channel ?? (try? MercuryLinuxMediaChannel())
        self.captureEngine = captureEngine
    }

    public func start() throws {
        guard let channel else {
            throw MercuryLinuxMediaChannel.ChannelError.runtimeDirectoryUnavailable
        }
        try channel.start()
    }

    public func stop() {
        captureEngine.stop()
        channel?.stop()
        phase = .idle
        pending = nil
        active = nil
        sessionID = nil
        startedAt = nil
        cooldownUntil = nil
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
        self.pending = nil
        self.active = pending
        self.sessionID = resolvedSessionID
        self.phase = .streaming
        self.startedAt = Date()
        self.cooldownUntil = nil
        self.outboundGOPID = 0
        self.outboundFrameIndex = 0
        self.updatedAt = Date()
        await sendDecision(for: pending, accepted: true, sessionID: resolvedSessionID, detail: nil)
        return DaemonMediaCallActionResponse(accepted: true, session: sessionSnapshot())
    }

    public func startOutboundCapture(_ request: MercuryLinuxCaptureRequest) throws {
        guard phase == .streaming,
              let active,
              active.kind == .mirror else {
            throw MercuryLinuxCaptureError.sessionNotStreaming
        }
        try captureEngine.start(request) { [weak self] frame in
            Task { await self?.ingestCapturedFrame(frame) }
        }
        updatedAt = Date()
    }

    public func stopOutboundCapture() {
        captureEngine.stop()
    }

    public func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws {
        try captureEngine.setBitrate(targetBitrateBps)
        updatedAt = Date()
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
            captureEngine.stop()
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
        if let position = media.sealedFramePosition ?? sniffSealedPosition(media: media),
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

    private func sniffSealedPosition(media: HermesRealtimeRelayMediaPayload) -> HermesRealtimeRelaySealedMediaFramePosition? {
        media.sealedFramePosition
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
        captureEngine.stop()
        phase = .cooldown
        pending = nil
        active = nil
        sessionID = nil
        startedAt = nil
        cooldownUntil = Date().addingTimeInterval(2)
        outboundGOPID = 0
        outboundFrameIndex = 0
        updatedAt = Date()
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
