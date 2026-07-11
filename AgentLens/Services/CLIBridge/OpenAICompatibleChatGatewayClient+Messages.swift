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
    /// Builds the OpenAI-compatible `messages` array. When attachments are
    /// present anywhere in the history, the user-message bodies switch to the
    /// multimodal `content: [parts]` shape. Pure-text histories keep the
    /// legacy `{role, content: String}` form so older relays don't choke on
    /// unknown content types.
    static func buildMessages(
        systemPrompt: String,
        history: [ChatMessageRecord],
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil
    ) -> [[String: Any]] {
        let encoderMessages = history.compactMap { msg -> HermesAttachmentEncoder.Message? in
            let role: HermesAttachmentEncoder.Message.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil
            }
            // Pull this message's worth of attachment bytes from the caller-
            // supplied map (only the latest user message normally provides
            // bytes; persisted history attaches by metadata only).
            var msgBytes: [String: Data] = [:]
            for att in msg.attachments {
                if let data = attachmentBytes[att.id] {
                    msgBytes[att.id] = data
                }
            }
            return HermesAttachmentEncoder.Message(
                role: role,
                text: msg.content,
                attachments: msg.attachments,
                attachmentBytes: msgBytes
            )
        }
        let encoded = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: systemPrompt,
            messages: encoderMessages,
            capabilities: capabilities,
            workspaceAbsolutePath: { att in
                guard let workspaceURL else { return att.workspaceRelativePath }
                return workspaceURL.appendingPathComponent(att.workspaceRelativePath).path
            }
        )
        // T-AI-06: content-level secret scrubbing before any prompt reaches a model
        // provider. Redacts high-confidence credential shapes (API keys, AWS keys,
        // GitHub tokens, PEM private keys, bearer/JWT) from outbound message text.
        return encoded.map { scrubMessageContent($0) }
    }

    /// T-AI-06: redacts secrets from a single OpenAI-compatible message's textual
    /// content, including the multimodal `content: [parts]` `text` parts. Non-text
    /// parts (image data) are left untouched.
    static func scrubMessageContent(_ message: [String: Any]) -> [String: Any] {
        var scrubbed = message
        if let text = message["content"] as? String {
            scrubbed["content"] = AgentSecretScrubber.scrub(text)
        } else if let parts = message["content"] as? [[String: Any]] {
            scrubbed["content"] = parts.map { part -> [String: Any] in
                var p = part
                if let text = part["text"] as? String {
                    p["text"] = AgentSecretScrubber.scrub(text)
                }
                return p
            }
        }
        return scrubbed
    }

    /// T-AI-06: asserts no-retention / no-train intent to cooperating providers.
    /// Unknown headers are ignored harmlessly by non-cooperating gateways.
    static func applyNoRetentionHeaders(to request: inout URLRequest) {
        for (key, value) in AgentProviderRetentionPolicy.noRetentionHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    static func applyAdditionalHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (key, value) in headers {
            let field = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isEmpty, !trimmedValue.isEmpty else { continue }
            guard field.caseInsensitiveCompare("Authorization") != .orderedSame else { continue }
            request.setValue(trimmedValue, forHTTPHeaderField: field)
        }
    }
}
