import Foundation

struct HomeAssistantCastRecoveryClient: Sendable {
    enum Outcome: Equatable {
        case skipped
        case triggered
        case failed(String)
    }

    var session: URLSession = .shared

    func trigger(
        webhookURL: URL?,
        device: CastDevice,
        dashboardURL: URL,
        reason: String
    ) async -> Outcome {
        guard let webhookURL else { return .skipped }

        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.payload(
            device: device,
            dashboardURL: dashboardURL,
            reason: reason
        )

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Home Assistant webhook returned a non-HTTP response.")
            }
            return (200..<300).contains(http.statusCode)
                ? .triggered
                : .failed("Home Assistant webhook returned HTTP \(http.statusCode).")
        } catch {
            return .failed("Home Assistant webhook failed: \(error.localizedDescription)")
        }
    }

    static func payload(device: CastDevice, dashboardURL: URL, reason: String) -> Data? {
        let body: [String: Any] = [
            "source": "openburnbar",
            "action": "cast_recovery",
            "device": [
                "serviceName": device.serviceName,
                "friendlyName": device.friendlyName,
                "host": device.host,
                "port": device.port,
                "model": device.model
            ],
            "dashboardURL": dashboardURL.absoluteString,
            "reason": reason,
            "requestedAt": ISO8601DateFormatter().string(from: Date())
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [])
    }
}
