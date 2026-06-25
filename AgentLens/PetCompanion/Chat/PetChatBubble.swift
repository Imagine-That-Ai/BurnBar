import AppKit
import Combine
import SwiftUI
import OpenBurnBarCore

// MARK: - PetChatController

/// The conversational brain bridge for the pet bubble (PLAN C5/C7). It owns the
/// click-to-chat lifecycle and drives the pet's logical-state choreography
/// (`listen → think → speak → react`) off the **existing** agent layer — it does
/// NOT build new providers.
///
/// Reuse contract (Ground Truth #2): a single shared ``ChatSessionController``
/// (the app's already-instantiated instance) is the transport. The bubble sets
/// `inputText` and calls `await send()`, observes `messages` + `isStreaming` for
/// streamed tokens, and switches brains with `setChatBackend(_:)`. The active
/// ``ChatBackendID`` is persisted by that controller (UserDefaults
/// `"chatBackendID"`) — we add a thin `@AppStorage("pet.activeAgent")` mirror so
/// the bubble's own picker restores across launches even before the panel opens.
///
/// When the active backend throws / is offline, ``PetChatFallback`` answers
/// locally with a visible "answering locally" beat (`react`), so chat never
/// dead-ends (PLAN C6).
///
/// `@MainActor @Observable`: it mutates AppKit panel geometry and SwiftUI state.
@MainActor
@Observable
final class PetChatController {

    // MARK: Observable surface (bound by the bubble view)

    /// Whether the bubble is open (pet was clicked).
    private(set) var isOpen = false
    /// The text the user is typing into the bubble.
    var draft = ""
    /// The reply currently rendering in the bubble (streamed text).
    private(set) var replyText = ""
    /// True while a stream (cloud or local floor) is in flight.
    private(set) var isAnswering = false
    /// True when the *local* floor is answering (drives the "answering locally"
    /// banner + `react` beat).
    private(set) var isAnsweringLocally = false
    /// The brain that produced / is producing the current reply.
    private(set) var activeBackend: ChatBackendID
    /// The set of brains the user can switch between (Settings-enabled order).
    private(set) var availableBackends: [ChatBackendID] = ChatBackendID.allCases
    /// Last error surfaced from the agent layer (nil when healthy or recovered).
    private(set) var lastErrorNote: String?

    // MARK: Collaborators

    /// The shared transport. Reused, never duplicated (Ground Truth #2).
    private let chat: ChatSessionController
    /// The pet coordinator we drive states on.
    private weak var pet: PetCompanionController?

    /// The chosen pet's human name (e.g. "Sam Altman") for chat chrome — so the
    /// input says "Ask Sam Altman…" instead of the impersonal "Ask the pet…".
    var petName: String { pet?.displayName ?? "your companion" }
    /// The app's shared settings — the *same* ``SettingsManager`` the main chat
    /// UI reads the enabled-engine set from (its `enabledChatBackendIDsCSV` key,
    /// decoded via `enabledChatBackends`). We reuse that property so the bubble's
    /// switcher honours the user's Settings choice without a second copy of the
    /// setting (Ground Truth #2).
    @ObservationIgnored
    private let settings: SettingsManager

    /// Persisted brain selection mirror (survives even before the bubble opens;
    /// the same UserDefaults key PLAN C7's `@AppStorage("pet.activeAgent")` uses,
    /// accessed directly here since `@AppStorage` is a SwiftUI-View property
    /// wrapper and this is a plain `@Observable` model). The `PetCompanionToggleButton`
    /// view can still bind the same key with `@AppStorage` and stay in sync.
    @ObservationIgnored
    private var persistedAgentRaw: String {
        get { UserDefaults.standard.string(forKey: PetCompanionFeature.DefaultsKey.activeAgent)
                ?? ChatBackendID.codex.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: PetCompanionFeature.DefaultsKey.activeAgent) }
    }

    /// Observation of the shared controller's streaming output.
    @ObservationIgnored private var streamObserver: Task<Void, Never>?
    /// Set when the shared send call returns before the observer sees a stream.
    @ObservationIgnored private var sendAttemptCompleted = false
    /// The local-floor stream task (cancelled on close / backend switch).
    @ObservationIgnored private var floorTask: Task<Void, Never>?
    /// True only while this bubble owns the shared chat stream it started.
    @ObservationIgnored private var ownsSharedStream = false
    /// Called when the bubble chrome requests closure, so the owning panel hides
    /// as well as the controller state closing.
    @ObservationIgnored private let onCloseRequested: () -> Void

    init(chat: ChatSessionController,
         pet: PetCompanionController,
         settings: SettingsManager = .shared,
         onCloseRequested: @escaping () -> Void = {}) {
        self.chat = chat
        self.pet = pet
        self.settings = settings
        self.onCloseRequested = onCloseRequested
        // Restore the persisted brain, preferring the shared controller's own
        // persisted value (its UserDefaults["chatBackendID"]) so we never fight it.
        self.activeBackend = chat.chatBackend
        if let restored = ChatBackendID(rawValue: persistedAgentRaw), restored != chat.chatBackend {
            // Bubble's mirror and the shared controller diverged (e.g. main chat
            // window changed it) — trust the shared controller as source of truth.
            persistedAgentRaw = chat.chatBackend.rawValue
        }
        refreshAvailableBackends()
    }

    // MARK: Open / close (pet click)

    /// Open the bubble in response to a pet click. Perks the pet to `listen` and
    /// focuses input. Idempotent.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        lastErrorNote = nil
        refreshAvailableBackends()
        pet?.recordUserTyping()
        pet?.fire(.inputFocused)        // graph-driven listen, if the petdef wires it
        pet?.drive(to: .listen)         // …and force the listen pose regardless
    }

    /// Close the bubble, cancel any in-flight stream, and settle the pet to idle.
    func close() {
        guard isOpen else { return }
        isOpen = false
        cancelInFlight()
        draft = ""
        replyText = ""
        isAnswering = false
        isAnsweringLocally = false
        pet?.noteAgentBusy(false)
        pet?.drive(to: .idle)
    }

    func requestClose() {
        onCloseRequested()
    }

    func toggle() {
        if isOpen {
            requestClose()
        } else {
            open()
        }
    }

    // MARK: Attachments (file drag-and-drop onto the pet)

    /// Passthrough to the shared controller's staged attachments so the bubble's
    /// attachment tray can observe the single source of truth (a drop at the pet
    /// and a drop at any chat composer both stage here).
    var pendingAttachments: [HermesAttachment] { chat.pendingAttachments }
    /// Passthrough to the shared controller's import error so the tray surfaces
    /// the same "too large" / "unreadable" message the composer does.
    var attachmentError: String? { chat.attachmentError }

    /// Stage a dropped file URL onto the shared chat controller. Reuses the
    /// existing ``ChatSessionController/addAttachment(from:)`` seam (which routes
    /// through ``HermesAttachmentLoader``, enforces per-kind size caps, copies
    /// into the per-thread workspace, and makes a thumbnail) so a drop at the
    /// pet is byte-identical to a drop at the chat composer.
    func stageAttachment(from url: URL) {
        chat.addAttachment(from: url)
    }

    /// Stage a dropped in-memory image onto the shared chat controller. Reuses
    /// ``ChatSessionController/addAttachment(image:suggestedName:)`` (which
    /// writes a PNG into the workspace + sizes it).
    func stageAttachment(image: NSImage, suggestedName: String?) {
        chat.addAttachment(image: image, suggestedName: suggestedName)
    }

    /// Remove a staged attachment by id (the bubble tray's remove button).
    func removeAttachment(_ id: String) {
        chat.removeAttachment(id)
    }

    /// Reveal a staged attachment's workspace file in Finder (the bubble tray's
    /// "Reveal in Finder" context action). Mirrors ``ChatInputRow``'s reveal.
    func revealAttachment(_ attachment: HermesAttachment) {
        let url = chat.chatWorkspaceURL.appendingPathComponent(attachment.workspaceRelativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([chat.chatWorkspaceURL])
        }
    }

    // MARK: Send

    /// Send the current draft through the active brain. Drives
    /// `think → speak`, mirrors streamed tokens into ``replyText``, and on any
    /// agent error transparently falls through to ``PetChatFallback`` with a
    /// visible `react` beat (PLAN C6).
    func send() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }

        lastErrorNote = nil
        replyText = ""
        isAnswering = true
        isAnsweringLocally = false

        pet?.fire(.sendPressed)
        let intent = pet?.recordUserMessage(trimmed) ?? .neutral
        if intent == .neutral || intent == .question {
            pet?.drive(to: .think)
        }

        let history = currentHistory(appendingUser: trimmed)
        let ignoredAssistantIDs = Set(chat.messages.filter { $0.role == .assistant }.map(\.id))
        let previousInput = chat.inputText

        guard !chat.isSendBusy else {
            draft = ""
            await answerLocally(
                history: history,
                note: "A chat response is already in progress. Answering locally instead."
            )
            return
        }

        // Hand the draft to the shared controller exactly as the main chat does,
        // adding the active pet's `agent.persona` as wrapped style context. A pet
        // without a persona leaves the prompt untouched (PetChatProviders is the
        // onboarding-only floor; the live bubble's default is the shared core).
        chat.personaCoreOverride = pet?.activeChatPersona
        chat.inputText = trimmed
        draft = ""
        ownsSharedStream = true

        // The mirroring observer owns the whole lifecycle from here: it streams
        // tokens into the bubble on success, and on an agent error (no CLI,
        // gateway down, consent denied, mid-stream throw) it transparently routes
        // to the local floor with the visible "answering locally" beat. It reads
        // `history` for the floor, so capture it on the controller for the observer.
        pendingFallbackHistory = history
        beginMirroringStream(ignoringAssistantIDs: ignoredAssistantIDs)
        await chat.send()
        // `send()` assembles + captures the system prompt synchronously before it
        // returns, so the override is already baked into this turn. Clear it now
        // so an unrelated main-chat send through the shared controller is not
        // styled with the pet's persona.
        chat.personaCoreOverride = nil
        sendAttemptCompleted = true
        if chat.inputText.isEmpty, !previousInput.isEmpty {
            chat.inputText = previousInput
        }
    }

    /// Snapshot of the conversation (incl. the just-sent user turn) the observer
    /// hands to the local floor if the cloud path errors before any token.
    @ObservationIgnored private var pendingFallbackHistory: [PetChatFallback.Turn] = []

    // MARK: Stream mirroring (cloud path)

    /// Begin observing the shared controller's `messages`/`isStreaming` and
    /// mirror the in-flight assistant message into ``replyText``. Drives `speak`
    /// on first token and `react` when the result lands.
    private func beginMirroringStream(ignoringAssistantIDs ignoredAssistantIDs: Set<String>) {
        streamObserver?.cancel()
        sendAttemptCompleted = false
        var sawText = false
        var sawStreamActivity = false
        var sawNewAssistant = false

        streamObserver = Task { [weak self] in
            guard let self else { return }
            // Poll the @Observable controller at a light cadence; cheaper and
            // simpler than threading a Combine publisher out of an @Observable.
            while !Task.isCancelled {
                let streaming = self.chat.isStreaming
                if streaming || self.chat.activeStreamMessageId != nil {
                    sawStreamActivity = true
                }

                if let assistant = self.latestAssistant(excluding: ignoredAssistantIDs) {
                    sawNewAssistant = true
                    let text = Self.renderedText(of: assistant)
                    if !text.isEmpty {
                        if !sawStreamActivity, !streaming, self.chat.activeStreamMessageId == nil {
                            if Self.shouldUseLocalFallback(forNonStreamingAssistantText: text) {
                                await self.answerLocally(history: self.pendingFallbackHistory, note: text)
                                break
                            }
                            sawText = true
                            self.replyText = text
                            self.pet?.fire(.streamStart)
                            self.finishCloudReply()
                            break
                        }
                        if !sawText {
                            sawText = true
                            self.pet?.fire(.streamStart)
                        } else {
                            self.pet?.fire(.streamToken)
                        }
                        self.replyText = text
                    }
                }

                if !streaming && self.chat.activeStreamMessageId == nil {
                    guard sawStreamActivity || sawNewAssistant else {
                        if self.sendAttemptCompleted {
                            await self.answerLocally(history: self.pendingFallbackHistory,
                                                     note: nil)
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(60))
                        continue
                    }
                    // Stream finished (or never started). Decide success vs floor.
                    if let err = self.chat.streamError, !sawText {
                        await self.answerLocally(history: self.pendingFallbackHistory, note: err)
                    } else if sawText {
                        self.finishCloudReply()
                    } else {
                        // No tokens and no error surfaced (e.g. backend silently
                        // produced nothing): still answer locally so the bubble is
                        // never a dead-end (PLAN C6).
                        await self.answerLocally(history: self.pendingFallbackHistory,
                                                 note: nil)
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func finishCloudReply() {
        ownsSharedStream = false
        isAnswering = false
        isAnsweringLocally = false
        pet?.fire(.resultLanded)
        pet?.recordTaskOutcome(.normalReply)
        settleToIdleSoon()
    }

    // MARK: Local floor (PLAN C6)

    /// Answer from the deterministic local persona, streaming word-by-word with a
    /// visible "answering locally" beat. Used when the active brain throws/offline.
    private func answerLocally(history: [PetChatFallback.Turn], note: String?) async {
        // Cancel any cloud mirroring; we own the bubble now.
        streamObserver?.cancel()
        floorTask?.cancel()
        ownsSharedStream = false

        lastErrorNote = note
        isAnswering = true
        isAnsweringLocally = true
        replyText = ""

        // The legible "I'm answering locally" beat: alert/react, then speak.
        pet?.fire(.fallbackFired)
        pet?.recordTaskOutcome(.failure)
        try? await Task.sleep(for: .milliseconds(420))
        pet?.noteAgentBusy(true)
        pet?.drive(to: .speak)

        let stream = PetChatFallback.stream(history: history, lines: pet?.voiceLines)
        floorTask = Task { [weak self] in
            for await tok in stream {
                guard let self, !Task.isCancelled else { break }
                self.replyText += tok
            }
            guard let self, !Task.isCancelled else { return }
            self.isAnswering = false
            self.isAnsweringLocally = false
            self.pet?.recordTaskOutcome(.normalReply)
            self.settleToIdleSoon()
        }
    }

    // MARK: Backend switch (PLAN C7 — reuse ChatBackendID switcher)

    /// Switch the answering brain mid-session. Cancels any in-flight stream
    /// (cloud or floor) and replays the conversation to the next backend by
    /// re-sending the last user turn through it, so the new brain has context
    /// (PLAN C7 "mid-reply switch cancels the stream and replays history").
    func switchBackend(to backend: ChatBackendID) {
        guard backend != activeBackend else { return }
        Task { @MainActor in
            await switchBackendAndReplay(to: backend)
        }
    }

    func userDidType() {
        guard isOpen, !draft.isEmpty else { return }
        pet?.recordUserTyping()
    }

    private func switchBackendAndReplay(to backend: ChatBackendID) async {
        guard backend != activeBackend else { return }

        let wasAnswering = isAnswering
        let lastUser = lastUserText()

        cancelInFlight()

        // Reuse the existing switcher: it cancels the stream, swaps the per-backend
        // thread, reloads messages, and persists to UserDefaults["chatBackendID"].
        await chat.setChatBackendAsync(backend)
        activeBackend = backend
        persistedAgentRaw = backend.rawValue

        replyText = ""
        isAnswering = false
        isAnsweringLocally = false
        pet?.drive(to: .listen)

        // Replay: if we were mid-reply, resend the last user turn to the new brain
        // so the switch produces a fresh answer rather than a dead bubble.
        if wasAnswering, let lastUser, !lastUser.isEmpty {
            draft = lastUser
            await send()
        }
    }

    /// Pull the Settings-enabled brain list (CSV in SettingsManager), falling back
    /// to all cases when the setting is absent (Ground Truth #2 enabled-engine set).
    func refreshAvailableBackends() {
        // Reuse the exact property the main chat header reads: `enabledChatBackends`
        // decodes `SettingsManager.enabledChatBackendIDsCSV` and preserves the
        // user's picker order. Only those brains appear in the switcher; an absent
        // setting (empty list) falls back to every backend so it is never empty.
        availableBackends = Self.resolveAvailableBackends(enabled: settings.enabledChatBackends)
    }

    /// Resolve the brains the switcher offers from the Settings-enabled list: use
    /// it verbatim (Settings order) when non-empty, else fall back to every
    /// backend. Pure so the offer/fallback rule is unit-testable in isolation.
    static func resolveAvailableBackends(enabled: [ChatBackendID]) -> [ChatBackendID] {
        enabled.isEmpty ? ChatBackendID.allCases : enabled
    }

    // MARK: Helpers

    private func cancelInFlight() {
        streamObserver?.cancel(); streamObserver = nil
        floorTask?.cancel(); floorTask = nil
        if ownsSharedStream {
            chat.cancelGeneration()
        }
        ownsSharedStream = false
    }

    /// Settle the pet back to idle a beat after a reply lands, so `react` is seen.
    private func settleToIdleSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard let self, !self.isAnswering, self.isOpen else { return }
            self.pet?.drive(to: .listen) // bubble still open → stay attentive
        }
    }

    private func latestAssistant(excluding ignoredIDs: Set<String> = []) -> ChatMessageRecord? {
        chat.messages.last { $0.role == .assistant && !ignoredIDs.contains($0.id) }
    }

    private func lastUserText() -> String? {
        chat.messages.last { $0.role == .user }?.content
    }

    /// Render an assistant record to display text, preferring interleaved
    /// transcript pieces (tool-use cards collapse to their text).
    private static func renderedText(of record: ChatMessageRecord) -> String {
        let pieces = record.displayTranscript.filter { $0.kind == .text }
        if !pieces.isEmpty { return pieces.map(\.value).joined() }
        return record.content
    }

    static func shouldUseLocalFallback(forNonStreamingAssistantText text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("Hermes isn’t running.")
            || normalized.hasPrefix("Hermes gateway is running, but OpenBurnBar could not read its live model catalog.")
            || normalized.hasPrefix("OpenClaw gateway is unavailable.")
            || normalized.hasPrefix("Pi agent gateway is unavailable.")
            || normalized.hasPrefix("Mac CLI assistants are off.")
            || normalized.hasPrefix("Droid CLI was not found.")
            || normalized.hasPrefix("Forge CLI was not found.")
            || normalized.hasPrefix("Antigravity CLI was not found.")
            || normalized.hasPrefix("Cursor Agent CLI was not found.")
            || normalized.hasPrefix("Codex CLI was not found.")
            || normalized.hasPrefix("Claude Code CLI was not found.")
            || normalized.hasPrefix("No eligible route for ")
            || (normalized.hasPrefix("Selected ") && normalized.contains("has not been verified against this gateway's live /v1/models catalog."))
    }

    /// Build a fallback history from the shared controller's messages, optionally
    /// appending an as-yet-unsent user turn.
    private func currentHistory(appendingUser pending: String? = nil) -> [PetChatFallback.Turn] {
        var turns: [PetChatFallback.Turn] = chat.messages.compactMap { rec in
            let role: PetChatFallback.Turn.Role
            switch rec.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            return PetChatFallback.Turn(role: role, text: rec.content)
        }
        if let pending, !pending.isEmpty {
            turns.append(PetChatFallback.Turn(role: .user, text: pending))
        }
        return turns
    }
}

// MARK: - PetChatBubbleView

/// The frosted SwiftUI speech bubble anchored to the ``PetPanel`` (PLAN C5).
/// Opens on pet click, streams the reply, carries the brain switcher, and shows
/// the "answering locally" beat. Styled with the app's ``DesignSystem`` tokens
/// so it reads as native BurnBar chrome.
struct PetChatBubbleView: View {
    @Bindable var controller: PetChatController
    /// Tail anchor (the renderer's `"contact"` socket projected into the bubble's
    /// space). The tail points at this x within the bubble width.
    var tailAnchorX: CGFloat = 0.5
    var onContentSizeChange: () -> Void = {}

    @FocusState private var inputFocused: Bool

    var body: some View {
        contentColumn
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.md)
            // Reserve room at the bottom for the speech-bubble tail (carved into
            // the outline) so it never clips the input row.
            .padding(.bottom, DesignSystem.Spacing.md + 6)
            .frame(width: 300)
            .glassBubbleChrome(tailAnchor: tailAnchorX)
            .onAppear { inputFocused = true }
            .onChange(of: controller.isOpen) { _, open in inputFocused = open }
            .onChange(of: controller.draft) { _, _ in controller.userDidType() }
            .onChange(of: controller.replyText) { _, _ in onContentSizeChange() }
            .onChange(of: controller.isAnswering) { _, _ in onContentSizeChange() }
            .onChange(of: controller.isAnsweringLocally) { _, _ in onContentSizeChange() }
            .onChange(of: controller.lastErrorNote) { _, _ in onContentSizeChange() }
            .onChange(of: controller.pendingAttachments.count) { _, _ in onContentSizeChange() }
            .animation(DesignSystem.Animation.gentle, value: controller.isAnswering)
            .animation(DesignSystem.Animation.gentle, value: controller.replyText)
            .animation(DesignSystem.Animation.gentle, value: controller.pendingAttachments.count)
    }

    /// The bubble's content column, broken out so `body`'s modifier chain
    /// type-checks in reasonable time.
    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            attachmentTray
            transcript
            inputRow
        }
    }

    // MARK: Attachment tray (file drag-and-drop onto the pet)

    /// Mercury-styled chip strip for staged attachments. Reuses the shared
    /// ``ChatAttachmentTray`` (the same component the chat composer renders) with
    /// `isHermes: true` so the chips get the mercury gradient stroke per the
    /// DESIGN.md chat-surface identity. Renders nothing when no attachments are
    /// staged and no error is present, so the bubble stays clean.
    @ViewBuilder
    private var attachmentTray: some View {
        if !controller.pendingAttachments.isEmpty || controller.attachmentError != nil {
            ChatAttachmentTray(
                attachments: controller.pendingAttachments,
                isHermes: true,
                attachmentError: controller.attachmentError,
                onRemove: { controller.removeAttachment($0) },
                onReveal: { controller.revealAttachment($0) }
            )
        }
    }

    // MARK: Header — brain switcher + close

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            backendPicker
            Spacer(minLength: 0)
            if controller.isAnsweringLocally {
                localBadge
            }
            Button {
                controller.requestClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close chat bubble")
        }
    }

    /// The agent switcher — reuses ``ChatBackendID`` exactly. Selecting cancels
    /// any stream and replays to the next brain (PLAN C7).
    private var backendPicker: some View {
        Menu {
            ForEach(controller.availableBackends) { backend in
                Button {
                    controller.switchBackend(to: backend)
                } label: {
                    if backend == controller.activeBackend {
                        Label(backend.displayName, systemImage: "checkmark")
                    } else {
                        Text(backend.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xxs) {
                Circle()
                    .fill(DesignSystem.Colors.primaryGradient)
                    .frame(width: 7, height: 7)
                Text(controller.activeBackend.shortLabel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .menuStyle(.borderlessButton)
        // Let the picker label truncate (it never does with today's short
        // labels) rather than .fixedSize() forcing it to push the localBadge /
        // close button off the fixed-width header. Lowest layout priority so the
        // close button and "answering locally" badge keep their room first.
        .layoutPriority(0)
        .accessibilityLabel("Answering brain")
        .accessibilityValue(controller.activeBackend.displayName)
    }

    private var localBadge: some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 8, weight: .bold))
            Text("answering locally")
                .font(DesignSystem.Typography.tiny)
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(DesignSystem.Colors.warning)
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .padding(.vertical, 2)
        .background(DesignSystem.Colors.warning.opacity(0.12), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        if controller.replyText.isEmpty && controller.isAnswering {
            thinkingDots
        } else if !controller.replyText.isEmpty {
            ScrollView {
                Text(controller.replyText)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Cap the transcript so a long multi-paragraph cloud reply scrolls
            // inside the bubble instead of growing the NSPanel past the screen.
            // The cap lets NSHostingView.fittingSize settle so the panel stays
            // on-screen; .bottom anchor keeps freshly streamed tokens visible.
            .frame(maxHeight: 280)
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
        } else if let note = controller.lastErrorNote {
            Text(note)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var thinkingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(DesignSystem.Colors.textMuted)
                    .frame(width: 5, height: 5)
                    .opacity(0.4)
                    .scaleEffect(controller.isAnswering ? 1.3 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18),
                        value: controller.isAnswering
                    )
            }
        }
        .accessibilityLabel("Thinking")
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            TextField("Ask \(controller.petName)…", text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(submit)
                .submitLabel(.send)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        controller.draft.trimmingCharacters(in: .whitespaces).isEmpty
                            ? AnyShapeStyle(DesignSystem.Colors.textMuted)
                            : AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                    )
            }
            .buttonStyle(.plain)
            .disabled(controller.draft.trimmingCharacters(in: .whitespaces).isEmpty || controller.isAnswering)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(DesignSystem.Colors.surface.opacity(0.6), in: Capsule())
    }

    private func submit() {
        Task { await controller.send() }
    }

    // MARK: Chrome

    // The chrome (Liquid Glass plate, sheen, specular rim, shadow + glow) lives
    // in `glassBubbleChrome` below, broken out so `body`'s modifier chain
    // type-checks in reasonable time.
}

// MARK: - Liquid Glass bubble chrome

/// The state-of-the-art Liquid Glass speech-bubble chrome. Everything is CLIPPED
/// to the bubble silhouette (body + tail) so it reads as one real refracting
/// glass bubble, not a glass plate with a rectangle behind it:
///   • the Liquid Glass plate is the primary surface (on macOS 26+ it refracts
///     the desktop behind it; older systems get a tuned `ultraThinMaterial`);
///   • a faint brand-tinted sheen rides under the glass;
///   • a hairline specular rim catches the light along the top edge;
///   • a layered soft shadow + warm glow ground the bubble in space.
/// Broken into its own modifier so `body`'s chain type-checks in reasonable
/// time.
private struct GlassBubbleChrome: ViewModifier {
    let tailAnchor: CGFloat

    func body(content: Content) -> some View {
        let shape = SpeechBubbleShape(tailAnchor: tailAnchor)
        // Clip FIRST so the glass plate, sheen, and rim all conform to the
        // bubble silhouette and the content never leaks past the tail.
        content
            .background {
                // Soft brand sheen riding UNDER the glass — drawn as a
                // background so the content (text) stays legible on top.
                shape.fill(SpeechBubbleSheen.gradient)
            }
            .clipShape(shape)
            .liquidGlassSurface(in: shape, fallback: .ultraThinMaterial)
            .overlay {
                // Hairline specular rim along the bubble's outer edge.
                shape.stroke(specularRim, lineWidth: 1)
            }
            // Shadow + glow apply to the clipped bubble silhouette, not a rect.
            .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 12)
            .shadow(color: DesignSystem.Colors.ember.opacity(0.10), radius: 34, x: 0, y: 16)
    }

    private var specularRim: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.5),
                Color.white.opacity(0.06),
                Color.white.opacity(0.22)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The faint brand-tinted gradient that rides under the glass so the bubble has
/// a warm identity even where the desktop behind it is dark.
private enum SpeechBubbleSheen {
    static let gradient = LinearGradient(
        colors: [
            DesignSystem.Colors.ember.opacity(0.14),
            DesignSystem.Colors.amber.opacity(0.08),
            Color.clear
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

private extension View {
    func glassBubbleChrome(tailAnchor: CGFloat) -> some View {
        modifier(GlassBubbleChrome(tailAnchor: tailAnchor))
    }
}

// MARK: - SpeechBubbleShape

/// A proper speech-bubble silhouette: a rounded body with the downward tail
/// carved INTO the bottom edge as one continuous outline (no internal seam).
/// The tail's horizontal position follows the pet's contact socket
/// (`tailAnchor`, 0…1). Used as the Liquid Glass plate shape so the bubble
/// refracts light as a real chat bubble, not a plain rounded rect with a
/// stuck-on triangle.
private struct SpeechBubbleShape: Shape {
    var tailAnchor: CGFloat = 0.5
    var cornerRadius: CGFloat = DesignSystem.Radius.lg
    var tailWidth: CGFloat = 16
    var tailHeight: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, min(rect.width, rect.height - tailHeight) / 2)
        guard r > 0, rect.width > tailWidth, (rect.height - tailHeight) > 0 else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
            return path
        }

        let left = rect.minX
        let right = rect.maxX
        let top = rect.minY
        let bodyBottom = rect.maxY - tailHeight

        // Tail anchor, clamped so the tail never collides with the bottom corners.
        let anchorX = left + max(tailWidth / 2 + r + 2,
                                 min(right - tailWidth / 2 - r - 2,
                                     rect.width * tailAnchor))
        let tailLeft = anchorX - tailWidth / 2
        let tailRight = anchorX + tailWidth / 2
        let tailTipY = rect.maxY

        // Trace the bubble as ONE continuous path:
        //   start at top-left (after the rounded corner), go clockwise across the
        //   top, down the right, along the bottom to the tail, OUT to the tip,
        //   back to the bottom, and down the left — so the tail is carved into the
        //   outline instead of being a separate triangle with an internal seam.
        path.move(to: CGPoint(x: left, y: top + r))
        // Top-left corner.
        path.addArc(center: CGPoint(x: left + r, y: top + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        // Top edge.
        path.addLine(to: CGPoint(x: right - r, y: top))
        // Top-right corner.
        path.addArc(center: CGPoint(x: right - r, y: top + r), radius: r,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        // Right edge down to the bottom-right corner.
        path.addLine(to: CGPoint(x: right, y: bodyBottom - r))
        // Bottom-right corner.
        path.addArc(center: CGPoint(x: right - r, y: bodyBottom - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Bottom edge up to the tail's right base.
        path.addLine(to: CGPoint(x: tailRight, y: bodyBottom))
        // Out to the tail tip and back to the left base.
        path.addLine(to: CGPoint(x: anchorX, y: tailTipY))
        path.addLine(to: CGPoint(x: tailLeft, y: bodyBottom))
        // Bottom edge to the bottom-left corner.
        path.addLine(to: CGPoint(x: left + r, y: bodyBottom))
        // Bottom-left corner.
        path.addArc(center: CGPoint(x: left + r, y: bodyBottom - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        // Left edge back up to the start.
        path.closeSubpath()
        return path
    }
}
