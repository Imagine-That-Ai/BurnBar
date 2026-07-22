import DeviceCheck
import FirebaseAppCheck
import FirebaseCore
import Foundation
import OpenBurnBarCore

/// App Check provider factory that selects the appropriate attestation provider:
/// - **Debug/internal builds**: Uses `AppCheckDebugProvider` only when the shared
///   debug App Check policy allows it and a token is present.
/// - **Release builds**: Uses DeviceCheck on macOS and prefers App Attest with a
///   DeviceCheck fallback on supported non-Mac Apple platforms. Returns no provider
///   when the platform provider is unavailable so Firebase fails closed instead of
///   silently using a debug provider.
final class OpenBurnBarAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    enum ProviderSelection: String {
        case debug
        case appAttest
        case deviceCheck
        case unsupported
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
        case .unsupported:
            return nil
        }
    }

    static func providerSelection(
        firebasePlistPath: String?,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = AppCheckDebugTokenEnvironment.isDebugBuild,
        appAttestIsSupported: Bool? = nil,
        deviceCheckIsSupported: Bool? = nil
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
        return productionProviderSelection(
            appAttestIsSupported: appAttestIsSupported ?? runtimeAppAttestIsSupported,
            deviceCheckIsSupported: deviceCheckIsSupported ?? DCDevice.current.isSupported
        )
    }

    static func productionProviderSelection(
        appAttestIsSupported: Bool,
        deviceCheckIsSupported: Bool
    ) -> ProviderSelection {
        #if os(macOS)
        // Apple documents App Attest as unsupported on Mac. A provisioning
        // profile can still make the support probe return true, but assertions
        // then fail at runtime. DeviceCheck is the production Mac provider.
        if deviceCheckIsSupported {
            return .deviceCheck
        }
        return .unsupported
        #else
        if appAttestIsSupported {
            return .appAttest
        }
        if deviceCheckIsSupported {
            return .deviceCheck
        }
        return .unsupported
        #endif
    }

    private static var runtimeAppAttestIsSupported: Bool {
        if #available(macOS 11.0, *) {
            return DCAppAttestService.shared.isSupported
        }
        return false
    }
}
