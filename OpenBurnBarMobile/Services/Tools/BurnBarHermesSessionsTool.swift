import Foundation

// MARK: - burnbar_hermes_sessions
//
// Hands the model a structured list of the user's recent Hermes sessions
// so it can answer questions like "which session burned the most tokens
// yesterday?" without inventing IDs.
//
// The tool returns JSON, not prose: the model can reformat it however
// suits the question. Each entry mirrors `HermesSessionSummary` minus the
// raw timestamps (we emit ISO-8601 strings) so the wire-format stays
// stable across language versions.

@MainActor
public struct BurnBarHermesSessionsTool: MobileTool {

    public init() {}

    public static let name = "burnbar_hermes_sessions"

    public var displayName: String { "List recent sessions" }

    public var description: String {
        """
        List the most recent Hermes/Pi sessions visible on this device. Use \
        this when the user asks about "my sessions", "yesterday's runs", or \
        "the session with the most tokens" so you can answer with real ids \
        rather than invented placeholders.

        Optional arguments:
          - `limit`: max sessions to return (1–50, default 10).
          - `query`: case-insensitive substring filter applied to title +
                      preview before returning results.

        Returns a JSON object: `{"sessions": [...], "count": <int>}`. Each \
        session has `id`, `title`, `preview`, `model`, `messageCount`, \
        `toolCallCount`, `inputTokens`, `outputTokens`, and an ISO-8601 \
        `lastActiveAt` when available.
        """
    }

    public var parametersSchema: [String: Any] {
        MobileToolJSONSchema.object(
            properties: [
                "limit": MobileToolJSONSchema.integer(
                    description: "Maximum number of sessions to return.",
                    minimum: 1,
                    maximum: 50
                ),
                "query": MobileToolJSONSchema.string(
                    description: "Optional case-insensitive substring filter applied to session title and preview."
                )
            ],
            required: [],
            description: "Read-only listing of the device's recent assistant sessions."
        )
    }

    public func execute(
        arguments: String,
        context: any MobileToolContext
    ) async throws -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        var limit = 10
        var query: String?

        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data, options: []))
                    as? [String: Any] else {
                throw MobileToolError.invalidArguments(
                    "expected a JSON object, got \(trimmed.prefix(80))"
                )
            }
            if let rawLimit = object["limit"] as? Int {
                limit = max(1, min(50, rawLimit))
            } else if let rawLimit = object["limit"] as? Double {
                limit = max(1, min(50, Int(rawLimit)))
            }
            if let rawQuery = object["query"] as? String {
                let cleaned = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                query = cleaned.isEmpty ? nil : cleaned.lowercased()
            }
        }

        let sessions = context.availableSessions
        let filtered: [MobileToolSessionSummary]
        if let query {
            filtered = sessions.filter { summary in
                let title = summary.title?.lowercased() ?? ""
                let preview = summary.preview?.lowercased() ?? ""
                return title.contains(query) || preview.contains(query)
            }
        } else {
            filtered = sessions
        }

        let trimmedSessions = Array(filtered.prefix(limit))
        let payload: [String: Any] = [
            "count": trimmedSessions.count,
            "total_available": sessions.count,
            "sessions": trimmedSessions.map(encodeSession)
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func encodeSession(_ session: MobileToolSessionSummary) -> [String: Any] {
        var dict: [String: Any] = [
            "id": session.id,
            "messageCount": session.messageCount,
            "toolCallCount": session.toolCallCount,
            "inputTokens": session.inputTokens,
            "outputTokens": session.outputTokens
        ]
        if let title = session.title, !title.isEmpty { dict["title"] = title }
        if let preview = session.preview, !preview.isEmpty { dict["preview"] = preview }
        if let model = session.model, !model.isEmpty { dict["model"] = model }
        if let date = session.lastActiveAt {
            dict["lastActiveAt"] = ISO8601DateFormatter.shared.string(from: date)
        }
        return dict
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
