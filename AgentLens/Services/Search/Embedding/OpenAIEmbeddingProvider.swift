import Foundation
import OpenBurnBarCore

// MARK: - OpenAI Embedding Provider Errors

/// Errors specific to OpenAI embedding generation.
enum OpenAIEmbeddingProviderError: LocalizedError {
    case missingAPIKey
    case unsupportedModel(String)
    case invalidBaseURL
    case unexpectedResponse(statusCode: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI indexing requires an API key."
        case .unsupportedModel(let model):
            return "Unsupported OpenAI embedding model: \(model)"
        case .invalidBaseURL:
            return "The OpenAI embeddings endpoint URL is invalid."
        case .unexpectedResponse(let statusCode, let message):
            if let message, message.isEmpty == false {
                return "OpenAI embeddings request failed (\(statusCode)): \(message)"
            }
            return "OpenAI embeddings request failed with status \(statusCode)."
        case .invalidResponse:
            return "OpenAI embeddings returned an invalid response."
        }
    }
}

// MARK: - OpenAI Embedding Provider

/// Embedding provider backed by OpenAI's embedding API.
/// Supports text-embedding-3-small, text-embedding-3-large, and text-embedding-ada-002.
final class OpenAIEmbeddingProvider: ChunkEmbeddingProviding, QueryEmbeddingProviding, Sendable {
    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable {
            let embedding: [Float]
        }

        struct APIError: Decodable {
            struct Details: Decodable {
                let message: String?
            }

            let error: Details?
        }

        let data: [Item]
    }

    /// Models supported by this provider.
    static let supportedModels: [String] = [
        "text-embedding-3-small",
        "text-embedding-3-large",
        "text-embedding-ada-002",
    ]

    let descriptor: EmbeddingModelDescriptor
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    init(
        apiKey: String,
        modelName: String,
        versionTag: String = "openai-v1",
        chunkerVersion: String = ProjectionIdentity.chunkerVersion,
        normalizationVersion: String = "unit-l2-v1",
        promptVersion: String = "plain-text-v1",
        baseURL: String = "https://api.openai.com/v1",
        session: URLSession = .shared
    ) throws {
        let dimensions = try Self.dimensions(for: modelName)
        self.descriptor = EmbeddingModelDescriptor(
            provider: "openai",
            modelName: modelName,
            dimensions: dimensions,
            distanceMetric: .cosine,
            versionTag: versionTag,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            promptVersion: promptVersion
        )
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    /// Returns the embedding dimensions for a given model name.
    static func dimensions(for modelName: String) throws -> Int {
        switch modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "text-embedding-3-small":
            return 1536
        case "text-embedding-3-large":
            return 3072
        case "text-embedding-ada-002":
            return 1536
        default:
            throw OpenAIEmbeddingProviderError.unsupportedModel(modelName)
        }
    }

    func embedding(for text: String) async throws -> [Float] {
        let vectors = try await embeddings(for: [text])
        return vectors.first ?? []
    }

    func embeddings(for texts: [String]) async throws -> [[Float]] {
        let input = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard input.isEmpty == false else { return [] }
        guard apiKey.isEmpty == false else { throw OpenAIEmbeddingProviderError.missingAPIKey }
        guard let url = URL(string: baseURL + "/embeddings") else {
            throw OpenAIEmbeddingProviderError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": descriptor.modelName,
            "input": input,
            "encoding_format": "float",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIEmbeddingProviderError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(EmbeddingResponse.APIError.self, from: data))?.error?.message
            throw OpenAIEmbeddingProviderError.unexpectedResponse(statusCode: http.statusCode, message: message)
        }

        let payload = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        let vectors = payload.data.map(\.embedding)
        guard vectors.count == input.count else {
            throw OpenAIEmbeddingProviderError.invalidResponse
        }
        return vectors
    }
}
