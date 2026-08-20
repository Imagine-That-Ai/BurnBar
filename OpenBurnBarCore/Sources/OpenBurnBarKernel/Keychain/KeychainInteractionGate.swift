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
/// ACL no longer matches this binary's code signature fails closed with
/// `errSecInteractionNotAllowed` instead of throwing a password dialog at the user.
///
/// Why this exists at all: items written without `kSecUseDataProtectionKeychain` land in
/// the file-based login keychain, whose per-item ACL is bound to the requesting binary's
/// signature. Any signature drift -- a Sparkle update, a re-sign, a second binary such as
/// the daemon reading an item the app created -- makes macOS ask for the login password.
/// A user cannot distinguish that dialog from a request for their computer password.
///
/// The daemon has always wrapped its reads in this. The app did not, which is why the app
/// was the one raising password dialogs at launch. Prefer fixing the storage
/// (data-protection keychain + access group) and keep this as the belt-and-braces guard for
/// any read that happens before there is a window to explain itself in.
///
/// Pair it with `kSecUseAuthenticationUI: kSecUseAuthenticationUIFail` in the query: this
/// suppresses the legacy keychain's own UI, that one covers the modern path.
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
