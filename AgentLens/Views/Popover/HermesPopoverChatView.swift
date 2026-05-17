import SwiftUI
import AppKit
import OpenBurnBarCore

// MARK: - Assistants Popover Chat View

/// Full chat experience inside the menu bar popover.
/// Renders whichever backend the user has selected (Hermes, Pi, Codex, etc.).
/// Layout: provider hero → chat thread → input → dashboard link.
///
/// Plan 2 parity: hero card emblem, glyph, border gradient, and status tint
/// all switch with the active `ChatBackendID`.
struct AssistantsPopoverChatView: View {
    @Bindable var controller: ChatSessionController
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    var settingsManager: SettingsManager
    var onDismissChat: () -> Void
    var onOpenDashboardWithChat: () -> Void

    /// Atom router scoped to the popover. Owns the chip-detail popover
    /// presentation and broadcasts `Notification.Name.hermesAtomActivated`
    /// on confirm so the surrounding menu bar surfaces can route the
    /// activation (open dashboard, switch tab, surface settings, …).
    @State private var atomRouter = HermesAtomRouter()

    var body: some View {
        VStack(spacing: 0) {
            runtimeHeroCard
            VStack(spacing: 4) {
                HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                    ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
                    Spacer(minLength: 0)
                    ChatEngineModelMenu(controller: controller)
                }
                HermesModelStrip(controller: controller, settingsManager: settingsManager)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(DesignSystem.Colors.surface.opacity(0.35))
            OpenBurnBarHermesOperatingStrip(layer: operatingLayer)
            Divider().background(runtimeDividerTint.opacity(0.3))
            chatThread
            Divider().background(runtimeDividerTint.opacity(0.3))
            inputRow
            bottomBar
        }
        .frame(width: 340)
        .background(DesignSystem.Colors.background)
        .environment(\.hermesAtomNavigator, atomRouter)
        .popover(item: Binding(
            get: { atomRouter.pending },
            set: { atomRouter.pending = $0 }
        )) { pending in
            HermesAtomDetailPopover(
                atom: pending.atom,
                label: pending.label,
                onOpen: {
                    atomRouter.confirm(pending)
                    atomRouter.pending = nil
                }
            )
        }
        .onAppear {
            controller.ensureChatWorkspaceDirectoryExists()
            // Warm pretext + install (a no-op) onPerform so the contract
            // is consistent with `ChatPanel`. Notifications still fire.
            PretextEngine.shared.start()
            atomRouter.onPerform = { _ in }
            Task {
                await controller.probeHermesAvailability()
                await controller.probeOpenClawAvailability()
                await operatingLayer.refreshControllerRuntime()
            }
        }
    }

    // MARK: - Hero Card

    private var runtimeHeroCard: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AnyShapeStyle(heroCardEmblemFill))
                    .frame(width: 36, height: 36)

                if let provider = controller.chatBackend.agentProvider {
                    ProviderLogoView(provider: provider, size: 24, useFallbackColor: false)
                } else {
                    Text(controller.chatBackend.glyph)
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(heroCardGlyphColor)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.chatBackend.displayName)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                heroCardStatusText
            }

            Spacer()

            Button {
                controller.revealChatWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(heroCardIconTint)
            }
            .buttonStyle(.plain)
            .popoverTooltip("Show this chat’s workspace in Finder — each new chat uses its own folder under OpenBurnBar’s Application Support.")

            // Mining animation or back button — top right corner
            if controller.isStreaming {
                AnimatedMiningPickView()
                    .frame(width: 28, height: 28)
            } else {
                Button {
                    onDismissChat()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.5))
                }
                .buttonStyle(.plain)
                .popoverTooltip("Back to overview")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background {
            DesignSystem.Colors.surfaceElevated
        }
        .mercuryShimmer(active: controller.isStreaming)
    }

    @ViewBuilder
    private var heroCardStatusText: some View {
        switch controller.chatBackend {
        case .hermes:
            if let modelName = controller.hermesModelName {
                HStack(spacing: 4) {
                    modelBrandDot(for: modelName)
                    Text(Self.abbreviateModelName(modelName))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            } else if controller.hermesAvailable {
                Text("Connected")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Text("Offline")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        case .piAgent:
            if let modelName = controller.piAgentModelName {
                HStack(spacing: 4) {
                    modelBrandDot(for: modelName)
                    Text(Self.abbreviateModelName(modelName))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            } else if controller.piAgentAvailable {
                Text("Connected")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Text("Offline")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        case .openclaw:
            if controller.openClawAvailable {
                Text("Connected")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Text("Offline")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        default:
            Text("Connected")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.success)
        }
    }

    private var heroCardEmblemFill: any ShapeStyle {
        switch controller.chatBackend {
        case .hermes:
            return LinearGradient(
                colors: [
                    DesignSystem.Colors.hermesMercury.opacity(0.15),
                    DesignSystem.Colors.hermesAureate.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .piAgent:
            return LinearGradient(
                colors: [
                    DesignSystem.Colors.whimsy.opacity(0.15),
                    DesignSystem.Colors.whimsy.opacity(0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [
                    DesignSystem.Colors.whimsy.opacity(0.10),
                    DesignSystem.Colors.ember.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var heroCardGlyphColor: Color {
        switch controller.chatBackend {
        case .hermes:   return DesignSystem.Colors.hermesAureate
        case .piAgent:  return DesignSystem.Colors.whimsy
        default:        return DesignSystem.Colors.textSecondary
        }
    }

    private var heroCardIconTint: Color {
        switch controller.chatBackend {
        case .hermes:   return DesignSystem.Colors.hermesAureate
        case .piAgent:  return DesignSystem.Colors.whimsy
        default:        return DesignSystem.Colors.textSecondary
        }
    }

    private var runtimeDividerTint: Color {
        switch controller.chatBackend {
        case .hermes:   return DesignSystem.Colors.hermesMercury
        case .piAgent:  return DesignSystem.Colors.whimsy
        default:        return DesignSystem.Colors.border
        }
    }

    @ViewBuilder
    private func modelBrandDot(for modelName: String) -> some View {
        let brand = LLMModelBrand.infer(fromModelKey: modelName)
        Circle()
            .fill(brand == .unknown
                  ? DesignSystem.Colors.colorForModel(modelName)
                  : brand.emblemColor)
            .frame(width: 6, height: 6)
    }

    private static func abbreviateModelName(_ name: String) -> String {
        var short = name
        let prefixes = ["NousResearch/", "meta-llama/", "mistralai/", "Qwen/", "google/", "deepseek-ai/"]
        for prefix in prefixes {
            if short.hasPrefix(prefix) {
                short = String(short.dropFirst(prefix.count))
                break
            }
        }
        if short.count > 32 {
            short = String(short.prefix(30)) + "…"
        }
        return short
    }

    // MARK: - Chat Thread

    private var chatThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    if controller.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(controller.messages) { msg in
                            HermesPopoverBubble(
                                message: msg,
                                isStreaming: controller.isStreaming
                                    && msg.id == controller.activeStreamMessageId
                                    && msg.role == .assistant
                            )
                            .id(msg.id)
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
            }
            .frame(minHeight: 140, maxHeight: 320)
            .onChange(of: controller.messages.count) { _, _ in
                if let last = controller.messages.last {
                    Task { @MainActor in
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            if let provider = controller.chatBackend.agentProvider {
                ProviderLogoView(provider: provider, size: 32, useFallbackColor: false)
                    .opacity(0.55)
            } else {
                Text(controller.chatBackend.glyph)
                    .font(.system(size: 32))
                    .foregroundStyle(heroCardGlyphColor.opacity(0.4))
            }

            Text("Ask \(controller.chatBackend.displayName)")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Text("OpenBurnBar index + your chosen backend")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xxl)
    }

    // MARK: - Input Row

    private var inputRow: some View {
        VStack(spacing: 0) {
            if !controller.pendingAttachments.isEmpty || controller.attachmentError != nil {
                ChatAttachmentTray(
                    attachments: controller.pendingAttachments,
                    isHermes: controller.chatBackend == .hermes,
                    attachmentError: controller.attachmentError,
                    onRemove: { controller.removeAttachment($0) },
                    onReveal: { revealAttachment($0) }
                )
            }
            HStack(spacing: DesignSystem.Spacing.sm) {
                attachmentMenu
                TextField(popoverInputPlaceholder, text: $controller.inputText)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .onSubmit {
                        Task { await sendMessage() }
                    }

                if controller.isStreaming {
                    Button {
                        controller.cancelGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    .buttonStyle(.plain)
                } else if popoverSendEnabled {
                    Button {
                        Task { await sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(heroCardIconTint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm + 2)
        }
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.6))
    }

    private var popoverSendEnabled: Bool {
        !controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !controller.pendingAttachments.isEmpty
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        Menu {
            Button {
                pickFiles()
            } label: {
                Label("Choose Files…", systemImage: "folder")
            }
            Button {
                pickImagesFromPhotos()
            } label: {
                Label("Photos…", systemImage: "photo.on.rectangle")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(heroCardIconTint)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Attach files")
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                controller.addAttachment(from: url)
            }
        }
    }

    private func pickImagesFromPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK {
            for url in panel.urls {
                controller.addAttachment(from: url)
            }
        }
    }

    private func revealAttachment(_ attachment: HermesAttachment) {
        let url = controller.chatWorkspaceURL.appendingPathComponent(attachment.workspaceRelativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button {
                controller.clearChat()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                    Text("New")
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                onOpenDashboardWithChat()
            } label: {
                HStack(spacing: 4) {
                    Text("Open in Dashboard")
                        .font(DesignSystem.Typography.tiny)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(heroCardIconTint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.surface.opacity(0.5))
    }

    private var popoverInputPlaceholder: String {
        switch controller.chatBackend {
        case .codex: return "Ask Codex…"
        case .claude: return "Ask Claude…"
        case .hermes: return "Ask Hermes…"
        case .openclaw: return "Ask OpenClaw…"
        case .piAgent: return "Ask Pi…"
        }
    }

    // MARK: - Actions

    private func sendMessage() async {
        await controller.send()
    }
}

// MARK: - Backward compatibility

@available(*, deprecated, renamed: "AssistantsPopoverChatView")
typealias HermesPopoverChatView = AssistantsPopoverChatView

// MARK: - Hermes Popover Bubble

/// Chat bubble optimized for the compact popover.
private struct HermesPopoverBubble: View {
    let message: ChatMessageRecord
    var isStreaming: Bool

    private var transcript: [ChatTranscriptPiece] {
        message.displayTranscript
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .user {
                Spacer(minLength: 40)
                userBubble
            } else {
                assistantColumn
                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - User

    private var userBubble: some View {
        let text = transcript.filter { $0.kind == .text }.map(\.value).joined()
        let display = text.isEmpty ? message.content : text

        return Text(display)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, DesignSystem.Spacing.sm + 2)
            .padding(.vertical, DesignSystem.Spacing.xs + 3)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 14,
                    bottomLeadingRadius: 14,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 14,
                    style: .continuous
                )
                .fill(DesignSystem.Colors.whimsy.opacity(0.12))
            }
    }

    // MARK: - Assistant

    private var assistantColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thinking state
            if isStreaming && transcript.isEmpty {
                HermesThinkingView()
                    .scaleEffect(0.85)
            }

            ForEach(popoverGroupedTranscript) { group in
                Group {
                    switch group {
                    case .toolGroup(let pieces):
                        popoverToolGroupStrip(pieces)
                    case .single(let piece):
                        let isLast = piece.id == transcript.last(where: { $0.kind == .text })?.id
                        let display = piece.value + (isStreaming && isLast ? "▍" : "")
                        // Use atom-aware rendering for completed assistant
                        // turns; streaming/error keeps plain `Text` so chips
                        // never thrash mid-stream.
                        let useAtomRendering = !isStreaming && !display.isEmpty
                        if !display.isEmpty {
                            Group {
                                if useAtomRendering {
                                    HermesRichBubble(text: piece.value, baseSize: 12)
                                        .frame(maxWidth: 260, alignment: .leading)
                                } else {
                                    Text(display)
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, DesignSystem.Spacing.sm + 2)
                            .padding(.vertical, DesignSystem.Spacing.xs + 3)
                            .background {
                                ZStack {
                                    UnevenRoundedRectangle(
                                        topLeadingRadius: 4,
                                        bottomLeadingRadius: 14,
                                        bottomTrailingRadius: 14,
                                        topTrailingRadius: 14,
                                        style: .continuous
                                    )
                                    .fill(DesignSystem.Colors.surface)

                                    UnevenRoundedRectangle(
                                        topLeadingRadius: 4,
                                        bottomLeadingRadius: 14,
                                        bottomTrailingRadius: 14,
                                        topTrailingRadius: 14,
                                        style: .continuous
                                    )
                                    .strokeBorder(DesignSystem.Colors.mercuryGradient, lineWidth: 0.75)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Popover Tool Group Strip

    @ViewBuilder
    private func popoverToolGroupStrip(_ pieces: [ChatTranscriptPiece]) -> some View {
        let reversedPieces = Array(pieces.reversed())
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(reversedPieces) { piece in
                    compactToolPill(piece)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Popover Transcript Grouping

    private var popoverGroupedTranscript: [TranscriptGroup] {
        TranscriptGroup.group(transcript)
    }

    @ViewBuilder
    private func compactToolPill(_ piece: ChatTranscriptPiece) -> some View {
        HStack(spacing: 4) {
            Image(systemName: toolIcon(for: piece.value))
                .font(.system(size: 9, weight: .semibold))
            Text(piece.value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(DesignSystem.Colors.mercuryGradient)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.hermesMercury.opacity(0.08))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(DesignSystem.Colors.hermesMercury.opacity(0.25), lineWidth: 0.5)
        }
    }

    private func toolIcon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("read") || n.contains("file") || n.contains("write") { return "doc.text" }
        if n.contains("bash") || n.contains("exec") || n.contains("run") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") { return "magnifyingglass" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") { return "globe" }
        if n.contains("edit") || n.contains("patch") { return "pencil.and.outline" }
        return "wrench.and.screwdriver"
    }
}
