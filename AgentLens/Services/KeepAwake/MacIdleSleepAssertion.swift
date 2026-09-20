import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// Test seam for `IOPMAssertionTypePreventUserIdleSystemSleep`.
/// Display may still sleep. Never wraps `pmset disablesleep`.
protocol IdleSleepAsserting: AnyObject, Sendable {
    func acquire(reason: String) -> UInt32?
    func release(_ assertionID: UInt32)
}

/// Production IOPM assertion. Pattern matches
/// `OpenBurnBarRemoteAccessAgentMain` (`IOPMAssertionCreateWithName` /
/// `IOPMAssertionRelease`) but uses PreventUserIdleSystemSleep so the
/// lid/display can dim while the host stays a remote endpoint.
final class IOPMIdleSleepAssertion: IdleSleepAsserting, @unchecked Sendable {
    func acquire(reason: String) -> UInt32? {
        #if os(macOS)
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess, assertionID != 0 else { return nil }
        return assertionID
        #else
        return nil
        #endif
    }

    func release(_ assertionID: UInt32) {
        #if os(macOS)
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(IOPMAssertionID(assertionID))
        #endif
    }
}
