import Foundation

/// Event-source + focus/type sequence policy for the login-window credential worker.
///
/// **Event source.** On macOS 26.5, creating a keyboard event from `.hidSystemState` after the
/// worker is launched into the loginwindow bootstrap can deadlock inside SkyLight before any key is
/// posted. The session source creates keyboard events in that bootstrap without hanging, which is
/// the only place Remote Unlock needs to type while the Mac is locked.
///
/// **Focus/type sequence.** The worker wakes the lock UI with a single pointer *move* (never a
/// click — a mis-aimed click can collapse the password lane), presses Escape to dismiss the
/// Touch-ID affordance, focuses/clears the password lane with a few harmless Backspaces, types the
/// password, then presses Return. Every delay here is deliberately small so the whole sequence —
/// including a retry — fits inside `RemoteAccessCredentialTimeoutPolicy.workerExitTimeoutNanoseconds`.
/// The previous blind "reveal_password_lane" sequence (three coordinate clicks, each followed by
/// backspace/space/backspace with ~400ms settles) ran ~5.35s and was killed by the 5s worker
/// timeout before a single password key was posted.
public enum RemoteAccessCredentialEventSourcePolicy {
    public enum KeyboardEventSource: String, Sendable {
        case combinedSessionState
    }

    public enum KeyboardEventTap: String, Sendable {
        case sessionEventTap
    }

    public static let keyboardEventSource = KeyboardEventSource.combinedSessionState
    public static let keyboardEventTap = KeyboardEventTap.sessionEventTap

    /// The credential worker must not press Return before typing the password.
    ///
    /// Loginwindow treats Return as *submit* when the password field is focused. A pre-type Return
    /// therefore submits an empty credential, shakes the lock screen, and often swallows the real
    /// password that follows. The focus sequence below deliberately contains **no** Return — the
    /// password's own keystrokes focus and fill the field, and the single trailing Return submits it.
    public static let preCredentialSubmitKeyPresses = 0

    /// Center point for a single pointer *move* that wakes the lock UI without activating any
    /// control. We never click here: a click landing on the wrong element (avatar, switch-user,
    /// power button) can collapse or de-focus the password lane.
    public static let pointerNudgePoint = RemoteAccessNormalizedPoint(x: 0.5, y: 0.5)
    public static let pointerNudgeSettleMicroseconds: UInt32 = 180_000

    /// Escape dismisses the transient "Touch ID or enter password" affordance and drops focus onto
    /// the password lane.
    public static let escapeSettleMicroseconds: UInt32 = 200_000

    /// Harmless Backspaces that focus/clear the password lane before typing. Backspace on an empty
    /// field is a no-op and never submits, so the sequence is safe even when focus is already correct
    /// or the field already holds stray characters from a prior partial attempt.
    public static let focusClearKeyPresses = 3
    public static let focusKeySettleMicroseconds: UInt32 = 70_000

    /// Settle before typing the first password key, after the focus sequence completes.
    public static let preTypeSettleMicroseconds: UInt32 = 200_000

    /// Inter-keystroke delay while typing the password. Loginwindow drops keys posted too fast.
    public static let interCharacterSettleMicroseconds: UInt32 = 18_000

    /// Settle between the last password key and the submitting Return.
    public static let preReturnSettleMicroseconds: UInt32 = 150_000

    /// After Return, wait this long for loginwindow to evaluate the credential before reading the
    /// lock state to decide success / whether a second attempt is warranted.
    public static let postSubmitVerifyDelayMicroseconds: UInt32 = 750_000
}

public struct RemoteAccessNormalizedPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
