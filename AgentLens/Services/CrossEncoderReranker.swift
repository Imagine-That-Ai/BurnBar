import Foundation
import OpenBurnBarCore

// MARK: - RetrievalRerankProviding Protocol

/// Protocol for cross-encoder style reranking of retrieval candidates.
/// Implementations score query-document pairs to improve precision over
/// bi-encoder cosine similarity alone.

protocol RetrievalRerankProviding: Sendable {
    /// Reranks the provided candidates for the given query.
    /// - Parameters:
    ///   - query: The user's search query.
    ///   - candidates: Candidates to rerank, each with full text content for scoring.
    ///   - limit: Maximum number of candidates to return.
    /// - Returns: Reranked candidates, potentially reordered and/or reduced in count.
    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult]
}

// MARK: - NoOpRetrievalReranker

/// A no-op reranker that returns candidates unchanged.
/// Used as the default when reranking is disabled or unavailable.

final class NoOpRetrievalReranker: RetrievalRerankProviding {
    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        Array(candidates.prefix(limit))
    }
}

// MARK: - Cross-Encoder Errors

enum CrossEncoderRerankerError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case unexpectedResponse(statusCode: Int, message: String?)
    case invalidResponse
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Cross-encoder reranking requires an API key."
        case .invalidBaseURL:
            return "The cross-encoder API URL is invalid."
        case .unexpectedResponse(let statusCode, let message):
            if let message, message.isEmpty == false {
                return "Cross-encoder request failed (\(statusCode)): \(message)"
            }
            return "Cross-encoder request failed with status \(statusCode)."
        case .invalidResponse:
            return "Cross-encoder returned an invalid response."
        case .parseError(let detail):
            return "Failed to parse cross-encoder response: \(detail)"
        }
    }
}

// MARK: - Shared Prompt Helpers

private struct CrossEncoderRankingRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct CrossEncoderPromptPayload {
    let systemPrompt: String
    let userPrompt: String
    let scoredCandidates: [RetrievalResult]
}

private struct CrossEncoderRelevanceScore: Decodable {
    let chunk_id: String
    let relevance: Double
}

private enum CrossEncoderPromptBuilder {
    static func buildPrompt(
        query: String,
        candidates: [RetrievalResult],
        maxCharsPerCandidate: Int,
        maxCandidatesPerRequest: Int
    ) -> CrossEncoderPromptPayload? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            return nil
        }

        let scoredCandidates = Array(candidates.prefix(maxCandidatesPerRequest))
        guard scoredCandidates.isEmpty == false else {
            return nil
        }

        let systemPrompt = """
        You are a relevance scoring assistant. Given a user query and a list of passages,
        score each passage's relevance to the query on a scale from 0.0 to 1.0.

        Scoring guidelines:
        - 1.0: Passage directly answers or is highly relevant to the query
        - 0.7-0.9: Passage is relevant and contains useful information
        - 0.4-0.6: Passage mentions related topics but doesn't fully address the query
        - 0.1-0.3: Passage is tangentially related
        - 0.0: Passage is completely irrelevant

        Return your scores as a JSON array of objects with "chunk_id" (the passage number) and "relevance" (0.0-1.0).
        Only include passages you scored. Do not include passages with score 0.0.
        Never use tools or external resources. Reply with JSON only.
        """

        var lines: [String] = []
        lines.append("User Query: \(trimmedQuery)")
        lines.append("")
        lines.append("Passages:")

        for (index, candidate) in scoredCandidates.enumerated() {
            let passageNumber = index + 1
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredText = candidate.snippet.isEmpty == false
                ? candidate.snippet
                : candidate.title
            let text = truncateText(preferredText, maxChars: maxCharsPerCandidate)

            lines.append("")
            lines.append("[\(passageNumber)] Title: \(title)")
            lines.append("[\(passageNumber)] Content: \(text)")
        }

        return CrossEncoderPromptPayload(
            systemPrompt: systemPrompt,
            userPrompt: lines.joined(separator: "\n"),
            scoredCandidates: scoredCandidates
        )
    }

    static func rerankedResults(
        scores: [CrossEncoderRelevanceScore],
        scoredCandidates: [RetrievalResult],
        allCandidates: [RetrievalResult],
        limit: Int,
        maxCandidatesPerRequest: Int
    ) -> [RetrievalResult] {
        let scoreByID = Dictionary(uniqueKeysWithValues: scores.map { ($0.chunk_id, $0.relevance) })

        var scoredResults: [(result: RetrievalResult, relevanceScore: Double, originalIndex: Int)] = []
        scoredResults.reserveCapacity(scoredCandidates.count)

        for (index, candidate) in scoredCandidates.enumerated() {
            let passageNumber = index + 1
            let relevance = scoreByID[String(passageNumber)] ?? 0
            scoredResults.append((candidate, relevance, index))
        }

        scoredResults.sort { lhs, rhs in
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.originalIndex < rhs.originalIndex
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }

        let reranked = scoredResults.prefix(limit).map(\.result)

        if allCandidates.count > scoredCandidates.count {
            let remaining = Array(allCandidates.dropFirst(min(maxCandidatesPerRequest, allCandidates.count)))
            return Array(reranked) + remaining
        }

        return Array(reranked)
    }

    static func parseScores(from content: String) throws -> [CrossEncoderRelevanceScore] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var jsonString = trimmed

        if let codeBlockRange = jsonString.range(of: "```json", options: .caseInsensitive) {
            let start = jsonString.index(after: codeBlockRange.upperBound)
            if let endRange = jsonString.range(
                of: "```",
                options: .caseInsensitive,
                range: start..<jsonString.endIndex
            ) {
                jsonString = String(jsonString[start..<endRange.lowerBound])
            } else {
                jsonString = String(jsonString[start...])
            }
        } else if let codeBlockRange = jsonString.range(of: "```", options: .caseInsensitive) {
            let start = jsonString.index(after: codeBlockRange.upperBound)
            if let endRange = jsonString.range(
                of: "```",
                options: .caseInsensitive,
                range: start..<jsonString.endIndex
            ) {
                jsonString = String(jsonString[start..<endRange.lowerBound])
            }
        }

        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let startIndex = jsonString.firstIndex(of: "["),
              let endIndex = jsonString.lastIndex(of: "]") else {
            throw CrossEncoderRerankerError.parseError("No JSON array found in response")
        }

        let jsonArray = String(jsonString[startIndex...endIndex])

        guard let data = jsonArray.data(using: .utf8) else {
            throw CrossEncoderRerankerError.parseError("Could not encode JSON string")
        }

        do {
            let decoded = try JSONDecoder().decode([CrossEncoderRelevanceScore].self, from: data)
            return decoded.filter { score in
                score.chunk_id.isEmpty == false &&
                score.relevance >= 0 &&
                score.relevance <= 1
            }
        } catch {
            throw CrossEncoderRerankerError.parseError("JSON parsing failed: \(error.localizedDescription)")
        }
    }

    static func parseErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct ErrorPayload: Decodable {
                let message: String?
            }

            let error: ErrorPayload?
        }

        return try? JSONDecoder().decode(ErrorResponse.self, from: data).error?.message
    }

    static func parseChatCompletionText(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw CrossEncoderRerankerError.invalidResponse
        }

        if let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                throw CrossEncoderRerankerError.invalidResponse
            }
            return trimmed
        }

        if let blocks = message["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String {
                    return text
                }
                return nil
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard joined.isEmpty == false else {
                throw CrossEncoderRerankerError.invalidResponse
            }
            return joined
        }

        throw CrossEncoderRerankerError.invalidResponse
    }

    private static func truncateText(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxChars - 3)
        return String(trimmed[..<index]) + "..."
    }
}

// MARK: - OpenAI-Compatible HTTP Reranker

/// Uses an OpenAI-compatible Chat Completions endpoint to rerank candidates by
/// scoring query-document relevance on a 0-1 scale.

final class OpenAICompatibleCrossEncoderReranker: RetrievalRerankProviding {
    private let apiKey: String
    private let requiresAPIKey: Bool
    private let modelName: String
    private let baseURL: String
    private let session: URLSession
    private let extraHeaders: [String: String]
    private let maxCharsPerCandidate: Int
    private let maxCandidatesPerRequest: Int

    init(
        apiKey: String = "",
        requiresAPIKey: Bool = true,
        modelName: String,
        baseURL: String,
        extraHeaders: [String: String] = [:],
        maxCharsPerCandidate: Int = 512,
        maxCandidatesPerRequest: Int = 40,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requiresAPIKey = requiresAPIKey
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.extraHeaders = extraHeaders
        self.session = session
        self.maxCharsPerCandidate = max(128, min(maxCharsPerCandidate, 1024))
        self.maxCandidatesPerRequest = max(5, min(maxCandidatesPerRequest, 64))
    }

    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        guard requiresAPIKey == false || apiKey.isEmpty == false else {
            throw CrossEncoderRerankerError.missingAPIKey
        }

        guard candidates.isEmpty == false else {
            return []
        }

        guard let payload = CrossEncoderPromptBuilder.buildPrompt(
            query: query,
            candidates: candidates,
            maxCharsPerCandidate: maxCharsPerCandidate,
            maxCandidatesPerRequest: maxCandidatesPerRequest
        ) else {
            return Array(candidates.prefix(limit))
        }

        let requestBody = CrossEncoderRankingRequest(
            model: modelName,
            messages: [
                CrossEncoderRankingRequest.Message(role: "system", content: payload.systemPrompt),
                CrossEncoderRankingRequest.Message(role: "user", content: payload.userPrompt)
            ],
            temperature: 0.1
        )

        let content = try await requestCompletion(body: requestBody)
        let scores = try CrossEncoderPromptBuilder.parseScores(from: content)

        return CrossEncoderPromptBuilder.rerankedResults(
            scores: scores,
            scoredCandidates: payload.scoredCandidates,
            allCandidates: candidates,
            limit: limit,
            maxCandidatesPerRequest: maxCandidatesPerRequest
        )
    }

    private func requestCompletion(body: CrossEncoderRankingRequest) async throws -> String {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw CrossEncoderRerankerError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if apiKey.isEmpty == false {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CrossEncoderRerankerError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw CrossEncoderRerankerError.unexpectedResponse(
                statusCode: http.statusCode,
                message: CrossEncoderPromptBuilder.parseErrorMessage(from: data)
            )
        }

        return try CrossEncoderPromptBuilder.parseChatCompletionText(from: data)
    }
}

typealias OpenAICrossEncoderReranker = OpenAICompatibleCrossEncoderReranker

// MARK: - CLI Reranker


final class CLICrossEncoderReranker: RetrievalRerankProviding {
    enum Provider {
        case codex
        case claude
    }

    private let provider: Provider
    private let modelName: String
    private let cliBridge: CLIBridge
    private let maxCharsPerCandidate: Int
    private let maxCandidatesPerRequest: Int

    init(
        provider: Provider,
        modelName: String,
        cliBridge: CLIBridge = CLIBridge(),
        maxCharsPerCandidate: Int = 512,
        maxCandidatesPerRequest: Int = 40
    ) {
        self.provider = provider
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cliBridge = cliBridge
        self.maxCharsPerCandidate = max(128, min(maxCharsPerCandidate, 1024))
        self.maxCandidatesPerRequest = max(5, min(maxCandidatesPerRequest, 64))
    }

    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        guard candidates.isEmpty == false else {
            return []
        }

        guard let payload = CrossEncoderPromptBuilder.buildPrompt(
            query: query,
            candidates: candidates,
            maxCharsPerCandidate: maxCharsPerCandidate,
            maxCandidatesPerRequest: maxCandidatesPerRequest
        ) else {
            return Array(candidates.prefix(limit))
        }

        let content: String
        switch provider {
        case .codex:
            content = try await cliBridge.generateTextWithCodex(
                model: modelName,
                systemPrompt: payload.systemPrompt,
                userMessage: payload.userPrompt
            )
        case .claude:
            content = try await cliBridge.generateTextWithClaude(
                model: modelName,
                systemPrompt: payload.systemPrompt,
                userMessage: payload.userPrompt
            )
        }

        let scores = try CrossEncoderPromptBuilder.parseScores(from: content)

        return CrossEncoderPromptBuilder.rerankedResults(
            scores: scores,
            scoredCandidates: payload.scoredCandidates,
            allCandidates: candidates,
            limit: limit,
            maxCandidatesPerRequest: maxCandidatesPerRequest
        )
    }
}

// MARK: - Mock Reversing Reranker (for testing)


final class MockReversingReranker: RetrievalRerankProviding {
    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        let reversed = candidates.reversed()
        return Array(reversed.prefix(limit))
    }
}
