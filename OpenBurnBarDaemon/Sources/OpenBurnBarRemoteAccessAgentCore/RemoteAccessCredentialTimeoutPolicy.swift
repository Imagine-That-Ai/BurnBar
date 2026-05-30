import Foundation

/// Nested timeout + retry budget for the locked-screen credential worker.
///
/// Remote Unlock spans four serialized waits that **must nest** from innermost to outermost.
/// If any layer's deadline is shorter than the layer beneath it, the outer layer tears the
/// connection down before the inner one finishes — which is exactly the bug that made the worker
/// report `login_session_worker_timed_out`: the worker's focus+type sequence ran ~6.3s while the
/// helper killed it at 5s, *before a single password key was posted*. The lock screen flickered
/// (escape/clicks fired) but the password was never typed.
///
/// ```
/// worker work  <  helper→worker exit timeout  <  Mac client socket timeout  <  iPhone ack timeout
/// ```
///
/// The worker-work budget is **derived** from `RemoteAccessCredentialEventSourcePolicy` and
/// `RemoteAccessDisplayWakePolicy` (not a hand-maintained magic number), so the nesting cannot
/// silently regress when a settle delay is tuned. `RemoteAccessCredentialTimeoutPolicyTests`
/// asserts the chain holds with margin.
public enum RemoteAccessCredentialTimeoutPolicy {
    /// Maximum focus+type attempts the worker makes before giving up. A second attempt only runs
    /// while the screen is still *confirmed* locked, so a retry can never type onto an unlocked
    /// desktop after the first attempt already succeeded.
    public static let maximumUnlockAttempts = 2

    /// Upper bound on credential length the worker will type, in keystrokes. Used only to size the
    /// worst-case timing budget below; the real credential length is validated independently and
    /// is far shorter in practice.
    public static let maximumTypedKeyCount = 128

    /// Worst-case duration of a *single* focus+type+verify attempt for a credential of `keyCount`
    /// keystrokes, in microseconds. Pure function of the event-source policy delays.
    public static func singleAttemptMicroseconds(keyCount: Int) -> UInt64 {
        let policy = RemoteAccessCredentialEventSourcePolicy.self
        var total: UInt64 = 0
        total += UInt64(policy.pointerNudgeSettleMicroseconds)
        total += UInt64(policy.escapeSettleMicroseconds)
        total += UInt64(policy.focusClearKeyPresses) * UInt64(policy.focusKeySettleMicroseconds)
        total += UInt64(policy.preTypeSettleMicroseconds)
        total += UInt64(max(0, keyCount)) * UInt64(policy.interCharacterSettleMicroseconds)
        total += UInt64(policy.preReturnSettleMicroseconds)
        total += UInt64(policy.postSubmitVerifyDelayMicroseconds)
        return total
    }

    /// Worst-case duration of the entire worker, including the asleep-display wake settle and every
    /// retry attempt, in microseconds.
    public static func worstCaseWorkerMicroseconds(keyCount: Int = maximumTypedKeyCount) -> UInt64 {
        let wake = UInt64(RemoteAccessDisplayWakePolicy.asleepSettleDelayMicroseconds)
        return wake + UInt64(maximumUnlockAttempts) * singleAttemptMicroseconds(keyCount: keyCount)
    }

    /// How long the helper waits for the credential worker to exit before killing it. A pure
    /// backstop against a genuinely hung worker — it must comfortably exceed the worst-case work so
    /// the worker is never killed mid-typing.
    public static let workerExitTimeoutNanoseconds: UInt64 = 14_000_000_000

    /// How long the Mac app's helper client waits for a socket response. Must exceed the worker
    /// exit timeout so the app never gives up while the helper is still legitimately working.
    /// (Applied as `SO_RCVTIMEO`/`SO_SNDTIMEO` in `RemoteAccessAgentClient`.)
    public static let macClientSocketTimeoutSeconds: Int = 20

    /// How long the iPhone waits for the Mac's unlock result. The outermost layer; mirrored here
    /// from `MercuryLiveSheet.remoteUnlockCredentialAckTimeoutNanoseconds` so the full nesting
    /// invariant is checkable in one place.
    public static let iOSCredentialAckTimeoutNanoseconds: UInt64 = 45_000_000_000
}
