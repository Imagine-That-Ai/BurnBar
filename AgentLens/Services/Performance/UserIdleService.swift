import CoreGraphics
import Foundation

// MARK: - UserIdleService
//
// Shared session-idle probe, extracted from `PetCompanionController` (PR6) so
// the usage-memory Stage-1 cadence and the pet's doze behavior read ONE
// definition of "the user is idle". Seconds since the most recent keyboard,
// mouse-move, or click event in the combined session event state — cheap
// (three CGEventSource reads, no polling) and callable from any actor.
enum UserIdleService {
    /// Seconds since the last user input event (keyboard, mouse move, or left
    /// click), per `CGEventSource.combinedSessionState`. Returns 0 when no
    /// finite signal is available (fail-active: callers treating idleness as a
    /// precondition for background work see "not idle" and stand down).
    static func idleSeconds() -> TimeInterval {
        let state = CGEventSourceStateID.combinedSessionState
        let key = CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown)
        let move = CGEventSource.secondsSinceLastEventType(state, eventType: .mouseMoved)
        let click = CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseDown)
        let values = [key, move, click].filter { $0.isFinite && $0 >= 0 }
        return values.min() ?? 0
    }
}
