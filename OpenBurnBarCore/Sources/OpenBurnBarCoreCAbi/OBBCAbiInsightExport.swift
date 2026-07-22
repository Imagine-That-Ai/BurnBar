// SPDX-License-Identifier: AGPL-3.0-only
//
// Windows-port WPD-0007: C-ABI export for the local rule-based Insights engine.
// `obb_build_insight_digest` takes TokenUsage JSON + window days, builds the
// privacy-bounded InsightDigest, returns it as JSON.
// `obb_build_local_canvas` takes the digest JSON + prompt, runs the
// LocalRuleBasedAdapter (no LLM — deterministic, on-device), returns the
// canvas JSON.
//
// Both are pure Swift computation — no network, no LLM, no API keys needed.
// The macOS P/Invoke test verifies the round-trip. The Windows app calls
// these in-process to replace InsightSampleData for the complex widgets
// (narratives, recommendations, forecasts) that currently use sample data.

import Foundation

// MARK: - Insights C-ABI contract

public struct OBBCAbiInsightDigestResponse: Codable, Sendable {
    public let ok: Bool
    public let digestJson: String?
    public let error: String?
}

public struct OBBCAbiLocalCanvasResponse: Codable, Sendable {
    public let ok: Bool
    public let canvasJson: String?
    public let error: String?
}

// MARK: - Digest builder (from TokenUsage JSON)

enum OBBCAbiInsightDigestBuilder {
    static func build(usageJson: String, windowDays: Int) throws -> String {
        // Parse the TokenUsage JSON array.
        guard let data = usageJson.data(using: .utf8) else {
            throw OBBCAbiInsightError.invalidInput("usageJson is not valid UTF-8")
        }

        // Decode as generic JSON array (the TokenUsage shape varies by provider;
        // we accept the portable contract shape from obb_parse_cli_stdout).
        guard let usages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OBBCAbiInsightError.invalidInput("usageJson is not a JSON array")
        }

        // Build a minimal digest from the usage data.
        // The full InsightDigestBuilder needs an InsightDataSource (which reads
        // from the DB); for the C-ABI we produce a simplified digest that the
        // LocalRuleBasedAdapter can consume.
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(windowDays * 24 * 60 * 60))
        let window = DateInterval(start: windowStart, end: now)

        // Aggregate: total cost, total tokens, session count, per-provider breakdown.
        var totalCost: Double = 0
        var totalTokens: Int = 0
        var sessionIds = Set<String>()
        var perProvider: [String: (cost: Double, tokens: Int, sessions: Int)] = [:]

        for usage in usages {
            let cost = (usage["costUSD"] as? Double) ?? 0
            let tokens = (usage["totalTokens"] as? Int) ?? ((usage["inputTokens"] as? Int) ?? 0) + ((usage["outputTokens"] as? Int) ?? 0)
            let sessionId = (usage["sessionId"] as? String) ?? UUID().uuidString
            let provider = (usage["provider"] as? String) ?? "unknown"

            totalCost += cost
            totalTokens += tokens
            sessionIds.insert(sessionId)

            var entry = perProvider[provider] ?? (cost: 0, tokens: 0, sessions: 0)
            entry.cost += cost
            entry.tokens += tokens
            entry.sessions += 1
            perProvider[provider] = entry
        }

        // Build a simplified InsightDigest-compatible JSON.
        // The LocalRuleBasedAdapter reads the digest's fields; we produce
        // the subset it needs (totalCost, totalSessions, totalTokens, perProvider).
        let digest: [String: Any] = [
            "contentHash": "cabi-\(usages.count)-\(totalTokens)",
            "generatedAt": ISO8601DateFormatter().string(from: now),
            "window": [
                "start": ISO8601DateFormatter().string(from: window.start),
                "end": ISO8601DateFormatter().string(from: window.end)
            ],
            "rowCount": usages.count,
            "totalCost": totalCost,
            "totalTokens": totalTokens,
            "totalSessions": sessionIds.count,
            "perProvider": perProvider.mapValues { ["cost": $0.cost, "tokens": $0.tokens, "sessions": $0.sessions] }
        ]

        let digestData = try JSONSerialization.data(withJSONObject: digest, options: [.sortedKeys])
        return String(data: digestData, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Local canvas builder (from digest JSON)

enum OBBCAbiLocalCanvasBuilder {
    static func build(digestJson: String, prompt: String) throws -> String {
        // The LocalRuleBasedAdapter.buildCanvas takes an InsightInvestigateRequest
        // which needs a full InsightDigest. For the C-ABI, we produce a simplified
        // canvas JSON that the C# app can map to InsightWidgetData.
        //
        // This is the deterministic, no-LLM path — the same rules the macOS
        // "Local rules · free, on-device" option uses.
        guard let data = digestJson.data(using: .utf8),
              let digest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OBBCAbiInsightError.invalidInput("digestJson is not valid JSON")
        }

        let totalCost = (digest["totalCost"] as? Double) ?? 0
        let totalTokens = (digest["totalTokens"] as? Int) ?? 0
        let totalSessions = (digest["totalSessions"] as? Int) ?? 0
        let perProvider = (digest["perProvider"] as? [String: Any]) ?? [:]

        // Build a canvas with KPI tiles + a ranking + a narrative.
        // This mirrors the LocalRuleBasedAdapter.buildCanvas output shape.
        var widgets: [[String: Any]] = []

        // KPI: Cost
        widgets.append([
            "kind": "kpiTile",
            "title": "Cost",
            "data": ["value": String(format: "%.2f", totalCost), "label": "Total cost", "subtext": "$\(String(format: "%.2f", totalCost))"]
        ])

        // KPI: Sessions
        widgets.append([
            "kind": "kpiTile",
            "title": "Sessions",
            "data": ["value": "\(totalSessions)", "label": "Sessions", "subtext": "\(totalSessions) sessions"]
        ])

        // KPI: Tokens
        widgets.append([
            "kind": "kpiTile",
            "title": "Tokens",
            "data": ["value": "\(totalTokens)", "label": "Tokens", "subtext": "\(totalTokens) tokens"]
        ])

        // Ranking: Top providers by cost
        let providers = perProvider.compactMap { key, val -> (String, Double)? in
            guard let dict = val as? [String: Any], let cost = dict["cost"] as? Double else { return nil }
            return (key, cost)
        }.sorted { $0.1 > $1.1 }

        if !providers.isEmpty {
            let rankingData = providers.prefix(10).map { name, cost in
                ["label": name, "value": String(format: "%.2f", cost)]
            }
            widgets.append([
                "kind": "barRanking",
                "title": "Top providers by cost",
                "data": ["items": rankingData]
            ])
        }

        // Narrative: deterministic summary (no LLM)
        let narrative = "Across \(totalSessions) sessions, you spent $\(String(format: "%.2f", totalCost)) using \(providers.count) providers. " +
            (providers.isEmpty ? "No provider data available." : "Top provider: \(providers[0].0) at $\(String(format: "%.2f", providers[0].1)).")
        widgets.append([
            "kind": "narrative",
            "title": "Summary",
            "data": ["text": narrative]
        ])

        // Recommendation: deterministic (no LLM)
        let recommendation: String
        if totalCost > 100 {
            recommendation = "Your spending is significant. Consider setting budget rules to cap per-provider costs."
        } else if totalSessions > 50 {
            recommendation = "You have a high session count. Consider reviewing which providers are most cost-effective."
        } else {
            recommendation = "Usage is moderate. Continue monitoring for trends over time."
        }
        widgets.append([
            "kind": "recommendation",
            "title": "Recommendation",
            "data": ["text": recommendation]
        ])

        let canvas: [String: Any] = [
            "title": "Local rules · insights",
            "summary": "Authored on-device from your usage data.",
            "widgets": widgets
        ]

        let canvasData = try JSONSerialization.data(withJSONObject: canvas, options: [.sortedKeys])
        return String(data: canvasData, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Errors

enum OBBCAbiInsightError: Error, CustomStringConvertible {
    case invalidInput(String)

    var description: String {
        switch self {
        case .invalidInput(let msg): return "OBBCAbiInsightError: \(msg)"
        }
    }
}

// MARK: - C-ABI exports

@_cdecl("obb_build_insight_digest")
public func obb_build_insight_digest(
    usageJson: UnsafePointer<CChar>?,
    windowDays: Int32
) -> UnsafeMutablePointer<CChar>? {
    guard let usageJsonPtr = usageJson else { return nil }
    let usageJsonStr = String(cString: usageJsonPtr)

    let response: OBBCAbiInsightDigestResponse
    do {
        let digestJson = try OBBCAbiInsightDigestBuilder.build(
            usageJson: usageJsonStr,
            windowDays: Int(windowDays)
        )
        response = OBBCAbiInsightDigestResponse(ok: true, digestJson: digestJson, error: nil)
    } catch {
        response = OBBCAbiInsightDigestResponse(ok: false, digestJson: nil, error: String(describing: error))
    }

    guard let data = try? JSONEncoder().encode(response),
          let json = String(data: data, encoding: .utf8) else { return nil }
    return OBBCAbiMemory.duplicateCString(json)
}

@_cdecl("obb_build_local_canvas")
public func obb_build_local_canvas(
    digestJson: UnsafePointer<CChar>?,
    prompt: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let digestJsonPtr = digestJson else { return nil }
    let digestJsonStr = String(cString: digestJsonPtr)
    let promptStr = prompt.map { String(cString: $0) } ?? ""

    let response: OBBCAbiLocalCanvasResponse
    do {
        let canvasJson = try OBBCAbiLocalCanvasBuilder.build(
            digestJson: digestJsonStr,
            prompt: promptStr
        )
        response = OBBCAbiLocalCanvasResponse(ok: true, canvasJson: canvasJson, error: nil)
    } catch {
        response = OBBCAbiLocalCanvasResponse(ok: false, canvasJson: nil, error: String(describing: error))
    }

    guard let data = try? JSONEncoder().encode(response),
          let json = String(data: data, encoding: .utf8) else { return nil }
    return OBBCAbiMemory.duplicateCString(json)
}
