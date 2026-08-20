import Foundation
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(AppKit)
import AppKit
#endif

@MainActor
extension ChatSessionController {
    func handleTextExpansionDraftChange() {
        textExpansionLookupTask?.cancel()
        guard settingsManager.textExpansion.inAppExpansionEnabled else { return }
        if let suppressedTextExpansionDraft, suppressedTextExpansionDraft == inputText {
            self.suppressedTextExpansionDraft = nil
            return
        }

        if let pendingTextExpansionPreview, !inputText.contains(pendingTextExpansionPreview.token) {
            cancelTextExpansionPreview()
        }

        let inputSnapshot = inputText
        let threadSnapshot = activeThreadID
        textExpansionLookupTask = Task { @MainActor [weak self] in
            await self?.handleTextExpansionDraftChange(inputSnapshot: inputSnapshot, threadID: threadSnapshot)
        }
    }

    private func handleTextExpansionDraftChange(inputSnapshot: String, threadID: String) async {
        let snippets: [TextExpansionSnippet]
        do {
            snippets = try await dataStore.fetchEnabledTextExpansionSnippets(
                surface: .inAppThread,
                threadID: threadID
            )
        } catch {
            guard !Task.isCancelled,
                  inputText == inputSnapshot,
                  activeThreadID == threadID else {
                return
            }
            textExpansionStatusMessage = "Text expansion unavailable: \(error.localizedDescription)"
            return
        }

        guard !Task.isCancelled,
              inputText == inputSnapshot,
              activeThreadID == threadID else {
            return
        }

        guard let match = TextExpansionMatcher.match(
            in: inputSnapshot,
            snippets: snippets,
            surface: .inAppThread,
            threadID: threadID
        ) else {
            return
        }

        if match.requiresPreview {
            guard settingsManager.textExpansion.llmRewritePreviewEnabled else { return }
            if pendingTextExpansionPreview?.snippetID == match.snippet.id,
               pendingTextExpansionPreview?.token == match.token {
                return
            }
            beginTextExpansionPreview(snippet: match.snippet, token: match.token)
        } else {
            let expanded = TextExpansionMatcher.replacingMatch(in: inputSnapshot, match: match)
            suppressedTextExpansionDraft = expanded
            inputText = expanded
            textExpansionStatusMessage = "Expanded \(match.token)"
        }
    }

    func insertPendingTextExpansionPreview() {
        guard let preview = pendingTextExpansionPreview,
              !preview.generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tokenRange = inputText.range(of: preview.token, options: .backwards) else {
            return
        }
        var copy = inputText
        copy.replaceSubrange(tokenRange, with: preview.generatedText)
        suppressedTextExpansionDraft = copy
        inputText = copy
        pendingTextExpansionPreview = nil
        textExpansionPreviewTask?.cancel()
        textExpansionPreviewTask = nil
        textExpansionStatusMessage = "Inserted \(preview.token)"
    }

    func cancelTextExpansionPreview() {
        pendingTextExpansionPreview = nil
        textExpansionPreviewTask?.cancel()
        textExpansionPreviewTask = nil
    }

    func beginTextExpansionPreview(snippet: TextExpansionSnippet, token: String) {
        textExpansionPreviewTask?.cancel()
        pendingTextExpansionPreview = ChatTextExpansionPreviewState(
            snippetID: snippet.id,
            title: snippet.title,
            token: token
        )
        textExpansionPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await self.rewriteTextExpansionSnippet(snippet)
                guard !Task.isCancelled else { return }
                self.pendingTextExpansionPreview = ChatTextExpansionPreviewState(
                    snippetID: snippet.id,
                    title: snippet.title,
                    token: token,
                    generatedText: generated,
                    isLoading: false
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.pendingTextExpansionPreview = ChatTextExpansionPreviewState(
                    snippetID: snippet.id,
                    title: snippet.title,
                    token: token,
                    isLoading: false,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    func rewriteTextExpansionSnippet(_ snippet: TextExpansionSnippet) async throws -> String {
        let context = TextExpansionContextPack(
            surface: .inAppThread,
            threadID: activeThreadID,
            title: historyThreads.first(where: { $0.id == activeThreadID })?.title,
            messages: messages.suffix(12).compactMap { message in
                guard message.role != .system else { return nil }
                return TextExpansionContextMessage(role: message.role.rawValue, content: message.content)
            },
            maxCharacters: 2_000
        )
        let system = TextExpansionPromptBuilder.buildSystemPrompt(maxCharacters: context.maxCharacters)
        let user = TextExpansionPromptBuilder.buildUserPrompt(snippetBody: snippet.body, context: context)
        let messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]

        let baseURL: URL
        let bearerToken: String?
        switch chatBackend {
        case .hermes:
            baseURL = hermesGatewayBaseURL
            bearerToken = hermesBearerToken
        case .openclaw:
            baseURL = URL(string: settingsManager.openClawGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? URL(string: "http://127.0.0.1:18789")!
            bearerToken = openClawBearerToken
        case .piAgent:
            baseURL = piAgentGatewayBaseURL
            bearerToken = piAgentBearerToken
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx:
            throw TextExpansionRewriteError.unsupportedBackend(chatBackend.displayName)
        }

        guard Self.allowsTextExpansionRewriteGateway(baseURL) else {
            throw TextExpansionRewriteError.nonLocalGatewayURL(chatBackend.displayName)
        }
        guard let url = URL(string: "v1/chat/completions", relativeTo: baseURL)?.absoluteURL else {
            throw TextExpansionRewriteError.invalidGatewayURL
        }
        let model = effectiveChatModel(for: chatBackend).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw TextExpansionRewriteError.missingModel }

        let (content, _) = try await OpenAICompatibleChatGatewayClient.nonStreamingFallback(
            url: url,
            messages: messages,
            model: model,
            session: URLSession(configuration: .default),
            bearerToken: bearerToken
        )
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextExpansionRewriteError.emptyResponse }
        return String(trimmed.prefix(context.maxCharacters))
    }
}
