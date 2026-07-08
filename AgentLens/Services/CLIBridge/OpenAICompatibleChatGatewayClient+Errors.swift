import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

extension OpenAICompatibleChatGatewayClient {
    static func nonStreamingFallback(
        url: URL,
        messages: [[String: Any]],
        model: String,
        session: URLSession,
        bearerToken: String?,
        plugins: [[String: any Sendable]]? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws -> (content: String, usage: CLIUsageSnapshot?) {
        var body: [String: Any] = ["model": model, "stream": false, "messages": messages]
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

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CLIBridgeError.hermesSSEError(Self.errorDetail(statusCode: http.statusCode, data: data))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(JSON parse fallback)
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] // try?-ok(JSON parse fallback)
            return ("", OpenAICompatibleUsageParser.usage(from: obj))
        }

        return (content, OpenAICompatibleUsageParser.usage(from: obj))
    }

    static func errorDetail<Lines: AsyncSequence>(
        statusCode: Int,
        lines: Lines
    ) async throws -> String where Lines.Element == String {
        var chunks: [String] = []
        for try await line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            chunks.append(trimmed)
            if chunks.joined(separator: "\n").count > 4096 { break }
        }
        let text = chunks.joined(separator: "\n")
        guard !text.isEmpty else {
            return appendingAuthGuidanceIfNeeded("HTTP \(statusCode)", statusCode: statusCode)
        }
        if let data = text.data(using: .utf8) {
            return errorDetail(statusCode: statusCode, data: data)
        }
        return appendingAuthGuidanceIfNeeded("HTTP \(statusCode): \(text)", statusCode: statusCode)
    }

    static func errorDetail(statusCode: Int, data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail: String
        if let parsed = parsedErrorMessage(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsed.isEmpty {
            if parsed.localizedCaseInsensitiveContains("HTTP \(statusCode)") {
                detail = parsed
            } else {
                detail = "HTTP \(statusCode): \(parsed)"
            }
        } else if text.isEmpty {
            detail = "HTTP \(statusCode)"
        } else {
            detail = "HTTP \(statusCode): \(text)"
        }
        return appendingAuthGuidanceIfNeeded(detail, statusCode: statusCode)
    }

    /// A 401/403 from any OpenAI-compatible gateway is a configuration problem
    /// the user can fix — say where, instead of leaving the raw gateway JSON as
    /// a dead end. This client serves Hermes, OpenClaw, and Pi alike, so the
    /// guidance stays backend-neutral; the Hermes pre-send gate delivers the
    /// Hermes-specific remedies (`hermesAuthRejectedMessage`).
    static func appendingAuthGuidanceIfNeeded(_ detail: String, statusCode: Int) -> String {
        guard OpenAICompatibleModelProbe.isAuthRejectedStatus(statusCode) else { return detail }
        return detail + " — the gateway rejected this app's API key. "
            + "Update this backend's Bearer Token under Settings → Chat Gateway, then send again."
    }

    private static func parsedErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(JSON parse fallback)
            return nil
        }
        if let error = obj["error"] as? String {
            return error
        }
        if let error = obj["error"] as? [String: Any] {
            return (error["message"] as? String)
                ?? (error["detail"] as? String)
                ?? (error["code"] as? String)
        }
        if let message = obj["message"] as? String {
            return message
        }
        if let detail = obj["detail"] as? String {
            return detail
        }
        if let hermes = obj["hermes"] as? [String: Any],
           let error = hermes["error"] as? String {
            return error
        }
        return nil
    }
}
