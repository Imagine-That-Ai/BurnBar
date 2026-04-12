import Foundation
#if os(macOS)
import Security
#endif

#if os(macOS)

/// Direct linkage for `SecKeychain{Get,Set}UserInteractionAllowed` so we do not import the
/// deprecated Swift declarations. Apple still documents these for suppressing prompts during
/// non-UI keychain access; there is no drop-in replacement with the same semantics.
@inline(__always)
@_silgen_name("SecKeychainGetUserInteractionAllowed")
private func obbSecKeychainGetUserInteractionAllowed(_ allowed: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus

@inline(__always)
@_silgen_name("SecKeychainSetUserInteractionAllowed")
private func obbSecKeychainSetUserInteractionAllowed(_ allowed: Bool) -> OSStatus

/// Disables keychain UI for the enclosed operation (legacy items can still prompt without this).
func withKeychainUserInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
    var previousAllowed = DarwinBoolean(true)
    let readStatus = obbSecKeychainGetUserInteractionAllowed(&previousAllowed)
    let disableStatus = obbSecKeychainSetUserInteractionAllowed(false)
    defer {
        if disableStatus == errSecSuccess {
            if readStatus == errSecSuccess {
                _ = obbSecKeychainSetUserInteractionAllowed(previousAllowed.boolValue)
            } else {
                _ = obbSecKeychainSetUserInteractionAllowed(true)
            }
        }
    }
    return try operation()
}

#else

func withKeychainUserInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
    try operation()
}

#endif
