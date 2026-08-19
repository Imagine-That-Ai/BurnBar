import Foundation

/// Mac-only Local D box client. Talks to `127.0.0.1:1337` JSON.
/// Send is allowed only when health is `.ok`. Never writes `store.db`.
struct GrokDHostClient: Sendable {
    let config: GrokDHostConfig
    let session: URLSession
    let portProbe: any GrokDPortProbing

    init(
        config: GrokDHostConfig,
        session: URLSession = GrokDHostClient.makeLoopbackSession(),
        portProbe: any GrokDPortProbing = GrokDTCPPortProbe()
    ) {
        self.config = config
        self.session = session
        self.portProbe = portProbe
    }

    static func makeLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    static func isAgentUUID(_ raw: String) -> Bool {
        raw.count == 36 && UUID(uuidString: raw) != nil
    }

    func health() async -> GrokDBoxHealth {
        let shimUp = portProbe.isListening(host: config.loopbackHost, port: config.shimPort)
        let hostUp = portProbe.isListening(host: config.loopbackHost, port: config.hostPort)
        let inferenceUp = portProbe.isListening(host: config.loopbackHost, port: config.inferencePort)

        if shimUp && !hostUp {
            return .canListHostDown
        }
        if shimUp && hostUp && !inferenceUp {
            return .canListCannotComplete
        }
        if shimUp && hostUp && inferenceUp {
            do {
                _ = try await listAgents()
                return .ok
            } catch {
                return .cannotList
            }
        }
        return .cannotList
    }

    func listAgents() async throws -> [GrokDAgentRecord] {
        let data = try await post(method: "listAgents", body: [:])
        return try decodeAgentList(data)
    }

    /// Sends one UUID a prompt. Refuses unless health is `.ok`. Does not wait for an assistant line.
    func sendPrompt(agentID: String, prompt: String) async throws -> GrokDTurnHandle {
        guard Self.isAgentUUID(agentID) else { throw GrokDHostError.invalidAgentID }
        let status = await health()
        guard status.allowsSend else { throw GrokDHostError.sendRefused(status) }

        let agents = try await listAgents()
        if let agent = agents.first(where: { $0.id == agentID }), agent.isBusy {
            throw GrokDHostError.agentBusy(id: agentID)
        }

        let body: [String: Any] = [
            "agentId": agentID,
            "prompt": prompt,
            "awaitTurn": false,
        ]
        _ = try await post(method: "sendPrompt", body: body)
        return GrokDTurnHandle(agentID: agentID, prompt: prompt, acceptedAt: Date())
    }

    private func post(method: String, body: [String: Any]) async throws -> Data {
        if config.loopbackHost != GrokDHostConfig.loopbackHost {
            throw GrokDHostError.notLoopback
        }
        var request = URLRequest(url: config.apiURL(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GrokDHostError.transport("non-http")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw GrokDHostError.httpStatus(http.statusCode)
        }
        return data
    }

    private func decodeAgentList(_ data: Data) throws -> [GrokDAgentRecord] {
        if let list = try? JSONDecoder().decode([GrokDAgentRecord].self, from: data) {
            return list
        }
        struct Envelope: Decodable { let agents: [GrokDAgentRecord] }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.agents
        }
        throw GrokDHostError.decoding
    }
}
