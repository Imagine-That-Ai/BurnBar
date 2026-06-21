import FirebaseAppCheck
import FirebaseCore
import Foundation
import OpenBurnBarCore

/// App Check provider factory that selects the appropriate attestation provider:
/// - **Debug/internal builds**: Uses `AppCheckDebugProvider` only when the shared
///   debug App Check policy allows it and a token is present.
/// - **macOS 11+ (Release)**: Uses `AppAttestProvider` for strong device attestation.
/// - **Older macOS (Release fallback)**: Uses `DeviceCheckProvider`.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    enum ProviderSelection: String {
        case debug
        case appAttest
        case deviceCheck
    }

    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        let firebasePlistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")
        switch Self.providerSelection(firebasePlistPath: firebasePlistPath) {
        case .debug:
            _ = AppCheckDebugTokenEnvironment.configureIfAvailable(
                firebasePlistPath: firebasePlistPath,
                debugAppCheckAllowed: true
            )
            // The Firebase SDK picks up the debug token from the
            // Firebase plist or the same-named env
            // variable; `AppCheckDebugProvider(app:)` has no secret argument
            // in the current SDK. We simply hand the app reference through.
            return AppCheckDebugProvider(app: app)
        case .appAttest:
            return AppAttestProvider(app: app)
        case .deviceCheck:
            return DeviceCheckProvider(app: app)
        }
    }

    static func providerSelection(
        firebasePlistPath: String?,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = AppCheckDebugTokenEnvironment.isDebugBuild
    ) -> ProviderSelection {
        let debugAllowed = AppCheckDebugTokenEnvironment.debugAppCheckAllowed(
            infoDictionary: infoDictionary,
            isDebugBuild: isDebugBuild
        )
        let hasDebugToken = AppCheckDebugTokenEnvironment.availableToken(
            firebasePlistPath: firebasePlistPath,
            infoDictionary: infoDictionary,
            environment: environment
        ) != nil
        if debugAllowed && (isDebugBuild || hasDebugToken) {
            return .debug
        }
        return productionProviderSelection()
    }

    private static func productionProviderSelection() -> ProviderSelection {
        if #available(macOS 11.0, *) {
            return .appAttest
        } else {
            return .deviceCheck
        }
    }
}
