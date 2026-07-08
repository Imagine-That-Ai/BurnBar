import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct OpenAICompatibleChatGatewayClient: Sendable {
    let runtime: CLIBridgeStreamRuntimeCoordinator

    /// Shared SSE path for Hermes gateway API and OpenClaw gateway (OpenAI-compatible).
    func runStream(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        unavailableError: CLIBridgeError,
        missingModelError: CLIBridgeError,
        disallowedModelError: CLIBridgeError? = nil,
        httpStreamID: UInt64,
        allowedModels: ModelAllowlist? = nil,
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil,
        toolBroker: AgentToolBroker? = nil,
        plugins: [[String: any Sendable]]? = nil,
        additionalHeaders: [String: String] = [:],
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        defer {
            Task { [runtime] in
                await runtime.clearHTTPStreamTask(streamID: httpStreamID)
            }
        }

        guard let url = URL(string: "v1/chat/completions", relativeTo: baseURL)?.absoluteURL else {
            continuation.finish(throwing: unavailableError)
            return
        }

        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else {
            continuation.finish(throwing: missingModelError)
            return
        }
        if let allowedModels, !allowedModels.allows(model) {
            continuation.finish(throwing: disallowedModelError ?? CLIBridgeError.disallowedModel(backend: "OpenAI-compatible gateway", model: model))
            return
        }

        let messages = Self.buildMessages(
            systemPrompt: systemPrompt,
            history: history,
            attachmentBytes: attachmentBytes,
            capabilities: capabilities,
            workspaceURL: workspaceURL
        )

        // Phase 4 — AgentLens-plane budget gate. Subscription credentials short-circuit
        // inside BudgetGate so flat-rate plans never get blocked here. Gate runs before
        // the URLRequest leaves the host so a blocked call never reaches the upstream.
        let credential = AgentLensCredentialIdentity.make(
            providerHint: baseURL.host?.lowercased() ?? "agentlens_gateway",
            bearerToken: bearerToken,
            displayLabel: baseURL.host ?? selectedModel
        )
        let estimatedInputChars = messages.reduce(0) { acc, msg in
            acc + (msg["content"] as? String ?? "").count
        }
        let estimatedCost = await MainActor.run {
            BudgetEnforcement.estimateCost(
                model: selectedModel,
                inputCharacters: estimatedInputChars + systemPrompt.count
            )
        }
        let decision = await BudgetEnforcement.shared.evaluate(
            credential: credential,
            estimatedCost: estimatedCost
        )
        switch decision {
        case .block(let rule, let used, let limit, let fallback):
            continuation.finish(throwing: BudgetBlockedError(
                rule: rule,
                used: used,
                limit: limit,
                fallback: fallback,
                resetAt: rule.period.nextReset()
            ))
            return
        case .allow, .warn, .paused:
            break
        }

        if let toolBroker, toolBroker.isActive, !toolBroker.openAITools.isEmpty {
            await Self.runToolEnabledLoop(
                url: url,
                messages: messages,
                model: selectedModel,
                session: URLSession(configuration: .default),
                bearerToken: bearerToken,
                toolBroker: toolBroker,
                continuation: continuation,
                plugins: plugins,
                additionalHeaders: additionalHeaders
            )
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var streamedAnyContent = false
        var parser = OpenAICompatibleSSEParser()
        do {
            var body: [String: Any] = [
                "model": selectedModel,
                "stream": true,
                "messages": messages,
                "stream_options": ["include_usage": true]
            ]
            if let plugins, !plugins.isEmpty {
                body["plugins"] = plugins
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            Self.applyNoRetentionHeaders(to: &request)
            Self.applyAdditionalHeaders(additionalHeaders, to: &request)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let detail = try await Self.errorDetail(
                    statusCode: http.statusCode,
                    lines: bytes.lines
                )
                continuation.finish(throwing: CLIBridgeError.hermesSSEError(detail))
                return
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                let result = parser.events(fromLine: line)
                for event in result.events {
                    continuation.yield(event)
                }
                if result.streamedText {
                    streamedAnyContent = true
                }
                if result.done {
                    break
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if !streamedAnyContent {
            do {
                try Task.checkCancellation()
                let content = try await Self.nonStreamingFallback(
                    url: url,
                    messages: messages,
                    model: selectedModel,
                    session: session,
                    bearerToken: bearerToken,
                    plugins: plugins,
                    additionalHeaders: additionalHeaders
                )
                if !content.content.isEmpty {
                    continuation.yield(.text(content.content))
                }
                if let usage = content.usage {
                    continuation.yield(.usage(usage))
                }
            } catch is CancellationError {
                // Stream cancellation is a normal user action.
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        continuation.finish()
    }

    struct OpenAIToolCall: Equatable {
        let id: String
        let name: String
        let arguments: String
    }

    /// T-AI-08: fail-closed model allowlist. The gateway advertises which
    /// models it is willing to serve via `/v1/models`; callers pass that
    /// catalog here so a poisoned or attacker-chosen model id cannot be
    /// forwarded upstream. An empty allowlist disables enforcement.
    struct ModelAllowlist: Sendable {
        let modelIDs: Set<String>

        init(modelIDs: [String]) {
            self.modelIDs = Set(modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }

        /// Normalize provider-scoped ids (`anthropic/claude-sonnet-4-6`) and
        /// bare ids against the allowed set.
        func allows(_ modelID: String) -> Bool {
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard trimmed == modelID else { return false }
            if modelIDs.isEmpty { return true }
            let lower = trimmed.lowercased()
            for allowed in modelIDs {
                if allowed.lowercased() == lower { return true }
                let scoped = allowed.split(separator: "/").map(String.init)
                if scoped.count > 1, scoped.last?.lowercased() == lower { return true }
            }
            return false
        }
    }
}
