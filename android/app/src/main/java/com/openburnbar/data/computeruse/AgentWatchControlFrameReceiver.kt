package com.openburnbar.data.computeruse

import com.openburnbar.irohrelay.HermesRealtimeRelayApprovalRequest
import com.openburnbar.irohrelay.HermesRealtimeRelayControlDenied
import com.openburnbar.irohrelay.HermesRealtimeRelayFrame
import com.openburnbar.irohrelay.HermesRealtimeRelayFrameType

/**
 * RR-7b — Android INGEST receiver for Computer Use `control.*` frames, the analogue of iOS
 * `AgentWatchReceiver.ingest` (OpenBurnBarMobile/.../ComputerUse/AgentWatchReceiver.swift).
 *
 * The transport layer owns iroh bytes; this receiver owns the product state the Compose Agent
 * Watch surface renders by feeding [ComputerUseWatchReducer]. It is intentionally deterministic and
 * side-effect-light so tests can replay raw relay frames without starting iroh or pairing a Mac.
 *
 * The load-bearing fix: parsing an inbound `CONTROL_APPROVAL_REQUEST` and calling
 * [ComputerUseWatchReducer.setPendingApproval] WITH a populated [ComputerUseApprovalRequest.wireRequest].
 * The Compose `sendSignedApproval` path needs that wire request to sign + transmit the response — it
 * was never populated before, so approvals could never be signed over the wire on Android.
 */
class AgentWatchControlFrameReceiver(
    private val reducer: ComputerUseWatchReducer,
    private val uid: String,
    private val connectionId: String,
) {
    /**
     * Reduce a single inbound relay frame into watch state. Frames addressed to a different
     * `uid`/`connectionId` are ignored (mirrors the iOS guard). Unhandled control kinds are no-ops.
     */
    fun ingest(frame: HermesRealtimeRelayFrame) {
        if (frame.uid != uid || frame.connectionId != connectionId) return
        when (frame.type) {
            HermesRealtimeRelayFrameType.CONTROL_CLASSIFY -> {
                frame.control?.sessionId?.let { reducer.startSession(it) }
            }
            HermesRealtimeRelayFrameType.CONTROL_APPROVAL_REQUEST -> {
                val request = frame.control?.approvalRequest ?: return
                reducer.startSession(request.sessionId)
                reducer.setPendingApproval(request.toApprovalRequest())
            }
            HermesRealtimeRelayFrameType.CONTROL_APPROVAL_RESPONSE -> {
                val response = frame.control?.approvalResponse ?: return
                // The Mac (or another phone) already answered — clear our pending prompt if it matches.
                if (reducer.state.value.pendingApproval?.approvalId == response.approvalId) {
                    reducer.setPendingApproval(null)
                }
            }
            HermesRealtimeRelayFrameType.CONTROL_DENIED -> {
                frame.control?.denied?.let { reducer.deny(it.reason.denyReasonValue()) }
            }
            else -> Unit
        }
    }
}

/**
 * Map an inbound relay approval request into the reducer model, carrying the original
 * [HermesRealtimeRelayApprovalRequest] as [ComputerUseApprovalRequest.wireRequest] so the response
 * can be signed against it. `requestedAt` is Swift-reference seconds (2001-01-01 epoch); convert
 * back to Unix millis for the reducer's millis-based timeline.
 */
internal fun HermesRealtimeRelayApprovalRequest.toApprovalRequest(): ComputerUseApprovalRequest =
    ComputerUseApprovalRequest(
        approvalId = approvalId,
        sessionId = sessionId,
        toolKind = toolKind,
        actionSummary = actionSummary,
        requestedAtMillis = ((requestedAt + APPLE_REFERENCE_DATE_EPOCH_SECONDS) * MILLIS_PER_SECOND).toLong(),
        wireRequest = this,
    )

/** Stable string the watch surface shows for a deny reason; matches the relay `@SerialName`s. */
internal fun HermesRealtimeRelayControlDenied.Reason.denyReasonValue(): String =
    when (this) {
        HermesRealtimeRelayControlDenied.Reason.ENTITLEMENT -> "entitlement"
        HermesRealtimeRelayControlDenied.Reason.SESSION_LIMIT -> "session_limit"
        HermesRealtimeRelayControlDenied.Reason.DAILY_LIMIT -> "daily_limit"
        HermesRealtimeRelayControlDenied.Reason.SOFT_CAP -> "soft_cap"
        HermesRealtimeRelayControlDenied.Reason.HARD_CAP -> "hard_cap"
        HermesRealtimeRelayControlDenied.Reason.SCOPE -> "scope"
        HermesRealtimeRelayControlDenied.Reason.DENY_REGION -> "deny_region"
        HermesRealtimeRelayControlDenied.Reason.KILL_SWITCH -> "kill_switch"
        HermesRealtimeRelayControlDenied.Reason.SIGNATURE_FAILURE -> "signature_failure"
        HermesRealtimeRelayControlDenied.Reason.COUNTER_REPLAY -> "counter_replay"
        HermesRealtimeRelayControlDenied.Reason.STALE_TIMESTAMP -> "stale_timestamp"
        HermesRealtimeRelayControlDenied.Reason.AGENT_UNAVAILABLE -> "agent_unavailable"
        else -> "scope"
    }

private const val MILLIS_PER_SECOND = 1_000.0

// Unix seconds at 2001-01-01T00:00:00Z — the Apple/Swift Date reference epoch.
private const val APPLE_REFERENCE_DATE_EPOCH_SECONDS = 978_307_200.0
