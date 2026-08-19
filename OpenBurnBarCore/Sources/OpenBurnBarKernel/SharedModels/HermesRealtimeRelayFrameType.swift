// Hand-written frame/protocol layer for the Hermes realtime relay — the most
// load-bearing cross-platform contract. Locked to packages/hermes-wire-protocol/
// protocol.json by the parity gate (parity.mjs); the payload message types are
// generated from relay-message-types.json into Generated/.

import Foundation

public enum HermesRealtimeRelayProtocol {
    public static let version = 1
    public static let capability = "realtime_relay"
    public static let defaultHostedRelayURLString = ""
    public static let roleHeaderName = "X-OpenBurnBar-Relay-Role"
    public static let hostRoleHeaderValue = "host"
    public static let clientRoleHeaderValue = "client"
}

public enum HermesRealtimeRelayFrameType: String, Codable, Sendable, Equatable {
    case hostRegister = "host.register"
    case hostReady = "host.ready"
    case requestStart = "request.start"
    case requestCancel = "request.cancel"
    case responseChunk = "response.chunk"
    case responseComplete = "response.complete"
    case responseError = "response.error"
    case ping
    case pong
    // Device-to-device Signal Double Ratchet ciphertext carried over the
    // existing iroh relay stream. The opaque ciphertext bytes stay in the
    // top-level signalSessionCiphertextB64 field so the transport remains
    // protocol-aware but crypto-agnostic.
    case signalSessionMessage = "signal.session.message"
    // Mercury media rollout — see plans/2026-05-15-mercury-media-master-plan.md
    // and docs/HERMES_MEDIA_TRANSPORT.md. Older peers skip unknown frame types
    // on the chat stream so adding cases here is forward-compatible.
    case mediaClassify = "media.classify"
    case mediaBlobAdvertise = "media.blob.advertise"
    case mediaBlobAck = "media.blob.ack"
    // Mercury Phase 8 — iOS-initiated mirror request / Mac ack / iOS
    // outbound presence heartbeat. Rides the existing media.control
    // stream; no new ALPN. Same forward-compat contract as the chat
    // frame types.
    case mediaMirrorRequest = "media.mirror.request"
    case mediaMirrorAck = "media.mirror.ack"
    case mediaMirrorStop = "media.mirror.stop"
    case mediaMirrorDisplaySelect = "media.mirror.display.select"
    case mediaPresenceHeartbeat = "media.presence.heartbeat"
    case mediaCallInvite = "media.call.invite"
    case mediaCallAck = "media.call.ack"
    /// Receiver -> encoder acknowledgement for a VideoToolbox LTR token
    /// carried on a decoded MediaFrame v2 video frame. This is inert for
    /// v1 peers and only participates after both peers negotiate v2.
    case mediaLongTermReferenceAck = "media.ltr.ack"
    /// Encoded `OpenBurnBarMedia.MediaFrame` bytes carried over the existing
    /// long-lived `media.control` stream after a mirror request is accepted.
    /// The media payload's `streamClass` identifies the logical receiver
    /// (`media.screen.video`, `control.surface.frame`, etc.).
    case mediaStreamFrame = "media.stream.frame"
    // Computer Use control plane — see
    // plans/2026-05-16-computer-use-master-plan.md. Same
    // forward-compatibility contract as the media frame types.
    case controlClassify = "control.classify"
    case controlActionLogEntry = "control.action.log.entry"
    case controlInputIntent = "control.input.intent"
    case controlApprovalRequest = "control.approval.request"
    case controlApprovalResponse = "control.approval.response"
    case controlSessionGrantChallenge = "control.session.grant.challenge"
    case controlAgentGrantRequest = "control.agent.grant.request"
    case controlAgentGrantReceipt = "control.agent.grant.receipt"
    case controlClipboardRequest = "control.clipboard.request"
    case controlClipboardResponse = "control.clipboard.response"
    case controlDenied = "control.denied"
    case controlAgentContextTarget = "control.agent.context.target"
    // Remote Unlock — human-only Mac unlock lane. These frames are kept
    // separate from Computer Use so agents can never consume credential input.
    case remoteUnlockSession = "remote_unlock.session"
    case remoteUnlockState = "remote_unlock.state"
    case remoteUnlockInput = "remote_unlock.input"
    case remoteUnlockCredential = "remote_unlock.credential"
    case remoteUnlockResult = "remote_unlock.result"
    case remoteUnlockDenied = "remote_unlock.denied"
    // System Permission Concierge — Phase 14. Mac emits status frames when a
    // tool failure is classified as a TCC denial; the phone replies with a
    // signed request asking the Mac to surface the right native prompt /
    // System Settings deep link. Both frames are forward-compatible —
    // older peers skip unknown control frame types.
    case controlSystemPermissionRequest = "control.system.permission.request"
    case controlSystemPermissionStatus = "control.system.permission.status"
    // War Room — the Wire. The encrypted Mac⇄Mac lane
    // (plans/2026-08-17-war-room-master-plan.md). Entitlement-gated to
    // Pro/Ultra and fail-closed: a peer that cannot prove an active
    // war_wire_grant answers `war.denied` and the dispatcher falls back to the
    // Firestore relay rather than degrading silently.
    case warHello = "war.hello"
    case warHelloAck = "war.hello.ack"
    case warFleetSnapshot = "war.fleet.snapshot"
    case warDispatch = "war.dispatch"
    case warDispatchAck = "war.dispatch.ack"
    case warStreamChunk = "war.stream.chunk"
    case warStreamComplete = "war.stream.complete"
    case warDenied = "war.denied"
}
