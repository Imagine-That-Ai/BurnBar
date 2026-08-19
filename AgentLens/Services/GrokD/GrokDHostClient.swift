import Foundation

/// Mac-only Local D box client. Talks to `127.0.0.1:1337` JSON.
/// Send is allowed only when health is `.ok`. Never writes `store.db`.
struct GrokDHostClient: Sendable {
    let config: GrokDHostConfig
    let session: URLSession
    let portProbe: any GrokDPortProbing
    let transcriptReader: any GrokDTranscriptReading

    init(
        config: GrokDHostConfig,
        session: URLSession = GrokDHostClient.makeLoopbackSession(),
        portProbe: any GrokDPortProbing = GrokDTCPPortProbe(),
        transcriptReader: any GrokDTranscriptReading = GrokDReadonlyTranscriptReader()
    ) {
        self.config = config
        self.session = session
        self.portProbe = portProbe
        self.transcriptReader = transcriptReader
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
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GrokDHostError.emptyPrompt }
        let status = await health()
        guard status.allowsSend else { throw GrokDHostError.sendRefused(status) }

        let agents = try await listAgents()
        guard let agent = agents.first(where: { $0.id == agentID }) else {
            throw GrokDHostError.unknownAgent(id: agentID)
        }
        if agent.isBusy {
            throw GrokDHostError.agentBusy(id: agentID)
        }

        let body: [String: Any] = [
            "agentId": agentID,
            "prompt": trimmed,
            "awaitTurn": false
        ]
        _ = try await post(method: "sendPrompt", body: body)
        return GrokDTurnHandle(agentID: agentID, prompt: trimmed, acceptedAt: Date())
    }

    /// Polls `listAgents` and, when `path` is present, a **read-only** sqlite
    /// window. Preview follow stays the fallback if the db is missing or busy.
    /// Never writes SQLite. `sendPrompt` stays `awaitTurn: false`.
    func followTurn(
        agentID: String,
        prompt: String,
        baselinePreview: String?,
        maxPolls: Int = 30,
        pollNanoseconds: UInt64 = 1_000_000_000
    ) async -> GrokDTurnFollowResult {
        let needle = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var sawPrompt = false
        var userPreview: String?
        var lastPreview: String?
        let polls = max(1, maxPolls)
        for poll in 0..<polls {
            if Task.isCancelled {
                return GrokDTurnFollowResult(outcome: .cancelled, lastPreview: lastPreview)
            }
            if poll > 0 && pollNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                } catch {
                    return GrokDTurnFollowResult(outcome: .cancelled, lastPreview: lastPreview)
                }
            }
            let agents: [GrokDAgentRecord]
            do {
                agents = try await listAgents()
            } catch {
                continue
            }
            guard let agent = agents.first(where: { $0.id == agentID }) else {
                return GrokDTurnFollowResult(outcome: .agentMissing, lastPreview: lastPreview)
            }
            let preview = agent.lastMessagePreview
            lastPreview = preview
            if let path = agent.path {
                switch await transcriptReader.read(path: path, token: needle) {
                case .completed:
                    return GrokDTurnFollowResult(outcome: .completed, lastPreview: preview)
                case .promptLanded:
                    sawPrompt = true
                case .skippedBusy, .unavailable, .noEvidence:
                    break
                }
            }
            if !sawPrompt {
                if Self.previewLooksLikePrompt(preview, needle: needle, baseline: baselinePreview) {
                    sawPrompt = true
                    userPreview = preview
                } else if Self.previewLooksLikeLaterReply(
                    preview,
                    needle: needle,
                    baseline: baselinePreview,
                    userPreview: nil
                ) {
                    return GrokDTurnFollowResult(outcome: .completed, lastPreview: preview)
                }
            } else if Self.previewLooksLikeLaterReply(
                preview,
                needle: needle,
                baseline: baselinePreview,
                userPreview: userPreview
            ) {
                return GrokDTurnFollowResult(outcome: .completed, lastPreview: preview)
            }
        }
        if sawPrompt {
            return GrokDTurnFollowResult(outcome: .promptLandedNoReply, lastPreview: lastPreview)
        }
        return GrokDTurnFollowResult(outcome: .stillRunning, lastPreview: lastPreview)
    }

    /// User line: exact prompt, or a truncation of it. A longer preview that
    /// merely *contains* the prompt is treated as an assistant/echo line.
    static func previewLooksLikePrompt(_ preview: String?, needle: String, baseline: String?) -> Bool {
        guard let preview, !preview.isEmpty, preview != baseline else { return false }
        if preview == needle { return true }
        return needle.hasPrefix(preview)
    }

    static func previewLooksLikeLaterReply(
        _ preview: String?,
        needle: String,
        baseline: String?,
        userPreview: String?
    ) -> Bool {
        guard let preview, !preview.isEmpty else { return false }
        if preview == baseline { return false }
        if preview == userPreview { return false }
        if preview == needle { return false }
        if needle.hasPrefix(preview) { return false }
        return true
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
        let decoder = JSONDecoder()
        do {
            return try decoder.decode([GrokDAgentRecord].self, from: data)
        } catch {
            struct Envelope: Decodable { let agents: [GrokDAgentRecord] }
            do {
                return try decoder.decode(Envelope.self, from: data).agents
            } catch {
                throw GrokDHostError.decoding
            }
        }
    }
}
