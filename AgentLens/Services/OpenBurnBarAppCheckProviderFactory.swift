import FirebaseAppCheck
import FirebaseCore
import Foundation

/// App Check provider factory that selects the appropriate attestation provider:
/// - **Debug builds**: Uses `AppCheckDebugProvider` when a debug token is present in Info.plist.
/// - **macOS 11+ (Release)**: Uses `AppAttestProvider` for strong device attestation.
/// - **Older macOS (Release fallback)**: Uses `DeviceCheckProvider`.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG
        if let debugSecret = Bundle.main.object(forInfoDictionaryKey: "FirebaseAppCheckDebugToken") as? String,
           !debugSecret.isEmpty {
            // The Firebase SDK picks up the debug token from the
            // `FIRAAppCheckDebugToken` Info.plist key or the same-named env
            // variable; `AppCheckDebugProvider(app:)` has no secret argument
            // in the current SDK. We simply hand the app reference through.
            _ = debugSecret
            return AppCheckDebugProvider(app: app)
        }
        // Debug without token: fall through to DeviceCheck as best-effort
        return DeviceCheckProvider(app: app)
        #else
        if #available(macOS 11.0, *) {
            return AppAttestProvider(app: app)
        } else {
            return DeviceCheckProvider(app: app)
        }
        #endif
    }
}
