import Foundation
import Observation
import OpenBurnBarKernel

/// Startup health for the loopback services BurnBar talks to.
///
/// `OpenBurnBarRuntimeContext` evaluates `LocalServiceInvariants` at
/// bootstrap via `evaluate(resolved:)` and the Help & Support hub
/// re-evaluates every time it appears, so fixing a setting clears its warning
/// without a relaunch. `.programmerError` violations never reach this store —
/// they trip `assertionFailure` in DEBUG and are logged in release.
@Observable
@MainActor
final class LocalServiceHealth {
    static let shared = LocalServiceHealth()

    /// Configuration violations for the currently configured endpoints.
    /// Empty means every registered local service resolves cleanly.
    private(set) var violations: [LocalServiceInvariantViolation] = []

    private(set) var lastEvaluatedAt: Date?

    /// Re-evaluate the registered services against the endpoints resolved from
    /// live settings (`SettingsManager.resolvedLocalServiceEndpoints`) and
    /// publish the result.
    @discardableResult
    func evaluate(resolved: [LocalService: String]) -> [LocalServiceInvariantViolation] {
        let violations = LocalServiceInvariants.configurationViolations(resolved: resolved)
        self.violations = violations
        lastEvaluatedAt = Date()
        return violations
    }

    /// Copy a user can act on: what is wrong and where to change it. Never
    /// names internals — keyed off the violation kind and services so message
    /// text stays a logging detail, not a contract.
    static func userFacingCopy(for violation: LocalServiceInvariantViolation) -> String {
        let endpoint = violation.endpoint.map { "\"\($0)\"" } ?? "the configured value"
        switch violation.kind {
        case .unparseableEndpoint:
            let service = violation.services.first
            let name = service?.descriptor.displayName ?? "Local service"
            return "The \(name) URL \(endpoint) isn't a valid URL. \(fixHint(for: service))"
        case .endpointCollision:
            let names = violation.services.map(\.descriptor.displayName).joined(separator: " and ")
            let locations = violation.services.map { "\($0.descriptor.displayName) is set \(locationPhrase(for: $0))" }
            return "\(names) are both set to \(endpoint). Change one of them: \(locations.joined(separator: "; "))."
        case .gatewayNotLoopback:
            let service = violation.services.first
            return "The OpenBurnBar gateway is set to \(endpoint), a non-local address — it must stay on this Mac (127.0.0.1 or localhost). \(fixHint(for: service))"
        case .portOutOfRange:
            let service = violation.services.first
            let name = service?.descriptor.displayName ?? "Local service"
            return "The \(name) port \(endpoint) is outside the valid range 1–65535. \(fixHint(for: service))"
        case .registryPortCollision, .registryNonLoopbackDefault:
            // Programmer errors — asserted/logged at bootstrap, not surfaced
            // here. If one ever reaches the store, show the raw message.
            return violation.message
        }
    }

    /// "Fix it in …" for services with an editable field; a plain-language
    /// description of where the value comes from for the ones without one
    /// (Ollama/MLX summary URLs are stored settings with no editing surface
    /// today, so the copy says what consumes them instead of inventing a
    /// navigation path).
    private static func fixHint(for service: LocalService?) -> String {
        switch service {
        case .openBurnBarGateway:
            return "Fix it in Settings → Engine Room → HTTP Gateway."
        case .hermesGateway:
            return "Fix it in Settings → Agents → Runtimes → Hermes Gateway."
        case .piAgentGateway:
            return "Fix it in Settings → Agents → Runtimes → Pi Agent Instances."
        case .openClawGateway:
            return "Fix it in Settings → Agents → Runtimes → OpenClaw Gateway."
        case .smartHubDashboard:
            return "Fix it in Settings → Devices & Sync → Smart Displays."
        case .ollama, .mlxServer:
            return "It is the stored endpoint used for on-device summaries (Settings → General → Session Summaries)."
        case nil:
            return "Fix it in Settings."
        }
    }

    /// Where the service's endpoint is changed, phrased for the collision
    /// sentence ("…is set in Settings → …" / "…is set as a stored override…").
    private static func locationPhrase(for service: LocalService) -> String {
        switch service {
        case .openBurnBarGateway:
            return "in Settings → Engine Room → HTTP Gateway"
        case .hermesGateway:
            return "in Settings → Agents → Runtimes → Hermes Gateway"
        case .piAgentGateway:
            return "in Settings → Agents → Runtimes → Pi Agent Instances"
        case .openClawGateway:
            return "in Settings → Agents → Runtimes → OpenClaw Gateway"
        case .smartHubDashboard:
            return "in Settings → Devices & Sync → Smart Displays"
        case .ollama, .mlxServer:
            return "as the stored endpoint for on-device summaries"
        }
    }
}
