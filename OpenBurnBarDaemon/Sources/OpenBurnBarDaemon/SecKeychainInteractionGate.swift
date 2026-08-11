import Foundation
#if os(macOS)
import LocalAuthentication
import Security
#endif

#if os(macOS)

/// One process-wide context for noninteractive background keychain reads.
///
/// The context is configured once and is never used for policy evaluation; it
/// only carries `interactionNotAllowed = true`. Reusing it avoids repeating
/// `LAContext` allocation and the associated securityd setup across provider,
/// connector, switcher, and database-key lookups. The global interaction gate
/// below remains the belt-and-suspenders protection for legacy ACL items.
private enum NonInteractiveKeychainAuthenticationContext {
    // AUDIT(nonisolated(unsafe)): set once before publication, then read-only.
    // sendable-allowlist: foundation-sdk-shim
    nonisolated(unsafe) static let shared: LAContext = {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }()
}

@inline(__always)
func nonInteractiveKeychainAuthenticationContext() -> LAContext {
    NonInteractiveKeychainAuthenticationContext.shared
}

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
