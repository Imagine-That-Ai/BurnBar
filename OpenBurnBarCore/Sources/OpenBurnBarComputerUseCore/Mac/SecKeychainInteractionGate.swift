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

/// Runs `operation` with macOS keychain UI suppressed, so a legacy-keychain item whose
/// ACL no longer matches this binary fails closed with `errSecInteractionNotAllowed`
/// instead of throwing a password dialog at the user.
///
/// Public because the app needs it too: `DatabaseEncryptionService` reads the SQLCipher
/// key inside `OpenBurnBarApp.init`, before any window exists, and a prompt there is
/// indistinguishable from an app demanding the user's computer password. The daemon has
/// always wrapped its reads in this; the app had no way to.
///
/// Pair it with `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` in the query --
/// this suppresses the legacy keychain's own UI, that one covers the modern path.
public func withKeychainUserInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
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

public func withKeychainUserInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
    try operation()
}

#endif
