import Foundation
import Observation
import OpenBurnBarCore

// MARK: - CLI Agent Mobile Chat Service
//
// The iOS-owned chat pipeline for CLI runtimes (Codex, Claude Code,
// OpenClaw, …): persists threads in `MobileChatHistoryStore`, streams
// replies through the Mac relay transport, and falls back to a queued
// mission when the relay can't take the turn. Moved out of
// `Views/CLIAgents/CLIAgentConversationListView.swift` (audit wave 4,
// item 15 — views must not own persistence/networking) into the Services
// layer; dependencies arrive via `init` (item 16).

enum CLIAgentChatRoute: Identifiable {
    case new(runtime: CLIAgentRuntime)
    case mobile(MobileChatThread)
    case existing(CLIAgentSessionRecord)
    case archived(CLIAgentSessionRecord)

    var id: String {
        switch self {
        case let .new(runtime): return "new-\(runtime.rawValue)"
        case let .mobile(thread): return "mobile-\(thread.id)"
        case let .existing(session): return "existing-\(session.id)"
        case let .archived(session): return "archived-\(session.id)"
        }
    }

    var title: String {
        switch self {
        case let .new(runtime): return "New \(runtime.displayName) Chat"
        case let .mobile(thread): return thread.title
        case let .existing(session), let .archived(session): return session.title
        }
    }

    var isNew: Bool {
        if case .new = self { return true }
        return false
    }
}

@MainActor
@Observable
final class CLIAgentMobileChatService {
    private(set) var threadID: String
    private(set) var streamingMessageID: String?
    private(set) var isSending = false
    private(set) var errorMessage: String?

    private let runtime: CLIAgentRuntime
    private let historyStore: MobileChatHistoryStore
    private let relayChatTransport: CLIAgentRelayChatTransporting
    private let parentSessionID: String?
    private let resumeAction: String
    private var observation: CLIAgentMissionObservation?

    init(
        runtime: CLIAgentRuntime,
        route: CLIAgentChatRoute,
        historyStore: MobileChatHistoryStore,
        relayChatTransport: CLIAgentRelayChatTransporting = CLIAgentRelayChatTransport.shared
    ) {
        self.runtime = runtime
        self.historyStore = historyStore
        self.relayChatTransport = relayChatTransport
        switch route {
        case .new:
            self.threadID = "mobile-\(runtime.rawValue)-\(UUID().uuidString)"
            self.parentSessionID = nil
            self.resumeAction = "new"
        case let .mobile(thread):
            self.threadID = thread.id
            self.parentSessionID = nil
            self.resumeAction = "continue"
        case let .existing(session):
            self.threadID = session.id
            self.parentSessionID = session.id
            self.resumeAction = "continue"
            seedThread(from: session, id: session.id)
        case let .archived(session):
            self.threadID = "mobile-\(runtime.rawValue)-\(UUID().uuidString)"
            self.parentSessionID = session.id
            self.resumeAction = session.resumeHandle?.canResume == true ? "resume" : "forward"
            seedThread(from: session, id: threadID)
        }
    }

    func startNewThread() {
        observation?.cancel()
        observation = nil
        threadID = "mobile-\(runtime.rawValue)-\(UUID().uuidString)"
        streamingMessageID = nil
        isSending = false
        errorMessage = nil
    }

    func send(message: String, presentationMode: CLIAgentChatPresentationMode = .nativeChat) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        observation?.cancel()

        let now = Date()
        let userMessage = MobileChatMessage(
            role: "user",
            text: trimmed,
            timestamp: now
        )
        let assistantPlaceholder = MobileChatMessage(
            role: "assistant",
            text: "",
            timestamp: now.addingTimeInterval(0.001)
        )
        streamingMessageID = assistantPlaceholder.id
        upsertThreadAppending(userMessage: userMessage, assistantPlaceholder: assistantPlaceholder)

        guard presentationMode == .nativeChat else {
            await dispatchMissionFallback(
                prompt: trimmed,
                placeholderID: assistantPlaceholder.id,
                relayError: nil,
                presentationMode: presentationMode
            )
            return
        }

        do {
            try await relayChatTransport.stream(
                runtime: runtime,
                threadID: threadID,
                prompt: trimmed,
                title: currentThreadTitle(),
                parentSessionID: parentSessionID,
                resumeAction: resumeAction,
                presentationMode: presentationMode,
                onEvent: { [weak self] event in
                    self?.apply(event, placeholderID: assistantPlaceholder.id)
                }
            )
            if isSending {
                isSending = false
                streamingMessageID = nil
            }
        } catch {
            guard shouldFallBackToMission(afterRelayError: error) else {
                finalizePlaceholder(
                    assistantPlaceholder.id,
                    text: "Could not reach \(runtime.displayName) on your Mac: \(error.localizedDescription)",
                    isError: true,
                    modelName: nil,
                    toolCalls: []
                )
                errorMessage = error.localizedDescription
                isSending = false
                return
            }
            await dispatchMissionFallback(
                prompt: trimmed,
                placeholderID: assistantPlaceholder.id,
                relayError: error,
                presentationMode: presentationMode
            )
        }
    }

    private func dispatchMissionFallback(
        prompt: String,
        placeholderID: String,
        relayError: Error?,
        presentationMode: CLIAgentChatPresentationMode
    ) async {
        // Forward any live desktop grant for this thread (matching Android's
        // optimistic-grant forwarding) so Mac-side capability gates — e.g.
        // Junie's full-desktop requirement — see what the user actually
        // approved instead of a hard-coded read-only payload.
        let optimisticGrant = MobileAgentPermissionGrantController.shared.optimisticGrant(
            runtimeID: runtime.assistantRuntime,
            threadID: threadID
        )
        let commandsAllowed = optimisticGrant.map {
            $0.capabilities.contains(.shell) || $0.capabilities.contains(.shellUnrestricted)
        } ?? false
        let fileEditsAllowed = optimisticGrant?.capabilities.contains(.workspaceWrite) ?? false
        do {
            let requestID = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: currentThreadTitle(),
                prompt: prompt,
                missionKind: "chat",
                requestedRuntime: runtime.rawValue,
                depth: "standard",
                approvalMode: "existing_policy",
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                clientThreadID: threadID,
                parentSessionID: parentSessionID,
                resumeAction: resumeAction,
                sourceSurface: presentationMode.iosSourceSurface,
                deliveryMode: presentationMode.mobileDeliveryMode,
                presentationMode: presentationMode
            )
            observation = try CLIAgentMissionDispatcher.shared.observe(
                requestID: requestID,
                onUpdate: { [weak self] snapshot in
                    self?.apply(snapshot, placeholderID: placeholderID)
                },
                onError: { [weak self] message in
                    guard let self else { return }
                    self.finalizePlaceholder(
                        placeholderID,
                        text: "Could not watch \(self.runtime.displayName) response: \(message)",
                        isError: true,
                        modelName: nil,
                        toolCalls: []
                    )
                    self.errorMessage = message
                    self.isSending = false
                    self.streamingMessageID = nil
                    self.observation?.cancel()
                    self.observation = nil
                }
            )
        } catch {
            finalizePlaceholder(
                placeholderID,
                text: "Could not reach \(runtime.displayName) on your Mac: \(error.localizedDescription)",
                isError: true,
                modelName: nil,
                toolCalls: []
            )
            errorMessage = relayError?.localizedDescription ?? error.localizedDescription
            isSending = false
        }
    }

    private func shouldFallBackToMission(afterRelayError error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("already responding")
            || lower.contains("unsupported runtime")
            || lower.contains("cannot send an empty") {
            return false
        }
        return true
    }

    func isStreamingMessage(_ id: String) -> Bool {
        isSending && streamingMessageID == id
    }

    private func seedThread(from session: CLIAgentSessionRecord, id: String) {
        guard historyStore.thread(id: id) == nil else { return }
        let messages = session.messages.map { message in
            MobileChatMessage(
                id: message.id,
                role: message.role.rawValue,
                text: message.text,
                timestamp: message.timestamp,
                modelName: session.modelName,
                isError: message.isError,
                toolCalls: message.toolUses.map(Self.mobileToolCall(from:))
            )
        }
        let thread = MobileChatThread(
            id: id,
            runtime: runtime.assistantRuntime.rawValue,
            title: session.title,
            preview: session.preview,
            modelName: session.modelName,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            messages: messages
        )
        historyStore.upsert(thread)
    }

    private func upsertThreadAppending(userMessage: MobileChatMessage, assistantPlaceholder: MobileChatMessage) {
        var thread = historyStore.thread(id: threadID) ?? MobileChatThread(
            id: threadID,
            runtime: runtime.assistantRuntime.rawValue,
            title: "New \(runtime.displayName) chat",
            preview: "",
            modelName: nil,
            createdAt: Date(),
            updatedAt: Date(),
            messages: []
        )
        thread.messages.append(userMessage)
        thread.messages.append(assistantPlaceholder)
        thread.title = Self.derivedTitle(from: thread.messages, fallback: "New \(runtime.displayName) chat")
        thread.preview = Self.derivedPreview(from: thread.messages)
        historyStore.upsert(thread)
    }

    private func currentThreadTitle() -> String {
        historyStore.thread(id: threadID)?.title ?? "New \(runtime.displayName) chat"
    }

    private func apply(_ snapshot: CLIAgentMissionSnapshot, placeholderID: String) {
        let text = CLIAgentMobileChatSnapshotReducer.visibleAssistantText(for: snapshot)
        let toolCalls = CLIAgentMobileChatSnapshotReducer.toolCalls(for: snapshot)
        if let text {
            finalizePlaceholder(
                placeholderID,
                text: text,
                isError: CLIAgentMobileChatSnapshotReducer.isError(snapshot),
                modelName: snapshot.selectedModelID ?? snapshot.requestedModelID ?? snapshot.runtimeLabel,
                toolCalls: toolCalls,
                keepStreaming: !snapshot.isTerminal
            )
        } else if !toolCalls.isEmpty {
            finalizePlaceholder(
                placeholderID,
                text: "",
                isError: false,
                modelName: snapshot.selectedModelID ?? snapshot.requestedModelID ?? snapshot.runtimeLabel,
                toolCalls: toolCalls,
                keepStreaming: !snapshot.isTerminal
            )
        }

        if snapshot.isTerminal {
            if text == nil {
                finalizePlaceholder(
                    placeholderID,
                    text: "\(snapshot.runtimeLabel) finished without a visible reply.",
                    isError: CLIAgentMobileChatSnapshotReducer.isError(snapshot),
                    modelName: snapshot.selectedModelID ?? snapshot.requestedModelID ?? snapshot.runtimeLabel,
                    toolCalls: []
                )
            }
            isSending = false
            streamingMessageID = nil
            observation?.cancel()
            observation = nil
        }
    }

    private func apply(_ event: CLIAgentRelayChatEvent, placeholderID: String) {
        let relayText = event.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let errorText = event.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let visibleText = relayText ?? errorText.map { "Error: \($0)" } ?? ""
        finalizePlaceholder(
            placeholderID,
            text: visibleText,
            isError: event.isError,
            modelName: event.modelID,
            toolCalls: Self.mobileToolCalls(from: event.transcriptPieces),
            keepStreaming: !event.isTerminal
        )
        if event.isTerminal {
            isSending = false
            streamingMessageID = nil
            observation?.cancel()
            observation = nil
        }
    }

    private func finalizePlaceholder(
        _ placeholderID: String,
        text: String,
        isError: Bool,
        modelName: String?,
        toolCalls: [MobileChatToolCall],
        keepStreaming: Bool = false
    ) {
        guard var thread = historyStore.thread(id: threadID),
              let idx = thread.messages.firstIndex(where: { $0.id == placeholderID })
        else { return }
        var message = thread.messages[idx]
        message.text = text
        message.isError = isError
        message.modelName = modelName
        message.toolCalls = toolCalls
        thread.messages[idx] = message
        thread.modelName = modelName ?? thread.modelName
        thread.preview = Self.derivedPreview(from: thread.messages)
        historyStore.upsert(thread)
        if !keepStreaming {
            streamingMessageID = nil
        }
    }

    private static func mobileToolCall(from tool: CLIAgentToolUse) -> MobileChatToolCall {
        MobileChatToolCall(
            id: tool.id,
            name: tool.name,
            status: tool.status,
            detail: tool.detail
        )
    }

    private static func mobileToolCalls(from pieces: [CLIAgentRelayTranscriptPiece]) -> [MobileChatToolCall] {
        pieces.compactMap { piece in
            switch piece.kind {
            case .text, .reasoning, .refusal:
                return nil
            case .toolUse:
                return MobileChatToolCall(
                    id: piece.id,
                    name: piece.value,
                    status: "running",
                    detail: piece.detail
                )
            case .toolResult:
                return MobileChatToolCall(
                    id: piece.id,
                    name: piece.value,
                    status: "done",
                    detail: piece.detail
                )
            }
        }
    }

    private static func derivedTitle(from messages: [MobileChatMessage], fallback: String) -> String {
        if let first = messages.first(where: { $0.role == "user" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return String(first.prefix(64))
        }
        return fallback
    }

    private static func derivedPreview(from messages: [MobileChatMessage]) -> String {
        if let latest = messages.reversed().first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            // List rows are plain text — flatten assistant markdown so
            // previews never show raw `**` / `#` markers.
            let plain = HermesAtomParser.plainText(latest)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(plain.prefix(140))
        }
        return ""
    }
}

enum CLIAgentMobileChatSnapshotReducer {
    static func visibleAssistantText(for snapshot: CLIAgentMissionSnapshot) -> String? {
        let status = snapshot.status.lowercased()
        if snapshot.isTerminal {
            if let error = snapshot.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return "Error: \(error)"
            }
            if let assistant = latestAssistantText(from: snapshot) {
                return assistant
            }
            if let result = snapshot.resultPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return result
            }
            if status == "completed" {
                return "\(snapshot.runtimeLabel) finished without a visible reply."
            }
            return snapshot.displayLiveSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        if let assistant = latestAssistantText(from: snapshot) {
            return assistant
        }
        guard snapshot.hasBeenClaimedByMac else { return nil }
        return snapshot.displayLiveSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func isError(_ snapshot: CLIAgentMissionSnapshot) -> Bool {
        ["failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed"].contains(snapshot.status.lowercased())
            || snapshot.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func toolCalls(for snapshot: CLIAgentMissionSnapshot) -> [MobileChatToolCall] {
        snapshot.events.compactMap { event in
            guard event.kind == "tool_call"
                    || event.kind == "tool_result"
                    || event.phase == "tool_use"
                    || event.phase == "tool_result"
            else { return nil }
            let name = event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.phase.replacingOccurrences(of: "_", with: " ").capitalized
            let status = (event.kind == "tool_result" || event.phase == "tool_result") ? "done" : "running"
            let detail = event.fullMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return MobileChatToolCall(
                id: "mission-\(snapshot.id)-\(event.sequence)",
                name: name,
                status: status,
                detail: detail
            )
        }
    }

    private static func latestAssistantText(from snapshot: CLIAgentMissionSnapshot) -> String? {
        snapshot.events.reversed().first { event in
            event.kind == "llm_response"
                || event.kind == "final_answer"
                || event.phase == "assistant_response"
                || event.phase == "completed"
        }.flatMap { event in
            event.fullMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }
}

// MARK: - Presentation-mode routing metadata

private extension CLIAgentChatPresentationMode {
    var iosSourceSurface: String {
        switch self {
        case .nativeChat: return "ios-chat-native"
        case .macVisibleCLI: return "ios-chat-mac-visible-cli"
        case .macInteractiveCLI: return "ios-chat-mac-interactive-cli"
        }
    }

    var mobileDeliveryMode: SkillRunDeliveryMode {
        switch self {
        case .nativeChat: return .actionOnly
        case .macVisibleCLI: return .fullStream
        case .macInteractiveCLI: return .fullStream
        }
    }
}

// MARK: - Presentation-mode preference (per-runtime)

/// UserDefaults-backed per-runtime chat presentation mode. Lives with the
/// chat service so the view layer never touches persistence directly.
enum CLIAgentPresentationModePreferences {
    private static func key(for runtime: CLIAgentRuntime) -> String {
        "openburnbar.cliAgent.presentationMode.\(runtime.rawValue)"
    }

    static func mode(for runtime: CLIAgentRuntime) -> CLIAgentChatPresentationMode {
        let raw = UserDefaults.standard.string(forKey: key(for: runtime))
        return raw.flatMap(CLIAgentChatPresentationMode.init(rawValue:)) ?? .nativeChat
    }

    static func set(_ mode: CLIAgentChatPresentationMode, for runtime: CLIAgentRuntime) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(for: runtime))
    }
}

