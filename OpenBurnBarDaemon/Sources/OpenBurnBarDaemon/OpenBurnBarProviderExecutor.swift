import OpenBurnBarCore
import Foundation
import LocalAuthentication
import Security

public struct BurnBarProviderExecutionResult: Sendable {
    public let outputText: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public init(
        outputText: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) {
        self.outputText = outputText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

public struct BurnBarStructuredPromptRequest: Sendable {
    public let systemPrompt: String?
    public let userPrompt: String
    public let assistantContextBlocks: [String]
    public let jsonOnly: Bool

    public init(
        systemPrompt: String? = nil,
        userPrompt: String,
        assistantContextBlocks: [String] = [],
        jsonOnly: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.assistantContextBlocks = assistantContextBlocks
        self.jsonOnly = jsonOnly
    }
}

public protocol BurnBarProviderExecuting: Sendable {
    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult
}

public extension BurnBarProviderExecuting {
    func complete(prompt: String, route: BurnBarProviderRoute) async throws -> BurnBarProviderExecutionResult {
        try await completeStructured(
            BurnBarStructuredPromptRequest(userPrompt: prompt),
            route: route
        )
    }
}

public enum BurnBarProviderExecutorError: Error, LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case upstreamError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid OpenBurnBar provider base URL: \(baseURL)"
        case .invalidResponse:
            return "OpenBurnBar provider returned an invalid response."
        case .upstreamError(let statusCode, let body):
            return "OpenBurnBar provider request failed with status \(statusCode): \(body)"
        }
    }
}

public struct BurnBarOpenAICompatibleProviderExecutor: BurnBarProviderExecuting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func completeStructured(
        _ promptRequest: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        if let fakeResult = try BurnBarFakeProviderExecution.consumeNextResult(
            promptRequest: promptRequest,
            route: route
        ) {
            return fakeResult
        }

        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        var messages: [ProviderCompletionRequest.Message] = []
        if let systemPrompt = promptRequest.systemPrompt, !systemPrompt.isEmpty {
            messages.append(.init(role: "system", content: systemPrompt))
        }
        for assistantBlock in promptRequest.assistantContextBlocks where !assistantBlock.isEmpty {
            messages.append(.init(role: "assistant", content: assistantBlock))
        }
        messages.append(.init(role: "user", content: promptRequest.userPrompt))
        request.httpBody = try JSONEncoder().encode(
            ProviderCompletionRequest(
                model: route.resolvedModelID,
                messages: messages,
                responseFormat: promptRequest.jsonOnly ? .init(type: "json_object") : nil
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BurnBarProviderExecutorError.upstreamError(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(ProviderCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let usage = decoded.usage.normalized(
            inputHint: max(1, promptRequest.userPrompt.count / 4),
            outputHint: max(1, choice.message.content.count / 4)
        )

        return BurnBarProviderExecutionResult(
            outputText: choice.message.content,
            inputTokens: usage.promptTokens,
            outputTokens: usage.completionTokens,
            cacheCreationTokens: usage.cacheCreationTokens,
            cacheReadTokens: usage.cacheReadTokens
        )
    }
}

private enum BurnBarFakeProviderExecution {
    private struct Payload: Codable {
        var outputs: [String]
    }

    static func consumeNextResult(
        promptRequest: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) throws -> BurnBarProviderExecutionResult? {
        guard let filePath = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
              !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: filePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        var payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.outputs.isEmpty else {
            return BurnBarProviderExecutionResult(
                outputText: #"{"action":"fail","rationale":"No fake provider outputs remaining.","message":"No fake provider outputs remaining."}"#,
                inputTokens: max(1, promptRequest.userPrompt.count / 4),
                outputTokens: 16,
                cacheCreationTokens: 0,
                cacheReadTokens: 0
            )
        }

        let outputText = payload.outputs.removeFirst()
        try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)

        let inputPrompt = [promptRequest.systemPrompt, promptRequest.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: outputText,
            inputTokens: max(1, inputPrompt.count / 4),
            outputTokens: max(1, outputText.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}

public actor BurnBarKeychainSecretStore: BurnBarProviderSecretStoring {
    private let service: String

    public init(service: String = "com.openburnbar.cursor-connector") {
        self.service = service
    }

    public func secret(for providerID: String) async throws -> String? {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "openburnbar-fake-provider-key-\(providerID)"
        }

        let account = "provider.\(providerID).apiKey"
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        // Daemon reads must never surface interactive keychain prompts.
        // LAContext.interactionNotAllowed handles this on macOS 11+.
        if #unavailable(macOS 11.0) {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed {
            return nil
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String?, for providerID: String) async throws {
        if let fakeOutputs = ProcessInfo.processInfo.environment["BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE"],
           !fakeOutputs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let account = "provider.\(providerID).apiKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(secret.utf8)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var createQuery = query
                createQuery[kSecValueData as String] = data
                createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
                }
            } else if updateStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
            }
        } else {
            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(deleteStatus))
            }
        }
    }
}

private struct ProviderCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

private struct ProviderCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String

            private struct ContentPart: Decodable {
                let text: String?
                let type: String?
            }

            private enum CodingKeys: String, CodingKey {
                case content
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let stringContent = try? container.decode(String.self, forKey: .content) {
                    content = stringContent
                    return
                }
                if let contentParts = try? container.decode([ContentPart].self, forKey: .content) {
                    content = contentParts
                        .compactMap { part in
                            if let text = part.text, !text.isEmpty { return text }
                            return nil
                        }
                        .joined(separator: "\n")
                    return
                }
                content = ""
            }
        }

        let message: Message
    }

    struct UsageDetails: Decodable {
        let cached_tokens: Int?
        let cachedTokens: Int?
        let cache_read_tokens: Int?
        let cacheReadTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case cached_tokens
            case cachedTokens
            case cache_read_tokens
            case cacheReadTokens
        }
    }

    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation_tokens: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationTokens: Int?
        let total_tokens: Int?
        let totalTokens: Int?
        let cache_read_tokens: Int?
        let cache_read_input_tokens: Int?
        let cacheReadTokens: Int?
        let cached_tokens: Int?
        let cachedTokens: Int?
        let prompt_tokens_details: UsageDetails?
        let promptTokensDetails: UsageDetails?
        let thinking_tokens: Int?
        let reasoning_tokens: Int?
        let thinkingTokens: Int?
        let reasoningTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case prompt_tokens
            case completion_tokens
            case input_tokens
            case output_tokens
            case cache_creation_input_tokens
            case cache_creation_tokens
            case promptTokens
            case completionTokens
            case inputTokens
            case outputTokens
            case cacheCreationTokens
            case total_tokens
            case totalTokens
            case cache_read_tokens
            case cache_read_input_tokens
            case cacheReadTokens
            case cached_tokens
            case cachedTokens
            case prompt_tokens_details
            case promptTokensDetails
            case thinking_tokens
            case reasoning_tokens
            case thinkingTokens
            case reasoningTokens
        }

        struct NormalizedUsage {
            let promptTokens: Int
            let completionTokens: Int
            let cacheCreationTokens: Int
            let cacheReadTokens: Int
        }

        private func firstValue(_ values: Int?...) -> Int {
            for value in values {
                if let value {
                    return value
                }
            }
            return 0
        }

        func normalized(inputHint: Int, outputHint: Int) -> NormalizedUsage {
            var prompt = prompt_tokens
                ?? input_tokens
                ?? promptTokens
                ?? inputTokens
                ?? 0

            var completion = completion_tokens
                ?? output_tokens
                ?? completionTokens
                ?? outputTokens
                ?? 0

            let cacheRead = firstValue(
                cache_read_tokens,
                cache_read_input_tokens,
                cacheReadTokens,
                cached_tokens,
                cachedTokens,
                prompt_tokens_details?.cached_tokens,
                prompt_tokens_details?.cachedTokens,
                prompt_tokens_details?.cache_read_tokens,
                prompt_tokens_details?.cacheReadTokens,
                promptTokensDetails?.cached_tokens,
                promptTokensDetails?.cachedTokens,
                promptTokensDetails?.cache_read_tokens,
                promptTokensDetails?.cacheReadTokens
            )

            let cacheCreation = firstValue(
                cache_creation_input_tokens,
                cache_creation_tokens,
                cacheCreationTokens
            )

            let thinking = firstValue(
                thinking_tokens,
                reasoning_tokens,
                thinkingTokens,
                reasoningTokens
            )

            let total = total_tokens ?? totalTokens ?? 0
            let explicitTotal = prompt + completion + cacheCreation + cacheRead
            let normalizedTotal = max(total, explicitTotal)
            let availableForInOut = max(normalizedTotal - cacheCreation - cacheRead, 0)

            if prompt == 0 && completion == 0 && availableForInOut > 0 {
                let safeInputHint = max(inputHint, 1)
                let safeOutputHint = max(outputHint, 1)
                let ratio = Double(safeInputHint) / Double(safeInputHint + safeOutputHint)
                prompt = Int((Double(availableForInOut) * ratio).rounded())
                completion = max(availableForInOut - prompt, 0)
            } else if prompt == 0 && completion > 0 && availableForInOut > completion {
                prompt = availableForInOut - completion
            } else if completion == 0 && prompt > 0 && availableForInOut > prompt {
                completion = availableForInOut - prompt
            } else if prompt + completion < availableForInOut {
                completion += availableForInOut - (prompt + completion)
            }

            if thinking > 0 && total == 0 {
                completion += thinking
            }

            return NormalizedUsage(
                promptTokens: max(prompt, 0),
                completionTokens: max(completion, 0),
                cacheCreationTokens: max(cacheCreation, 0),
                cacheReadTokens: max(cacheRead, 0)
            )
        }
    }

    let choices: [Choice]
    let usage: Usage
}
