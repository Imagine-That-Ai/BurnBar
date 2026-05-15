import Foundation
@preconcurrency import FirebaseAuth
import FirebaseAppCheck
import FirebaseCore

/// macOS equivalent of `MobileFirebaseTokenProvider`. Exposes Firebase
/// Auth + App Check token retrieval to the `BurnBarHostedInsightAdapter`
/// without dragging Firebase imports into `OpenBurnBarCore`.
///
/// Hosted-fallback callable expects an App Check header; the user
/// auth token is optional (anonymous callable allowed when the user
/// hasn't signed into iCloud / Sign-in-with-Apple yet).
final class MacFirebaseTokenProvider: @unchecked Sendable {
    static let shared: MacFirebaseTokenProvider? = {
        guard FirebaseApp.app() != nil else { return nil }
        return MacFirebaseTokenProvider()
    }()

    private init() {}

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
