import BurnBarCore
import Foundation
import Security

public struct BurnBarProviderExecutionResult: Sendable {
    public let outputText: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int

    public init(outputText: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int) {
        self.outputText = outputText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

public protocol BurnBarProviderExecuting: Sendable {
    func complete(prompt: String, route: BurnBarProviderRoute) async throws -> BurnBarProviderExecutionResult
}

public enum BurnBarProviderExecutorError: Error, LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case upstreamError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid BurnBar provider base URL: \(baseURL)"
        case .invalidResponse:
            return "BurnBar provider returned an invalid response."
        case .upstreamError(let statusCode, let body):
            return "BurnBar provider request failed with status \(statusCode): \(body)"
        }
    }
}

public struct BurnBarOpenAICompatibleProviderExecutor: BurnBarProviderExecuting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(prompt: String, route: BurnBarProviderRoute) async throws -> BurnBarProviderExecutionResult {
        guard let baseURL = URL(string: route.baseURL) else {
            throw BurnBarProviderExecutorError.invalidBaseURL(route.baseURL)
        }

        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ProviderCompletionRequest(
                model: route.resolvedModelID,
                messages: [.init(role: "user", content: prompt)]
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

        return BurnBarProviderExecutionResult(
            outputText: choice.message.content,
            inputTokens: decoded.usage.prompt_tokens,
            outputTokens: decoded.usage.completion_tokens,
            cacheReadTokens: decoded.usage.prompt_tokens_details?.cached_tokens ?? 0
        )
    }
}

public actor BurnBarKeychainSecretStore: BurnBarProviderSecretStoring {
    private let service: String

    public init(service: String = "com.burnbar.cursor-connector") {
        self.service = service
    }

    public func secret(for providerID: String) async throws -> String? {
        let account = "provider.\(providerID).apiKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
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
        let account = "provider.\(providerID).apiKey"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(secret.utf8)
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecItemNotFound {
                var createQuery = query
                createQuery[kSecValueData as String] = data
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

    let model: String
    let messages: [Message]
}

private struct ProviderCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    struct UsageDetails: Decodable {
        let cached_tokens: Int?
    }

    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let prompt_tokens_details: UsageDetails?
    }

    let choices: [Choice]
    let usage: Usage
}
