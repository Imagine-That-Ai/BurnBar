import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

extension MercuryRouter {

    /// Called by the media-control stream owner after the registry entry has
    /// been invalidated. A peer disconnect is semantically the same as that
    /// peer ending any in-flight mirror, but it must not unlock an unrelated
    /// live session.
    func handleControlStreamClosed(
        connectionID: String,
        controlStreamID: UUID? = nil,
        removedLastStreamForConnection: Bool = true
    ) async {
        Self.log.info("router_control_stream_closed connectionID=\(connectionID, privacy: .public) controlStreamID=\(controlStreamID?.uuidString ?? "legacy", privacy: .public) removedLast=\(removedLastStreamForConnection, privacy: .public)")
        Self.debugTrace("router_control_stream_closed connectionID=\(connectionID) controlStreamID=\(controlStreamID?.uuidString ?? "legacy") removedLast=\(removedLastStreamForConnection)")
        if let controlStreamID {
            remoteStreamingCapabilitiesByControlStreamID.removeValue(forKey: controlStreamID)
        }
        if removedLastStreamForConnection {
            remoteStreamingCapabilitiesByConnectionID.removeValue(forKey: connectionID)
            peerSource.handleControlStreamClosed(connectionID: connectionID)
        }

        let pendingMirrorClosed = pendingRequest.map {
            request($0, matchesClosedConnectionID: connectionID, controlStreamID: controlStreamID)
        } ?? false
        let pendingCallClosed = pendingCall.map {
            request($0, matchesClosedConnectionID: connectionID, controlStreamID: controlStreamID)
        } ?? false
        if pendingMirrorClosed { pendingRequest = nil }
        if pendingCallClosed { pendingCall = nil }

        let closedViewer = viewer(matchingConnectionID: connectionID, controlStreamID: controlStreamID)
        let activeMirrorClosed = closedViewer != nil
        if let closedViewer {
            _ = await removeActiveMirrorViewer(viewerID: closedViewer.viewerID)
        }

        switch phase {
        case .ringing where pendingMirrorClosed,
             .callRinging where pendingCallClosed,
             .starting where activeMirrorClosed,
             .streaming where activeMirrorClosed && activeMirrorViewers.isEmpty:
            phase = .idle
        default:
            break
        }
    }

    /// Closure entry point handed to `MacFileTransferService` via
    /// `setMercuryDispatcher`. Routes by frame type. Mirror frames
    /// capture the reply sender in the `PendingRequest` so later
    /// accepts/declines send acks on the correct stream.
    func handleFrame(
        _ frame: HermesRealtimeRelayFrame,
        controlStreamID: UUID? = nil,
        remotePeerNodeID: String? = nil,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        Self.log.info("router_handle_frame type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
        switch frame.type {
        case .mediaPresenceHeartbeat:

            if let heartbeat = frame.media?.presence {
                if let streamingCapabilities = heartbeat.streamingCapabilities {
                    let snapshot = MercuryStreamingCapabilitySnapshot(wire: streamingCapabilities)
                    if let controlStreamID {
                        remoteStreamingCapabilitiesByControlStreamID[controlStreamID] = snapshot
                    } else {
                        remoteStreamingCapabilitiesByConnectionID[frame.connectionId] = snapshot
                    }
                }
                peerSource.ingestHeartbeat(
                    heartbeat,
                    connectionID: frame.connectionId
                )

                // Reply with a lightweight presence heartbeat. The control
                // stream uses this as a liveness probe before mirror setup;
                // keep expensive capability probing and wallpaper transfer out
                // of this path so the stream is still alive for the actual
                // mirror request.
                let macCapabilities = macPresenceCapabilities()
                let responseBeat = HermesRealtimeRelayPresenceHeartbeat(
                    sentAt: Date(),
                    deviceDisplayName: Host.current().localizedName ?? "My Mac",
                    capabilities: macCapabilities,
                    peerDeviceId: frame.connectionId,
                    // F7: the Mac previously never advertised streaming
                    // capabilities back to phones, so phone-side negotiators
                    // (codec, wire version, frame AEAD) had no Mac snapshot.
                    // The probe is cached — no per-beat encoder sessions.
                    streamingCapabilities: localStreamingCapabilityProvider().wireValue,
                    remoteUnlockCapabilities: remoteUnlockReadiness.capabilities()
                )
                let responseFrame = HermesRealtimeRelayFrame(
                    type: .mediaPresenceHeartbeat,
                    uid: frame.uid,
                    connectionId: frame.connectionId,
                    media: HermesRealtimeRelayMediaPayload(presence: responseBeat)
                )
                do {
                    try await replySender(responseFrame)
                    Self.log.info("router_presence_reply_sent connectionID=\(frame.connectionId, privacy: .public)")
                } catch {
                    Self.log.error("router_presence_reply_failed connectionID=\(frame.connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

        case .mediaMirrorRequest:
            await handleMirrorRequest(
                frame: frame,
                controlStreamID: controlStreamID,
                remotePeerNodeID: remotePeerNodeID,
                replySender: replySender
            )
        case .mediaMirrorStop:
            await handleMirrorStop(frame: frame, controlStreamID: controlStreamID)
        case .mediaMirrorDisplaySelect:
            await handleMirrorDisplaySelect(
                frame: frame,
                controlStreamID: controlStreamID,
                replySender: replySender
            )
        case .mediaMirrorAck:
            // Mac is the producer of acks, not the consumer. Ignore.
            break
        case .mediaCallInvite:
            await handleCallInvite(
                frame: frame,
                controlStreamID: controlStreamID,
                replySender: replySender
            )
        case .mediaCallAck:
            // Mac is the producer of call acks, not the consumer. Ignore.
            break
        case .mediaLongTermReferenceAck:
            if let ack = frame.media?.longTermReferenceAck {
                sessionCoordinator.acknowledgeLongTermReferenceToken(
                    MercuryLTRToken(value: ack.tokenValue)
                )
                Self.log.info("router_ltr_ack_received token=\(ack.tokenValue, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
            }
        default:
            break
        }
    }

    func macPresenceCapabilities() -> [String] {
        var capabilities = [
            MercuryPeer.Feature.mirrorHost.rawValue,
            MercuryPeer.Feature.fileSend.rawValue,
            MercuryPeer.Feature.fileReceive.rawValue,
            MercuryPeer.Feature.callReceive.rawValue,
            // F7/F10: advertise the app-layer seal capabilities so phones can
            // negotiate them (both-peers-required gates; plain strings, so
            // pre-F7 peers simply ignore them).
            MediaFrameAeadNegotiation.capability,
            ControlFrameSealNegotiation.capability
        ]
        if remoteUnlockReadiness.capabilities().enabled {
            capabilities.append(MercuryPeer.Feature.remoteUnlockHost.rawValue)
        }
        return capabilities
    }

    /// F7: the Mac's streaming capability snapshot, probed once. The VideoToolbox
    /// probe creates real encoder sessions, so the heartbeat reply must not
    /// re-run it per beat.
    static let cachedLocalStreamingCapabilities: MercuryStreamingCapabilitySnapshot =
        MercuryVideoToolboxCapabilityProbe.snapshot(mediaFrameVersions: .v1AndV2)

}
