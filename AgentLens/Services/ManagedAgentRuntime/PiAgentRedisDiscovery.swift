import Foundation

// MARK: - Pi Agent Redis Snapshot

/// Result of polling the Pi agent's Redis-backed registry. When Redis is not
/// configured or unreachable, the adapter falls back to a synthetic
/// "default" instance derived from the gateway probe.
struct PiAgentRedisSnapshot: Equatable, Sendable {
    var available: Bool
    var statusMessage: String
    var instances: [ManagedAgentInstance]

    static let unavailable = PiAgentRedisSnapshot(
        available: false,
        statusMessage: "Redis not configured.",
        instances: []
    )
}

// MARK: - Pi Agent Redis Discovery

/// Pi instance discovery adapter. Production builds talk to the Pi gateway's
/// `/admin/instances` endpoint, which proxies the Redis-backed registry of
/// active Pi agent instances (online state, active session, attached
/// gateway base URL). Tests and lightweight environments inject a stub.
protocol PiAgentRedisDiscovery: Sendable {
    func snapshot(redisURL: URL?, gatewayBaseURL: URL, bearerToken: String?) async -> PiAgentRedisSnapshot
}

// MARK: - Live Implementation

struct PiAgentRedisHTTPDiscovery: PiAgentRedisDiscovery {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func snapshot(redisURL: URL?, gatewayBaseURL: URL, bearerToken: String?) async -> PiAgentRedisSnapshot {
        guard let endpoint = URL(string: "admin/instances", relativeTo: gatewayBaseURL)?.absoluteURL else {
            return PiAgentRedisSnapshot(
                available: false,
                statusMessage: "Pi gateway base URL is invalid.",
                instances: []
            )
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let redisURL {
            request.setValue(redisURL.absoluteString, forHTTPHeaderField: "X-Pi-Redis-URL")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return PiAgentRedisSnapshot(
                    available: false,
                    statusMessage: redisURL == nil
                        ? "Pi gateway has no Redis-backed instance registry."
                        : "Pi Redis registry not reachable at the configured URL.",
                    instances: []
                )
            }
            let decoded = decodeInstances(from: data)
            if decoded.isEmpty {
                return PiAgentRedisSnapshot(
                    available: true,
                    statusMessage: "Pi Redis registry is online but empty.",
                    instances: []
                )
            }
            return PiAgentRedisSnapshot(
                available: true,
                statusMessage: "Pi Redis registry online — \(decoded.count) instance\(decoded.count == 1 ? "" : "s").",
                instances: decoded
            )
        } catch {
            return PiAgentRedisSnapshot(
                available: false,
                statusMessage: redisURL == nil
                    ? "Pi gateway not reachable for instance discovery."
                    : "Pi Redis registry not reachable: \(error.localizedDescription)",
                instances: []
            )
        }
    }

    private func decodeInstances(from data: Data) -> [ManagedAgentInstance] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }

        // Support both `[{...}]` and `{ "instances": [...] }` shapes.
        let raw: [[String: Any]]
        if let arr = object as? [[String: Any]] {
            raw = arr
        } else if let dict = object as? [String: Any], let arr = dict["instances"] as? [[String: Any]] {
            raw = arr
        } else {
            return []
        }

        return raw.compactMap { entry -> ManagedAgentInstance? in
            let id = (entry["id"] as? String)
                ?? (entry["instance_id"] as? String)
                ?? (entry["instanceId"] as? String)
                ?? (entry["name"] as? String)
            guard let id, !id.isEmpty else { return nil }

            let displayName = (entry["display_name"] as? String)
                ?? (entry["displayName"] as? String)
                ?? (entry["name"] as? String)
                ?? id
            let isOnline = (entry["online"] as? Bool)
                ?? (entry["is_online"] as? Bool)
                ?? (entry["status"] as? String).map { $0.lowercased() == "online" || $0.lowercased() == "running" }
                ?? true
            let activeSessionID = (entry["active_session_id"] as? String)
                ?? (entry["activeSessionId"] as? String)
                ?? (entry["session_id"] as? String)
            let gatewayBaseURL: URL? = {
                if let raw = entry["gateway_base_url"] as? String {
                    return URL(string: raw)
                }
                if let raw = entry["gatewayBaseURL"] as? String {
                    return URL(string: raw)
                }
                if let raw = entry["base_url"] as? String {
                    return URL(string: raw)
                }
                return nil
            }()

            return ManagedAgentInstance(
                id: id,
                displayName: displayName,
                isOnline: isOnline,
                activeSessionID: activeSessionID,
                gatewayBaseURL: gatewayBaseURL
            )
        }
    }
}
