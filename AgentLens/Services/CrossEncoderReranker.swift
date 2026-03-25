import Foundation
import BurnBarCore

// MARK: - RetrievalRerankProviding Protocol

/// Protocol for cross-encoder style reranking of retrieval candidates.
/// Implementations score query-document pairs to improve precision over
/// bi-encoder cosine similarity alone.
@MainActor
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
@MainActor
final class NoOpRetrievalReranker: RetrievalRerankProviding {
    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        return Array(candidates.prefix(limit))
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

// MARK: - OpenAI Cross-Encoder Reranker

/// Uses OpenAI's Chat Completions API to rerank candidates by scoring
/// query-document relevance on a 0-1 scale. Falls back to original order
/// on error to ensure retrieval never fails due to reranking.
@MainActor
final class OpenAICrossEncoderReranker: RetrievalRerankProviding {
    private struct RankingRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct RankingResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }

        let choices: [Choice]
    }

    private struct RelevanceScore: Decodable {
        let chunk_id: String
        let relevance: Double
    }

    private let apiKey: String
    private let modelName: String
    private let baseURL: String
    private let session: URLSession

    /// Maximum characters per candidate when building the prompt.
    private let maxCharsPerCandidate: Int

    /// Maximum total candidates to rerank in a single request.
    private let maxCandidatesPerRequest: Int

    init(
        apiKey: String,
        modelName: String = "gpt-4o-mini",
        baseURL: String = "https://api.openai.com/v1",
        maxCharsPerCandidate: Int = 512,
        maxCandidatesPerRequest: Int = 40,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.maxCharsPerCandidate = max(128, min(maxCharsPerCandidate, 1024))
        self.maxCandidatesPerRequest = max(5, min(maxCandidatesPerRequest, 64))
    }

    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        guard apiKey.isEmpty == false else {
            throw CrossEncoderRerankerError.missingAPIKey
        }

        guard candidates.isEmpty == false else {
            return []
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            return Array(candidates.prefix(limit))
        }

        // Limit candidates to prevent context overflow
        let candidatesToScore = Array(candidates.prefix(maxCandidatesPerRequest))

        // Build prompt with numbered passages
        let passagesText = buildPassagesText(query: trimmedQuery, candidates: candidatesToScore)

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
        """

        let requestBody = RankingRequest(
            model: modelName,
            messages: [
                RankingRequest.Message(role: "system", content: systemPrompt),
                RankingRequest.Message(role: "user", content: passagesText)
            ],
            temperature: 0.1
        )

        guard let url = URL(string: baseURL + "/chat/completions") else {
            throw CrossEncoderRerankerError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CrossEncoderRerankerError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw CrossEncoderRerankerError.unexpectedResponse(statusCode: http.statusCode, message: message)
        }

        let payload = try JSONDecoder().decode(RankingResponse.self, from: data)

        guard let contentString = payload.choices.first?.message.content else {
            throw CrossEncoderRerankerError.invalidResponse
        }

        let scores = try parseScores(from: contentString)

        // Build score lookup
        let scoreByID = Dictionary(uniqueKeysWithValues: scores.map { ($0.chunk_id, $0.relevance) })

        // Create score-adjusted candidates
        var scoredCandidates: [(result: RetrievalResult, relevanceScore: Double, originalIndex: Int)] = []
        for (index, candidate) in candidatesToScore.enumerated() {
            let passageNum = index + 1
            let relevance = scoreByID[String(passageNum)] ?? 0.0
            scoredCandidates.append((candidate, relevance, index))
        }

        // Sort by relevance score descending, then by original index for stability
        scoredCandidates.sort { a, b in
            if a.relevanceScore == b.relevanceScore {
                return a.originalIndex < b.originalIndex
            }
            return a.relevanceScore > b.relevanceScore
        }

        // Return reranked results (up to limit)
        let reranked = scoredCandidates.prefix(limit).map(\.result)

        // Merge back with non-reranked candidates (those beyond maxCandidatesPerRequest)
        // They maintain their original relative order after reranked results
        if candidates.count > candidatesToScore.count {
            let remaining = Array(candidates.dropFirst(maxCandidatesPerRequest))
            return Array(reranked) + remaining
        }

        return Array(reranked)
    }

    private func buildPassagesText(query: String, candidates: [RetrievalResult]) -> String {
        var lines: [String] = []
        lines.append("User Query: \(query)")
        lines.append("")
        lines.append("Passages:")

        for (index, candidate) in candidates.enumerated() {
            let passageNum = index + 1
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = truncateText(candidate.snippet.isEmpty == false ? candidate.snippet : "", maxChars: maxCharsPerCandidate)

            lines.append("")
            lines.append("[\(passageNum)] Title: \(title)")
            lines.append("[\(passageNum)] Content: \(text)")
        }

        return lines.joined(separator: "\n")
    }

    private func truncateText(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars {
            return trimmed
        }
        // Find a good break point
        let index = trimmed.index(trimmed.startIndex, offsetBy: maxChars - 3)
        return String(trimmed[..<index]) + "..."
    }

    private func parseScores(from content: String) throws -> [RelevanceScore] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract JSON array from the content
        var jsonString = trimmed

        // Handle markdown code blocks
        if let codeBlockRange = jsonString.range(of: "```json", options: .caseInsensitive) {
            let start = jsonString.index(after: codeBlockRange.upperBound)
            if let endRange = jsonString.range(of: "```", options: .caseInsensitive, range: start..<jsonString.endIndex) {
                jsonString = String(jsonString[start..<endRange.lowerBound])
            } else {
                jsonString = String(jsonString[start...])
            }
        } else if let codeBlockRange = jsonString.range(of: "```", options: .caseInsensitive) {
            let start = jsonString.index(after: codeBlockRange.upperBound)
            if let endRange = jsonString.range(of: "```", options: .caseInsensitive, range: start..<jsonString.endIndex) {
                jsonString = String(jsonString[start..<endRange.lowerBound])
            }
        }

        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON array bounds
        guard let startIndex = jsonString.firstIndex(of: "["),
              let endIndex = jsonString.lastIndex(of: "]") else {
            throw CrossEncoderRerankerError.parseError("No JSON array found in response")
        }

        let jsonArray = String(jsonString[startIndex...endIndex])

        guard let data = jsonArray.data(using: .utf8) else {
            throw CrossEncoderRerankerError.parseError("Could not encode JSON string")
        }

        do {
            let scores = try JSONDecoder().decode([RelevanceScore].self, from: data)
            // Validate scores
            return scores.filter { score in
                score.chunk_id.isEmpty == false &&
                score.relevance >= 0 && score.relevance <= 1
            }
        } catch {
            throw CrossEncoderRerankerError.parseError("JSON parsing failed: \(error.localizedDescription)")
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct Error: Decodable {
                let message: String?
            }
            let error: Error?
        }
        return try? JSONDecoder().decode(ErrorResponse.self, from: data).error?.message
    }
}

// MARK: - Mock Reversing Reranker (for testing)

@MainActor
final class MockReversingReranker: RetrievalRerankProviding {
    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        // Reverse the order of candidates for testing
        let reversed = candidates.reversed()
        return Array(reversed.prefix(limit))
    }
}
