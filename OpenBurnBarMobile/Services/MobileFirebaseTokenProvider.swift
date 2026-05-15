import Foundation
import FirebaseAuth
import FirebaseAppCheck
import FirebaseCore

/// Bridge that exposes Firebase Auth + App Check token retrieval to
/// Sendable closures without dragging Firebase imports into types that
/// can't depend on them (notably the `OpenBurnBarCore` insight
/// adapters, which run in pure Swift packages).
///
/// The `BurnBarHostedInsightAdapter` calls `idToken()` and
/// `appCheckToken()` per request. Auth is optional (anonymous
/// callable allowed); App Check is enforced by the Cloud Function
/// guard so the hosted OpenRouter quota can't be burned without
/// proof the request came from a real BurnBar build.
final class MobileFirebaseTokenProvider: @unchecked Sendable {
    /// Returns the singleton when Firebase Core has been configured;
    /// `nil` on clean checkouts where `FirebaseApp.configure()` was
    /// skipped (e.g. unit tests without `GoogleService-Info.plist`).
    static let shared: MobileFirebaseTokenProvider? = {
        guard FirebaseApp.app() != nil else { return nil }
        return MobileFirebaseTokenProvider()
    }()

    private init() {}

    /// Fetch a fresh Firebase Auth ID token if a user is signed in.
    /// Returns `nil` for anonymous callers; the hosted callable
    /// tolerates anonymous requests as long as App Check passes.
    func idToken() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            guard let user = Auth.auth().currentUser else {
                continuation.resume(returning: nil)
                return
            }
            user.getIDTokenResult(forcingRefresh: false) { result, error in
                if let token = result?.token, error == nil {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Fetch an App Check attestation token. The Cloud Function
    /// rejects requests missing this header in production builds.
    func appCheckToken() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            AppCheck.appCheck().token(forcingRefresh: false) { token, error in
                if let token, error == nil, !token.token.isEmpty {
                    continuation.resume(returning: token.token)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
