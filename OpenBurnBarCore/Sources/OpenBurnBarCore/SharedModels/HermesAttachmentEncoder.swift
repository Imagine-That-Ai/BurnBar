import Foundation

// MARK: - Hermes Attachment Encoder

/// Cross-platform helper that turns a chat history (text + attachments) into
/// the message array we send to an OpenAI-compatible chat completions
/// endpoint. The macOS app and the mobile app both call this so the wire
/// format is identical regardless of platform.
///
/// The encoder is intentionally pure: it never touches the network. Callers
/// pass in the raw bytes for each attachment (loaded from the chat workspace)
/// and get back a fully-shaped `[String: Any]` array suitable for
/// `JSONSerialization.data(withJSONObject:)`.
public enum HermesAttachmentEncoder {
    public struct Message: Sendable {
        public enum Role: String, Sendable {
            case system
            case user
            case assistant
            /// OpenAI `role: "tool"` reply produced after a local tool call.
            /// Tool messages always carry a non-nil `toolCallID` referencing
            /// the upstream `tool_calls[].id` they answer.
            case tool
        }

        /// One tool the assistant emitted on a prior turn, replayed verbatim
        /// to the model so it can see its own call history when we continue
        /// a tool-use loop. Always paired with an assistant-role message.
        public struct ReplayToolCall: Sendable, Equatable {
            public let id: String
            public let name: String
            public let arguments: String
            public init(id: String, name: String, arguments: String) {
                self.id = id
                self.name = name
                self.arguments = arguments
            }
        }

        public let role: Role
        public let text: String
        public let attachments: [HermesAttachment]
        /// Maps attachment IDs to their bytes when available. When an
        /// attachment is missing here (file unreadable) the encoder falls back
        /// to the metadata in the attachment itself.
        public let attachmentBytes: [String: Data]
        /// For `role: .assistant` turns that called tools, the
        /// `tool_calls[]` array we must replay back so the model can
        /// "see" the call it previously made before consuming the
        /// matching tool result.
        public let assistantToolCalls: [ReplayToolCall]
        /// For `role: .tool` reply messages, the matching upstream
        /// `tool_call.id`. Required when role is `.tool`; ignored
        /// otherwise.
        public let toolCallID: String?

        public init(
            role: Role,
            text: String,
            attachments: [HermesAttachment] = [],
            attachmentBytes: [String: Data] = [:],
            assistantToolCalls: [ReplayToolCall] = [],
            toolCallID: String? = nil
        ) {
            self.role = role
            self.text = text
            self.attachments = attachments
            self.attachmentBytes = attachmentBytes
            self.assistantToolCalls = assistantToolCalls
            self.toolCallID = toolCallID
        }
    }

    /// Build the OpenAI-compatible `messages` array. When `useMultimodal` is
    /// false (e.g. all messages are text-only) the result uses the legacy
    /// `{role, content: String}` shape so we don't break gateways that don't
    /// accept content arrays.
    public static func encodeMessages(
        systemPrompt: String,
        messages: [Message],
        capabilities: HermesBackendCapabilities = .default,
        workspaceAbsolutePath: ((HermesAttachment) -> String)? = nil
    ) -> [[String: Any]] {
        var output: [[String: Any]] = []

        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            output.append(["role": "system", "content": systemPrompt])
        }

        // Detect whether anything in this request actually carries
        // attachments. We only switch to the multimodal `content: [parts]`
        // shape when needed — otherwise we keep the legacy string body so
        // older relays / proxies don't choke on unknown content types.
        let needsMultimodal = messages.contains { !$0.attachments.isEmpty }

        for message in messages {
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Tool result replies are sent verbatim — they never carry
            // attachments. Skip empty ones; the upstream API requires
            // tool_call_id and content. Tool messages must always be the
            // reply to a prior assistant tool call, never a standalone.
            if message.role == .tool {
                guard let toolCallID = message.toolCallID,
                      !toolCallID.isEmpty,
                      !trimmed.isEmpty else { continue }
                output.append([
                    "role": "tool",
                    "tool_call_id": toolCallID,
                    "content": message.text
                ])
                continue
            }

            // Assistant turns that called tools must replay both their
            // pre-call text (often empty) and the `tool_calls` array, so
            // the model can pair its prior call with the upcoming tool
            // result. Empty content is encoded as `NSNull` because most
            // OpenAI-compatible relays reject an empty string for an
            // assistant message that carries `tool_calls`.
            if message.role == .assistant, !message.assistantToolCalls.isEmpty {
                let toolCalls: [[String: Any]] = message.assistantToolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments
                        ] as [String: Any]
                    ] as [String: Any]
                }
                var entry: [String: Any] = [
                    "role": "assistant",
                    "tool_calls": toolCalls
                ]
                entry["content"] = trimmed.isEmpty ? (NSNull() as Any) : message.text
                output.append(entry)
                continue
            }

            if trimmed.isEmpty && message.attachments.isEmpty { continue }

            if !needsMultimodal {
                output.append([
                    "role": message.role.rawValue,
                    "content": message.text
                ])
                continue
            }

            let parts = encodeParts(
                message: message,
                capabilities: capabilities,
                workspaceAbsolutePath: workspaceAbsolutePath
            )
            // Only assistant + system messages may collapse back to a plain
            // string — they never have attachments. User parts always go out
            // as an array when multimodal mode is on.
            output.append([
                "role": message.role.rawValue,
                "content": parts
            ])
        }

        return output
    }

    private static func encodeParts(
        message: Message,
        capabilities: HermesBackendCapabilities,
        workspaceAbsolutePath: ((HermesAttachment) -> String)?
    ) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var pendingTextSuffix: [String] = []

        for attachment in message.attachments {
            switch attachment.kind {
            case .image:
                if capabilities.vision,
                   let part = imageURLPart(for: attachment, bytes: message.attachmentBytes[attachment.id]) {
                    parts.append(part)
                } else {
                    pendingTextSuffix.append(workspaceReference(for: attachment, workspaceAbsolutePath: workspaceAbsolutePath))
                }
            case .pdf:
                if capabilities.vision,
                   let pdfBytes = message.attachmentBytes[attachment.id],
                   let part = imagePart(name: attachment.displayName, mime: attachment.mimeType, bytes: pdfBytes) {
                    parts.append(part)
                } else if let preview = attachment.extractedTextPreview, !preview.isEmpty {
                    pendingTextSuffix.append(textInlineBlock(name: attachment.displayName, body: preview, truncated: attachment.byteSize > preview.utf8.count))
                } else {
                    pendingTextSuffix.append(workspaceReference(for: attachment, workspaceAbsolutePath: workspaceAbsolutePath))
                }
            case .textDocument:
                let inline: String
                if let bytes = message.attachmentBytes[attachment.id], let body = decodeText(bytes) {
                    inline = inlinedText(body: body, byteSize: attachment.byteSize)
                } else if let preview = attachment.extractedTextPreview {
                    inline = inlinedText(body: preview, byteSize: attachment.byteSize)
                } else {
                    inline = workspaceReference(for: attachment, workspaceAbsolutePath: workspaceAbsolutePath)
                }
                pendingTextSuffix.append(textInlineBlock(name: attachment.displayName, body: inline, truncated: false))
            case .audio:
                if capabilities.audio,
                   let bytes = message.attachmentBytes[attachment.id],
                   let part = inputAudioPart(bytes: bytes, mime: attachment.mimeType, name: attachment.displayName) {
                    parts.append(part)
                } else {
                    pendingTextSuffix.append(workspaceReference(for: attachment, workspaceAbsolutePath: workspaceAbsolutePath))
                }
            case .video, .generic:
                pendingTextSuffix.append(workspaceReference(for: attachment, workspaceAbsolutePath: workspaceAbsolutePath))
            }
        }

        // Compose the text part: user prose first, then any inline blocks
        // (textDocuments, workspace refs) appended below it. We always emit a
        // text part so the model has something to respond to even if every
        // attachment was an image.
        var fullText = trimmedText
        if !pendingTextSuffix.isEmpty {
            if !fullText.isEmpty { fullText += "\n\n" }
            fullText += pendingTextSuffix.joined(separator: "\n\n")
        }
        if fullText.isEmpty && !parts.isEmpty {
            fullText = "(see attachments)"
        }
        if !fullText.isEmpty {
            parts.insert(["type": "text", "text": fullText], at: 0)
        }
        return parts
    }

    // MARK: - Part builders

    private static func imageURLPart(
        for attachment: HermesAttachment,
        bytes providedBytes: Data?
    ) -> [String: Any]? {
        guard let bytes = providedBytes else { return nil }
        return imagePart(name: attachment.displayName, mime: attachment.mimeType, bytes: bytes)
    }

    private static func imagePart(
        name: String,
        mime: String,
        bytes: Data
    ) -> [String: Any]? {
        guard !bytes.isEmpty else { return nil }
        let resolvedMime = mime.isEmpty ? "application/octet-stream" : mime
        let base64 = bytes.base64EncodedString()
        let dataURL = "data:\(resolvedMime);base64,\(base64)"
        return [
            "type": "image_url",
            "image_url": [
                "url": dataURL,
                "detail": "auto"
            ]
        ]
    }

    private static func inputAudioPart(
        bytes: Data,
        mime: String,
        name: String
    ) -> [String: Any]? {
        guard !bytes.isEmpty else { return nil }
        let format: String
        let lower = mime.lowercased()
        if lower.contains("wav") {
            format = "wav"
        } else if lower.contains("mpeg") || lower.contains("mp3") {
            format = "mp3"
        } else if lower.contains("aac") {
            format = "aac"
        } else if lower.contains("flac") {
            format = "flac"
        } else {
            // m4a / aiff / unknown — fall back to inferring from filename.
            let ext = (name as NSString).pathExtension.lowercased()
            format = ["m4a", "mp4", "aac"].contains(ext) ? "m4a" : "wav"
        }
        return [
            "type": "input_audio",
            "input_audio": [
                "data": bytes.base64EncodedString(),
                "format": format
            ]
        ]
    }

    private static func textInlineBlock(name: String, body: String, truncated: Bool) -> String {
        let trimmedBody = body
        let suffix = truncated ? "\n[truncated — full file in chat workspace]" : ""
        return "--- attachment: \(name) ---\n\(trimmedBody)\(suffix)\n--- end ---"
    }

    private static func inlinedText(body: String, byteSize: Int) -> String {
        // Inline up to 64 KB of UTF-8 text. Above that, head + tail.
        let maxInline = HermesAttachmentLimits.maxInlineTextBytes
        let bodyBytes = body.utf8.count
        if bodyBytes <= maxInline {
            return body
        }
        let head = body.prefix(32 * 1024)
        let tail = body.suffix(16 * 1024)
        return "\(head)\n\n[…truncated…]\n\n\(tail)"
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return nil
    }

    private static func workspaceReference(
        for attachment: HermesAttachment,
        workspaceAbsolutePath: ((HermesAttachment) -> String)?
    ) -> String {
        let abs = workspaceAbsolutePath?(attachment)
        let path = abs ?? attachment.workspaceRelativePath
        let bytes = formatBytes(attachment.byteSize)
        return """
        --- attached file ---
        name: \(attachment.displayName)
        type: \(attachment.kind.rawValue)
        size: \(bytes)
        path: \(path)
        --- end ---
        """
    }

    public static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB", mb)
        }
        if bytes >= 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
        }
        return "\(bytes) B"
    }
}

// MARK: - Convenience kind detection

public extension HermesAttachmentKind {
    /// Best-effort classification from a MIME type + filename. Used by the
    /// composer when accepting drag-and-drop / picker payloads.
    static func infer(mimeType: String, fileName: String) -> HermesAttachmentKind {
        let mime = mimeType.lowercased()
        let ext = (fileName as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"].contains(ext) {
            return .image
        }
        if mime == "application/pdf" || ext == "pdf" {
            return .pdf
        }
        if mime.hasPrefix("video/") || ["mov", "mp4", "m4v", "avi", "mkv"].contains(ext) {
            return .video
        }
        if mime.hasPrefix("audio/") || ["m4a", "mp3", "wav", "aif", "aiff", "flac", "aac"].contains(ext) {
            return .audio
        }
        if mime.hasPrefix("text/")
            || mime == "application/json"
            || mime == "application/xml"
            || mime == "application/x-yaml" {
            return .textDocument
        }
        let textExts: Set<String> = [
            "txt", "md", "markdown", "log", "csv", "tsv", "json", "yaml", "yml", "xml", "toml", "ini",
            "swift", "py", "js", "jsx", "ts", "tsx", "rb", "go", "rs", "kt", "java", "c", "cc", "cpp",
            "h", "hpp", "m", "mm", "sh", "bash", "zsh", "sql", "html", "css", "scss", "less", "env"
        ]
        if textExts.contains(ext) { return .textDocument }
        return .generic
    }
}
