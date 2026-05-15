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
