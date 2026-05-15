import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OSLog

// MARK: - CLI Agent Session Mirror
//
// Pushes the live CLI agent transcript (Codex / Claude Code / OpenClaw)
// up to Firestore so the iOS Assistants tab can render the same chat
// the user is having on their Mac — full with tool-use pills.
//
// Document layout:
//   users/{uid}/cli_sessions/{threadID}
//
// `merge: true` upserts so partial in-flight streams are visible to iOS
// as they grow, without needing per-message subcollections (the
// transcript stays small enough for one document).
//
// Authorization mirrors `ConversationSyncService`: signed in,
// `isCloudSyncEnabled`, and `chatTranscriptCloudBackupEnabled`. The new
// preference key keeps the mirror opt-out from the broader cloud sync
// toggle so privacy-conscious users can disable transcript mirroring
// without losing telemetry sync.

@MainActor
final class CLIAgentSessionMirror {

    static let shared = CLIAgentSessionMirror()

    /// User preference key controlling whether the mirror is active.
    /// Defaults to `true` once the user opts into cloud sync — keeps
    /// the iOS Assistants tab useful by default. Power users can set
    /// it to `false` in Settings → Privacy.
    static let preferenceKey = "chat.cliAgentMirror.enabled"

    private let firestoreProvider: () -> Firestore
    private let accountManager: AccountManager
    private let defaults: UserDefaults
    private let logger: Logger

    init(
        firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() },
        accountManager: AccountManager = .shared,
        defaults: UserDefaults = .standard,
        logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.openburnbar.app", category: "CLIAgentSessionMirror")
    ) {
        self.firestoreProvider = firestoreProvider
        self.accountManager = accountManager
        self.defaults = defaults
        self.logger = logger
    }

    // MARK: - Public

    /// Mirror a CLI agent session. Safe to call after every
    /// `saveChatMessage` in `ChatSessionController` — the merge upsert
    /// keeps it idempotent.
    ///
    /// Returns silently when the user is signed out, the mirror is
    /// disabled, the runtime isn't a CLI agent (hermes/pi have their
    /// own mirror via `MobileChatHistoryStore`), or the messages
    /// collection is empty.
    func mirror(
        threadID: String,
        backend: ChatBackendID,
        modelName: String?,
        workspaceLabel: String?,
        messages: [ChatMessageRecord],
        usage: CLIUsageSnapshot? = nil,
        endedAt: Date? = nil
    ) async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              isEnabled,
              let agent = Self.cliAgent(for: backend),
              let uid = accountManager.userID,
              !messages.isEmpty else {
            return
        }

        let record = Self.build(
            threadID: threadID,
            agent: agent,
            modelName: modelName,
            workspaceLabel: workspaceLabel,
            messages: messages,
            usage: usage,
            endedAt: endedAt
        )

        let payload = CLIAgentSessionCodec.encode(record)
        let firestore = firestoreProvider()
        let docRef = firestore
            .collection("users").document(uid)
            .collection("cli_sessions").document(threadID)
        do {
            try await docRef.setData(payload, merge: true)
            logger.debug("mirrored CLI session \(threadID, privacy: .public) agent=\(record.agent.rawValue, privacy: .public) messages=\(record.messages.count)")
        } catch {
            logger.warning("CLI mirror upload failed for \(threadID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Mirror a provider-owned CLI log as a first-class assistant session.
    /// The full transcript remains in the encrypted `session_logs` cloud
    /// vault; this plaintext row is only the non-secret index/resume surface
    /// that lets iOS list, search, and route the session alongside live
    /// OpenBurnBar chats.
    func mirrorArchivedLog(_ conversation: ConversationRecord, cloudLogDocumentID: String? = nil) async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              isEnabled,
              let uid = accountManager.userID,
              let record = Self.buildArchivedLogRecord(
                conversation: conversation,
                cloudLogDocumentID: cloudLogDocumentID
              ) else {
            return
        }

        let payload = CLIAgentSessionCodec.encode(record)
        let firestore = firestoreProvider()
        let docRef = firestore
            .collection("users").document(uid)
            .collection("cli_sessions").document(Self.firestoreDocumentID(for: record))
        do {
            try await docRef.setData(payload, merge: true)
            logger.debug("mirrored archived CLI log \(record.id, privacy: .public) agent=\(record.agent.rawValue, privacy: .public)")
        } catch {
            logger.warning("Archived CLI mirror upload failed for \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Hard-delete the mirrored copy of a thread (used when the user
    /// deletes the thread locally). Best-effort: failures are logged
    /// and swallowed.
    func delete(threadID: String) async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              let uid = accountManager.userID else { return }
        do {
            try await firestoreProvider()
                .collection("users").document(uid)
                .collection("cli_sessions").document(threadID)
                .delete()
        } catch {
            logger.warning("CLI mirror delete failed for \(threadID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Live preference value. Reads `UserDefaults`; defaults to `true`
    /// when no value is set so users opted into cloud sync see iOS
    /// transcripts immediately. Power users can flip the toggle.
    var isEnabled: Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    // MARK: - Builder

    /// Map a `ChatBackendID` to its CLI counterpart. Returns `nil` for
    /// `hermes` / `piAgent` — those runtimes already mirror via the
    /// iOS-originated `MobileAssistantChatReader` path on macOS, so we
    /// don't double-publish.
    static func cliAgent(for backend: ChatBackendID) -> CLIAgentRuntime? {
        switch backend {
        case .codex:    return .codex
        case .claude:   return .claude
        case .openclaw: return .openClaw
        case .hermes, .piAgent: return nil
        }
    }

    /// Convert the controller's in-memory transcript into a Sendable
    /// record ready for Firestore. Exposed `internal` so unit tests can
    /// assert the conversion without spinning up a real account.
    static func build(
        threadID: String,
        agent: CLIAgentRuntime,
        modelName: String?,
        workspaceLabel: String?,
        messages: [ChatMessageRecord],
        usage: CLIUsageSnapshot?,
        endedAt: Date?
    ) -> CLIAgentSessionRecord {
        let cliMessages = messages.map { convert($0) }
        let createdAt = messages.first?.timestamp ?? Date()
        let updatedAt = messages.last?.timestamp ?? createdAt
        let title = derivedTitle(messages: messages)
        let preview = derivedPreview(messages: messages)
        let tokenUsage = usage.map { snapshot in
            CLIAgentTokenUsage(
                inputTokens: snapshot.inputTokens,
                outputTokens: snapshot.outputTokens,
                cacheCreationTokens: snapshot.cacheCreationTokens,
                cacheReadTokens: snapshot.cacheReadTokens,
                reasoningTokens: snapshot.reasoningTokens
            )
        }
        return CLIAgentSessionRecord(
            id: threadID,
            agent: agent,
            title: title,
            preview: preview,
            modelName: modelName?.nilIfBlank,
            workspaceLabel: workspaceLabel?.nilIfBlank,
            createdAt: createdAt,
            updatedAt: updatedAt,
            endedAt: endedAt,
            messages: cliMessages,
            tokenUsage: tokenUsage
        )
    }

    static func buildArchivedLogRecord(
        conversation: ConversationRecord,
        cloudLogDocumentID: String? = nil
    ) -> CLIAgentSessionRecord? {
        guard conversation.sourceType == .providerLog,
              let agent = archivedAgent(for: conversation.provider) else {
            return nil
        }

        let title = archivedTitle(for: conversation)
        let preview = archivedPreview(for: conversation)
        let createdAt = conversation.startTime ?? conversation.indexedAt
        let updatedAt = conversation.endTime ?? conversation.startTime ?? conversation.indexedAt
        let handle = CLIAgentResumeHandle(
            providerSessionID: conversation.sessionId,
            projectLabel: conversation.projectName.nilIfBlank,
            commandHint: commandHint(agent: agent, sessionID: conversation.sessionId),
            canResume: agent == .codex || agent == .claude,
            canFork: agent == .codex || agent == .claude,
            canForward: true
        )
        let transcriptMessages = archivedMessages(for: conversation)
        let archivedID = [
            "archive",
            agent.rawValue,
            cloudLogDocumentID?.nilIfBlank ?? conversation.id
        ].joined(separator: ":")

        return CLIAgentSessionRecord(
            id: archivedID,
            agent: agent,
            sourceKind: .archivedLog,
            title: title,
            preview: preview,
            modelName: nil,
            workspaceLabel: conversation.projectName.nilIfBlank,
            createdAt: createdAt,
            updatedAt: updatedAt,
            endedAt: updatedAt,
            messages: transcriptMessages,
            tokenUsage: nil,
            resumeHandle: handle,
            encryptedTranscriptAvailable: true
        )
    }

    static func archivedAgent(for provider: AgentProvider) -> CLIAgentRuntime? {
        switch provider {
        case .codex: return .codex
        case .claudeCode: return .claude
        case .openClaw: return .openClaw
        default: return nil
        }
    }

    static func firestoreDocumentID(for record: CLIAgentSessionRecord) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let scalars = record.id.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? UUID().uuidString : String(sanitized.prefix(512))
    }

    private static func archivedTitle(for conversation: ConversationRecord) -> String {
        if let title = conversation.summaryTitle?.nilIfBlank { return String(title.prefix(120)) }
        if let summary = conversation.summary?.nilIfBlank { return String(summary.prefix(120)) }
        return String((conversation.inferredTaskTitle.nilIfBlank ?? conversation.sessionId).prefix(120))
    }

    private static func archivedPreview(for conversation: ConversationRecord) -> String {
        let preview = conversation.lastAssistantMessage.nilIfBlank
            ?? conversation.summary?.nilIfBlank
            ?? conversation.fullText.nilIfBlank
            ?? "Encrypted transcript archived from \(conversation.provider.displayName)."
        return String(preview.prefix(500))
    }

    private static func commandHint(agent: CLIAgentRuntime, sessionID: String) -> String? {
        let safe = sessionID.replacingOccurrences(of: "\"", with: "\\\"")
        switch agent {
        case .codex:
            return "codex resume \"\(safe)\""
        case .claude:
            return "claude --resume \"\(safe)\""
        case .openClaw:
            return nil
        }
    }

    private static func archivedMessages(for conversation: ConversationRecord) -> [CLIAgentMessage] {
        let raw = conversation.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return conversation.lastAssistantMessage.nilIfBlank.map { message in
                [
                    CLIAgentMessage(
                        id: "\(conversation.id)-assistant-preview",
                        role: .assistant,
                        text: String(message.prefix(8_000)),
                        timestamp: conversation.endTime ?? conversation.startTime ?? conversation.indexedAt
                    )
                ]
            } ?? []
        }

        let blocks = parseMarkdownTurns(raw)
        let cappedBlocks = Array(blocks.prefix(120))
        if !cappedBlocks.isEmpty {
            let start = conversation.startTime ?? conversation.indexedAt
            let end = conversation.endTime ?? start
            let step = max(1, end.timeIntervalSince(start) / Double(max(cappedBlocks.count, 1)))
            return cappedBlocks.enumerated().map { index, block in
                CLIAgentMessage(
                    id: "\(conversation.id)-archived-\(index)",
                    role: block.role,
                    text: String(block.text.prefix(8_000)),
                    timestamp: start.addingTimeInterval(step * Double(index)),
                    isError: false,
                    toolUses: []
                )
            }
        }

        return [
            CLIAgentMessage(
                id: "\(conversation.id)-archived-transcript",
                role: .assistant,
                text: String(raw.prefix(16_000)),
                timestamp: conversation.endTime ?? conversation.startTime ?? conversation.indexedAt,
                isError: false,
                toolUses: []
            )
        ]
    }

    private static func parseMarkdownTurns(_ raw: String) -> [(role: CLIAgentRole, text: String)] {
        let lines = raw.components(separatedBy: .newlines)
        var turns: [(role: CLIAgentRole, text: String)] = []
        var currentRole: CLIAgentRole?
        var buffer: [String] = []

        func flush() {
            guard let role = currentRole else { return }
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                turns.append((role, text))
            }
            buffer.removeAll()
        }

        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "## you" || normalized == "# you" || normalized == "user:" || normalized == "## user" {
                flush()
                currentRole = .user
            } else if normalized == "## assistant" || normalized == "# assistant" || normalized == "assistant:" {
                flush()
                currentRole = .assistant
            } else if currentRole != nil {
                buffer.append(line)
            }
        }
        flush()
        return turns
    }

    static func convert(_ message: ChatMessageRecord) -> CLIAgentMessage {
        let role: CLIAgentRole
        switch message.role {
        case .user:      role = .user
        case .assistant: role = .assistant
        case .system:    role = .system
        }
        let pieces = message.transcriptPieces.isEmpty
            ? [ChatTranscriptPiece(id: "\(message.id)-legacy", kind: .text, value: message.content, detail: nil)]
            : message.transcriptPieces
        // Convert text pieces into the joined body and tool pieces
        // into structured `CLIAgentToolUse` entries. Streaming order is
        // preserved by the per-piece `id` prefix.
        var bodyParts: [String] = []
        var toolUses: [CLIAgentToolUse] = []
        for piece in pieces {
            switch piece.kind {
            case .text:
                if !piece.value.isEmpty {
                    bodyParts.append(piece.value)
                }
            case .toolUse, .toolResult:
                toolUses.append(
                    CLIAgentToolUse(
                        id: piece.id,
                        name: piece.value,
                        status: piece.kind == .toolResult ? "completed" : "done",
                        detail: piece.detail,
                        startedAt: message.timestamp
                    )
                )
            }
        }
        return CLIAgentMessage(
            id: message.id,
            role: role,
            text: bodyParts.joined(),
            timestamp: message.timestamp,
            isError: false,
            toolUses: toolUses
        )
    }

    static func derivedTitle(messages: [ChatMessageRecord]) -> String {
        let firstUser = messages.first(where: { $0.role == .user })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstUser, !firstUser.isEmpty {
            return String(firstUser.prefix(64))
        }
        return "CLI session"
    }

    static func derivedPreview(messages: [ChatMessageRecord]) -> String {
        let lastNonEmpty = messages
            .reversed()
            .first(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastNonEmpty, !lastNonEmpty.isEmpty {
            return String(lastNonEmpty.prefix(160))
        }
        return ""
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
