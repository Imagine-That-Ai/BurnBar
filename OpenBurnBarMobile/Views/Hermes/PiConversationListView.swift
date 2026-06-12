import SwiftUI
import OpenBurnBarCore

// MARK: - Pi Conversation List View
//
// Sibling of `HermesConversationListView`. Renders the Pi assistants surface
// in two stages:
//
//   1. A landing list of past Pi chats (the persisted "chat history" — see
//      `MobileChatHistoryStore`), with a FAB to start a new chat.
//   2. A push-detail view (`PiChatThreadView`) that hosts the active chat
//      with the composer and streaming bubbles.
//
// When the user has no saved chats yet, the landing collapses into the
// empty-state hero and the same FAB opens a fresh thread directly. The
// surrounding `NavigationStack` belongs to `RootTabView.hermesStack`.

private struct PresentedPiChatRoute: Identifiable {
    let route: PiChatRoute

    var id: String {
        switch route {
        case .new:
            return "new"
        case .existing(let threadID):
            return "existing:\(threadID)"
        }
    }
}

struct PiConversationListView: View {
    @Bindable var service: PiService
    let onSelectExistingThreadInSplit: ((String) -> Void)?

    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @State private var presentedChatRoute: PresentedPiChatRoute?

    init(
        service: PiService,
        onSelectExistingThreadInSplit: ((String) -> Void)? = nil
    ) {
        self.service = service
        self.onSelectExistingThreadInSplit = onSelectExistingThreadInSplit
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                brandHeader
                Group {
                    if historyStore.threads(for: .pi).isEmpty {
                        emptyLanding
                    } else {
                        threadList
                    }
                }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    newChatFAB
                        .padding(.trailing, MobileTheme.Spacing.lg)
                        .padding(.bottom, MobileTheme.Spacing.lg)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Label("Re-check connection", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showConnectionSheet = true
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.whimsy)
                }
            }
        }
        .sheet(isPresented: $showConnectionSheet) {
            AssistantConnectionSheet(
                hermesService: nil,
                piService: service,
                focusedRuntime: .pi
            )
        }
        .sheet(isPresented: $showModelPicker) {
            AssistantModelPickerSheet(
                runtime: .pi,
                hermesService: HermesService.shared,
                piService: service
            )
        }
        .fullScreenCover(item: $presentedChatRoute) { presented in
            NavigationStack {
                PiChatThreadView(service: service, route: presented.route)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") {
                                presentedChatRoute = nil
                            }
                        }
                    }
            }
        }
        .task {
            historyStore.bootstrap()
            await service.refreshRuntime()
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        let lens = AssistantModelLens(hermesService: HermesService.shared, piService: service)
        let resolver = AssistantStatusResolver(hermesService: HermesService.shared, piService: service)
        return AssistantBrandHeader(
            runtime: .pi,
            runtimeStatus: resolver.status(for: .pi),
            modelSnapshot: lens.snapshot(for: .pi),
            endpointLabel: resolver.endpointLabel(for: .pi),
            onTapModel: { showModelPicker = true },
            onTapStatus: { showConnectionSheet = true }
        )
    }

    // MARK: - Subviews

    private var emptyLanding: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Spacer()
            ZStack {
                Circle()
                    .fill(MobileTheme.piGradient.opacity(0.25))
                    .frame(width: 64, height: 64)
                Text(AssistantRuntimeID.pi.glyph)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.whimsy)
            }
            Text("Ask Pi")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("Pi runs in the OpenBurnBar gateway on your Mac and answers via the same OpenAI-compatible API.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileTheme.Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var threadList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(historyStore.threads(for: .pi)) { thread in
                    Button {
                        openPiChat(.existing(threadID: thread.id))
                    } label: {
                        PiThreadRow(thread: thread)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        HapticBus.sheetOpen()
                        // Load synchronously on tap so the detail view's first
                        // paint shows the right messages instead of flickering
                        // through the previous chat.
                        service.loadThread(id: thread.id)
                    })
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            service.deleteThread(id: thread.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.top, 8)
            .padding(.bottom, 96)
        }
    }

    private var newChatFAB: some View {
        Button {
            openPiChat(.new)
        } label: {
            ZStack {
                Circle()
                    .fill(MobileTheme.piGradient)
                    .frame(width: 56, height: 56)
                    .shadow(color: MobileTheme.whimsy.opacity(0.35), radius: 12, y: 6)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start new Pi chat")
    }

    private func openPiChat(_ route: PiChatRoute) {
        HapticBus.sheetOpen()
        if case .existing(let threadID) = route,
           let onSelectExistingThreadInSplit {
            onSelectExistingThreadInSplit(threadID)
            return
        }
        if case .new = route {
            service.startNewThread()
        }
        presentedChatRoute = PresentedPiChatRoute(route: route)
    }
}

// MARK: - Routes

enum PiChatRoute: Hashable {
    case new
    case existing(threadID: String)
}

// MARK: - Thread Row

private struct PiThreadRow: View {
    let thread: MobileChatThread

    var body: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(MobileTheme.piGradient.opacity(0.25))
                    .frame(width: 36, height: 36)
                Text(AssistantRuntimeID.pi.glyph)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.whimsy)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title)
                    .font(MobileTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                if !thread.preview.isEmpty {
                    Text(HermesAtomParser.plainText(thread.preview))
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                MobileAttachmentSummaryStrip(attachments: thread.recentAttachmentPreviews)
                HStack(spacing: 8) {
                    Text(thread.updatedAt, style: .relative)
                    Text("· \(thread.messageCount) msgs")
                }
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Active Chat View

struct PiChatThreadView: View {
    @Bindable var service: PiService
    let route: PiChatRoute

    @State private var input: String = ""
    @State private var showConnectionSheet = false
    @State private var permissionGrantThreadID: String?
    @State private var showThinkingStylePicker = false
    @State private var atomRouter = HermesAtomRouter()

    /// `.tool` messages exist purely as context for the upstream model
    /// — they're hidden from the visible chat list. The tool pill on
    /// the assistant turn that produced the call already conveys that
    /// the model used a tool.
    private var visibleMessages: [PiChatMessage] {
        service.messages.filter { $0.role != .tool }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                AssistantStateBanner(
                    runtime: .pi,
                    state: derivedState
                ) {
                    showConnectionSheet = true
                }

                if visibleMessages.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                Divider().background(MobileTheme.Colors.border.opacity(0.4))

                composer
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        permissionGrantThreadID = service.ensureDesktopGrantThreadID()
                    } label: {
                        Label("Agent permissions", systemImage: "hand.raised")
                    }
                    Button {
                        showThinkingStylePicker = true
                    } label: {
                        Label("Thinking Style", systemImage: "circle.dotted")
                    }
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Label("Re-check connection", systemImage: "arrow.clockwise")
                    }
                    Button {
                        service.startNewThread()
                    } label: {
                        Label("New chat", systemImage: "plus.bubble")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.whimsy)
                }
            }
        }
        .sheet(isPresented: $showConnectionSheet) {
            AssistantConnectionSheet(
                hermesService: nil,
                piService: service,
                focusedRuntime: .pi
            )
        }
        .sheet(isPresented: $showThinkingStylePicker) {
            HermesThinkingStylePickerSheet(
                modelName: service.messages.last(where: { $0.role == .assistant })?.modelName
            )
        }
        .sheet(
            isPresented: Binding(
                get: { permissionGrantThreadID != nil },
                set: { if !$0 { permissionGrantThreadID = nil } }
            )
        ) {
            if let threadID = permissionGrantThreadID {
                AgentPermissionGrantSheet(runtimeID: .pi, threadID: threadID)
            }
        }
        .environment(\.hermesAtomNavigator, atomRouter)
        .sheet(item: Binding(
            get: { atomRouter.pending },
            set: { atomRouter.pending = $0 }
        )) { pending in
            HermesAtomDetailSheet(
                atom: pending.atom,
                label: pending.label,
                onOpen: { atomRouter.confirm(pending) }
            )
        }
        .onAppear {
            applyRouteOnAppear()
            // Plug the atom router into the Pi service so the
            // `burnbar_atom_open` tool can drive in-app navigation.
            service.setToolAtomNavigator(atomRouter)
        }
        .onDisappear {
            service.setToolAtomNavigator(nil)
        }
        // Pending-prompt consumer — picks up prompts stashed by the
        // "Ask Pi" widget chip AppIntent or a `burnbar://pi?prompt=…`
        // deep link. Non-empty values auto-send; empty slots simply leave
        // the user on the composer.
        .task(id: AssistantPendingPrompt.shared.pi) {
            guard let pending = AssistantPendingPrompt.shared.consume(.pi),
                  !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            service.send(prompt: pending)
        }
    }

    private func applyRouteOnAppear() {
        switch route {
        case .new:
            if !service.messages.isEmpty || service.currentThreadID != nil {
                service.startNewThread()
            }
        case .existing(let threadID):
            if service.currentThreadID != threadID {
                service.loadThread(id: threadID)
            }
        }
    }

    private var displayTitle: String {
        switch route {
        case .new: return "New Pi chat"
        case .existing:
            if let threadID = service.currentThreadID,
               let thread = MobileChatHistoryStore.shared.thread(id: threadID) {
                return thread.title
            }
            return "Pi"
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Spacer()
            ZStack {
                Circle()
                    .fill(MobileTheme.piGradient.opacity(0.25))
                    .frame(width: 64, height: 64)
                Text(AssistantRuntimeID.pi.glyph)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(MobileTheme.whimsy)
            }
            Text("Ask Pi")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("Pi runs in the OpenBurnBar gateway on your Mac and answers via the same OpenAI-compatible API.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileTheme.Spacing.xl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    ForEach(visibleMessages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(MobileTheme.Spacing.lg)
            }
            .onChange(of: visibleMessages.last?.id) { _, lastID in
                if let lastID {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ msg: PiChatMessage) -> some View {
        let isUser = msg.role == .user
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            if isUser { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser {
                    HStack(spacing: 4) {
                        Text(AssistantRuntimeID.pi.glyph)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("via Pi")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(MobileTheme.whimsy)
                }
                if !isUser, msg.outcome != .normal {
                    piOutcomeBadge(for: msg)
                }
                if !msg.text.isEmpty || msg.toolCalls.isEmpty || msg.isStreaming {
                    Group {
                        if msg.text.isEmpty, msg.isStreaming {
                            // The shared thinking spinner (user-chosen style/
                            // color/size) replaces the bare "…" placeholder.
                            HermesThinkingSpinner(modelName: msg.modelName)
                        } else {
                            Text(msg.text)
                                .font(MobileTheme.Typography.body)
                                .foregroundStyle(msg.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                                .padding(.horizontal, MobileTheme.Spacing.md)
                                .padding(.vertical, MobileTheme.Spacing.sm)
                        }
                    }
                        .background(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                .fill(piBubbleFill(for: msg))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                        .strokeBorder(
                                            piBubbleStroke(for: msg, isUser: isUser),
                                            lineWidth: 0.7
                                        )
                                )
                        )
                }
                if !isUser, msg.outcome.supportsRetry, canRetryPi(msg) {
                    piRetryPill(for: msg)
                }
                if !isUser, !msg.toolCalls.isEmpty {
                    UnifiedToolCallAccordion(calls: unifiedToolCalls(for: msg), accent: .pi)
                }
            }
            if !isUser { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private func piOutcomeBadge(for msg: PiChatMessage) -> some View {
        if let label = msg.outcome.badgeLabel,
           let symbol = msg.outcome.badgeSymbol {
            let color = piOutcomeColor(msg.outcome)
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
            .accessibilityLabel(Text("Reply outcome: \(label)"))
        }
    }

    private func piRetryPill(for msg: PiChatMessage) -> some View {
        let color = piOutcomeColor(msg.outcome)
        return Button {
            HapticBus.send()
            service.retryLastUserTurn()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                Text("Try again")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.10)))
            .overlay(Capsule().stroke(color.opacity(0.55), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Try again")
        .accessibilityHint("Re-sends your last message to Pi.")
    }

    private func piBubbleFill(for msg: PiChatMessage) -> AnyShapeStyle {
        switch msg.outcome {
        case .normal:
            if msg.isError {
                return AnyShapeStyle(MobileTheme.Colors.error.opacity(0.06))
            }
            return AnyShapeStyle(MobileTheme.Colors.surfaceElevated)
        case .refusal, .reasoningFallback:
            return AnyShapeStyle(MobileTheme.whimsy.opacity(0.07))
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return AnyShapeStyle(MobileTheme.Colors.error.opacity(0.06))
        }
    }

    private func piBubbleStroke(for msg: PiChatMessage, isUser: Bool) -> AnyShapeStyle {
        if isUser {
            return AnyShapeStyle(MobileTheme.Colors.chatUserStroke.opacity(0.55))
        }
        if msg.isError {
            return AnyShapeStyle(MobileTheme.Colors.error)
        }
        switch msg.outcome {
        case .normal:
            return AnyShapeStyle(MobileTheme.piGradient)
        case .refusal, .reasoningFallback:
            return AnyShapeStyle(MobileTheme.whimsy.opacity(0.55))
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return AnyShapeStyle(MobileTheme.Colors.error)
        }
    }

    private func piOutcomeColor(_ outcome: PiChatMessageOutcome) -> Color {
        switch outcome {
        case .normal: return MobileTheme.Colors.textSecondary
        case .refusal, .reasoningFallback: return MobileTheme.whimsy
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty: return MobileTheme.Colors.error
        }
    }

    /// Show the retry pill only on the trailing assistant turn while
    /// idle, mirroring `HermesChatView.canRetry`.
    private func canRetryPi(_ msg: PiChatMessage) -> Bool {
        guard !service.isStreaming else { return false }
        let trailing = visibleMessages.last(where: { $0.role == .assistant })?.id
        return trailing == msg.id
    }

    /// Maps a Pi turn's tool calls into the shared display model. The most
    /// recent call becomes the collapsed accordion row, and pulses while the
    /// service is still streaming this turn.
    private func unifiedToolCalls(for msg: PiChatMessage) -> [UnifiedToolCallDisplay] {
        let lastID = msg.toolCalls.last?.id
        return msg.toolCalls.map { tool in
            UnifiedToolCallDisplay(
                id: tool.id,
                name: tool.name,
                statusRaw: tool.status,
                detail: tool.detail,
                arguments: tool.arguments,
                isRunning: service.isStreaming && tool.id == lastID
            )
        }
    }

    private var composer: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            TextField("Ask Pi…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MobileTheme.Typography.body)
                .lineLimit(1...5)
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md)
                        .fill(MobileTheme.Colors.surface)
                        .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
                )
            Button {
                let text = input
                input = ""
                service.send(prompt: text)
            } label: {
                Image(systemName: service.isStreaming ? "stop.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(MobileTheme.piGradient)
            }
            .disabled(!service.isStreaming && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.plain)
            .accessibilityLabel(service.isStreaming ? "Stop generating" : "Send")
        }
        .padding(MobileTheme.Spacing.md)
        .background(MobileTheme.Colors.background)
    }

    // MARK: - State

    private var derivedState: AssistantStateBanner.State {
        if service.connections.count <= 1 && service.connections.first?.id == PiConnectionRecord.localDefault.id && !service.isReachable {
            return .noHosts
        }
        if service.selectedConnection.status == .revoked {
            return .selectedHostRevoked
        }
        if !service.isReachable {
            return .hostOffline(lastSeen: service.selectedConnection.lastSeenAt)
        }
        return .ok
    }
}
