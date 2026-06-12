import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

@MainActor
final class HermesCompositeRelayTransport: HermesRelayTransporting {
    /// `UserDefaults` key the iOS feature toggle writes. The OpenBurnBar Mac
    /// app sets the same key via `SettingsManager.hermesIrohTransportEnabled`.
    /// When false, the cascade skips iroh and uses Firestore directly.
    nonisolated static let irohEnabledDefaultsKey = "hermes_iroh_transport_enabled"

    static let shared = HermesCompositeRelayTransport(
        primary: HermesIrohRelayTransport.shared,
        secondary: FirestoreHermesRelayTransport.shared,
        fallback: FirestoreHermesRelayTransport.shared
    )

    private let primary: HermesRelayTransporting
    private let secondary: HermesRelayTransporting
    private let fallback: HermesRelayTransporting
    private let irohEnabled: @Sendable () -> Bool

    /// Fallback chain. The primary is the iroh peer-to-peer transport;
    /// failures now cascade directly to the Firestore long-poll transport
    /// because the Cloud Run WSS relay and Redis backend were retired.
    init(
        primary: HermesRelayTransporting,
        secondary: HermesRelayTransporting,
        fallback: HermesRelayTransporting,
        irohEnabled: @escaping @Sendable () -> Bool = {
            #if DEBUG
            if ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_IROH_TRANSPORT"] == "1" {
                return true
            }
            #endif
            return UserDefaults.standard.bool(forKey: HermesCompositeRelayTransport.irohEnabledDefaultsKey)
        }
    ) {
        self.primary = primary
        self.secondary = secondary
        self.fallback = fallback
        self.irohEnabled = irohEnabled
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        if irohEnabled() {
            do {
                return try await primary.sendUnary(payload, timeout: timeout)
            } catch {
                if HermesServiceError.shouldStopRelayFallback(error) {
                    throw error
                }
                guard allowsFirestoreFallback(for: payload) else {
                    throw selectedModelNoFallbackError(error)
                }
                await Self.recordFallback(payload: payload, error: error, hop: "iroh-to-firestore")
            }
        }
        do {
            return try await secondary.sendUnary(payload, timeout: timeout)
        } catch {
            if HermesServiceError.shouldStopRelayFallback(error) {
                throw error
            }
            if secondary === fallback {
                throw error
            }
            await Self.recordFallback(payload: payload, error: error, hop: "secondary-to-firestore")
        }
        return try await fallback.sendUnary(payload, timeout: timeout)
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        if irohEnabled() {
            do {
                try await primary.sendStreaming(payload, timeout: timeout, onSSEEvent: onSSEEvent)
                return
            } catch {
                if HermesServiceError.shouldStopRelayFallback(error) {
                    throw error
                }
                guard allowsFirestoreFallback(for: payload) else {
                    throw selectedModelNoFallbackError(error)
                }
                await Self.recordFallback(payload: payload, error: error, hop: "iroh-to-firestore")
            }
        }
        do {
            try await secondary.sendStreaming(payload, timeout: timeout, onSSEEvent: onSSEEvent)
            return
        } catch {
            if HermesServiceError.shouldStopRelayFallback(error) {
                throw error
            }
            if secondary === fallback {
                throw error
            }
            await Self.recordFallback(payload: payload, error: error, hop: "secondary-to-firestore")
        }
        try await fallback.sendStreaming(payload, timeout: timeout, onSSEEvent: onSSEEvent)
    }

    /// Mirrors Android `HermesCompositeRelayTransport`: a generic iroh dial or
    /// stream failure on the user's **selected model** (`/v1/chat/completions`)
    /// must not silently reroute over Firestore. iOS previously fell back for
    /// *all* streaming ops unless `stopsRelayFallback` (which only covers
    /// model-binding errors + relayTimeout), so an iroh NAT failure mid-chat
    /// silently swapped the selected model's transport while Android hard-failed.
    /// Control-plane unary calls and the CLI-agent stream still fall back: they
    /// target the same selected Mac executor regardless of transport.
    private func allowsFirestoreFallback(for payload: HermesRelayPayload) -> Bool {
        payload.operation != .chatCompletions
    }

    /// Error surfaced when an iroh failure on the selected model is deliberately
    /// not followed by a Firestore fallback. Message mirrors the Kotlin transport
    /// so logs read identically across platforms.
    private func selectedModelNoFallbackError(_ error: Error) -> HermesServiceError {
        .relayUnavailable(
            "Iroh direct Hermes relay failed before the selected Mac harness completed: "
                + "\(error.localizedDescription). No Firestore fallback was attempted, "
                + "so the selected model is not silently rerouted."
        )
    }

    private static func recordFallback(payload: HermesRelayPayload, error: Error, hop: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        await FirestoreIrohAuditLogger.shared.record(
            event: .fallbackToFirestore,
            uid: uid,
            connectionId: payload.connectionID,
            transport: .firestore,
            rttMillis: nil,
            detail: [
                "hop": hop,
                "target": "firestore",
                "error": String(error.localizedDescription.prefix(256))
            ]
        )
    }
}
