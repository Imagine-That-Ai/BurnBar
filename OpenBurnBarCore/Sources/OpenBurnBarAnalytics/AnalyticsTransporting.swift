import Foundation

/// The SDK seam. Production is backed by the Amplitude SDK (initialized only
/// after consent, autocapture disabled); tests use a capturing fake. The
/// `Analytics` recorder is the only thing that talks to it, so the consent gate
/// cannot be bypassed. Ported from
/// `AgentLens/Services/Analytics/AnalyticsTransporting.swift`.
///
/// The real `AmplitudeSwift`-backed implementation lives in the iOS **app
/// target** (`OpenBurnBarMobile/Services/Analytics/AmplitudeTransport.swift`),
/// not in this package — exactly as macOS keeps `AmplitudeTransport.swift` in the
/// app and out of the SDK-free core. That keeps this package free of the
/// Amplitude dependency and buildable with `swift build` on any toolchain.
@MainActor
public protocol AnalyticsTransporting: AnyObject {
    /// Whether a real client is currently initialized.
    var isStarted: Bool { get }
    /// Construct + start the underlying SDK. Called only once consent is granted.
    func start()
    /// Tear down the client (on revoke). Flushes nothing.
    func stop()
    /// Send one taxonomy event. Never called while consent is not granted.
    func send(name: String, category: String, properties: [String: AnalyticsValue])
    /// Set the authenticated user id (nil to clear). Never before verified login.
    func setUserId(_ id: String?)
}
