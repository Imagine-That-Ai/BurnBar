import Foundation

// MARK: - Cast Reconnect Strategy
//
// Wraps `CastChannelClient` with auto-recovery logic so a single
// "Cast Now" tap survives transient zombie sessions on the device side.
//
// Strategy:
//   1. Try direct cast. If success, done.
//   2. On failure/timeout, send STOP to the receiver, wait 2s, retry.
//   3. Exponential backoff between retries: 1s, 2s, 4s, 8s.
//   4. Give up after 4 attempts. Caller surfaces a "Wake your Hub"
//      diagnostic with a deep link to the Google Home app.
//
// All retries use the **same** TLS connection where possible to avoid
// the device throttling rapid reconnects. We rebuild the connection
// only when state went `.failed` / `.cancelled`.

@MainActor
final class CastReconnectStrategy {

    enum Result: Equatable {
        case success(sessionId: String)
        case recoveredViaHomeAssistant(String)
        case failure(String, attemptsMade: Int)
    }

    let device: CastDevice
    private let backoff: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000]
    private let homeAssistantWebhookURL: URL?
    private let recoveryClient: HomeAssistantCastRecoveryClient

    init(
        device: CastDevice,
        homeAssistantWebhookURL: URL? = nil,
        recoveryClient: HomeAssistantCastRecoveryClient = HomeAssistantCastRecoveryClient()
    ) {
        self.device = device
        self.homeAssistantWebhookURL = homeAssistantWebhookURL
        self.recoveryClient = recoveryClient
    }

    /// Top-level entry. Sends to the device with full recovery semantics.
    func castWithRecovery(url: URL) async -> Result {
        var lastError = "Unknown"
        for attempt in 0..<backoff.count {
            let client = CastChannelClient(device: device)
            switch await client.cast(url: url) {
            case .success(let sessionId):
                return .success(sessionId: sessionId)
            case .failure(let reason):
                lastError = reason
                // Force-stop any zombie session before next attempt.
                await client.stop()
            case .timeout:
                lastError = "Hub didn't respond in time"
                await client.stop()
            }
            try? await Task.sleep(nanoseconds: backoff[attempt])
        }

        switch await recoveryClient.trigger(
            webhookURL: homeAssistantWebhookURL,
            device: device,
            dashboardURL: url,
            reason: lastError
        ) {
        case .triggered:
            return .recoveredViaHomeAssistant("Native Cast could not reach \(device.friendlyName), so Home Assistant was asked to recover and cast the dashboard.")
        case .failed(let reason):
            return .failure("\(lastError) Home Assistant recovery also failed: \(reason)", attemptsMade: backoff.count)
        case .skipped:
            break
        }
        return .failure(lastError, attemptsMade: backoff.count)
    }

    /// Lightweight liveness check — opens the channel, sends one PING,
    /// returns whether we got a roundtrip back. Used by the wizard's
    /// "Diagnose" view.
    func probe() async -> Bool {
        let client = CastChannelClient(device: device)
        let result = await client.ping()
        client.disconnect()
        return result
    }
}
