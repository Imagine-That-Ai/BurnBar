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

struct PiConversationListView: View {
    @Bindable var service: PiService

    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var showConnectionSheet = false

    var body: some View {
        ZStack {
            AuroraBackdrop()

            Group {
                if historyStore.threads(for: .pi).isEmpty {
                    emptyLanding
                } else {
                    threadList
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
        .navigationTitle("Pi")
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
        .navigationDestination(for: PiChatRoute.self) { route in
            PiChatThreadView(service: service, route: route)
        }
        .task {
            historyStore.bootstrap()
            await service.refreshRuntime()
        }
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
                    NavigationLink(value: PiChatRoute.existing(threadID: thread.id)) {
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
        NavigationLink(value: PiChatRoute.new) {
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
        .simultaneousGesture(TapGesture().onEnded {
            HapticBus.sheetOpen()
            service.startNewThread()
        })
        .accessibilityLabel("Start new Pi chat")
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
                    Text(thread.preview)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
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

                if service.messages.isEmpty {
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
        .onAppear {
            applyRouteOnAppear()
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
                    ForEach(service.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(MobileTheme.Spacing.lg)
            }
            .onChange(of: service.messages.last?.id) { _, lastID in
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
            VStack(alignment: .leading, spacing: 4) {
                if !isUser {
                    HStack(spacing: 4) {
                        Text(AssistantRuntimeID.pi.glyph)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Text("via Pi")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(MobileTheme.whimsy)
                }
                Text(msg.text.isEmpty ? (msg.isStreaming ? "…" : "") : msg.text)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(msg.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                    .padding(.horizontal, MobileTheme.Spacing.md)
                    .padding(.vertical, MobileTheme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                                    .strokeBorder(
                                        isUser
                                            ? AnyShapeStyle(MobileTheme.Colors.chatUserStroke.opacity(0.55))
                                            : AnyShapeStyle(MobileTheme.piGradient),
                                        lineWidth: 0.7
                                    )
                            )
                    )
            }
            if !isUser { Spacer(minLength: 32) }
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
