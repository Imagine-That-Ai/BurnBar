import SwiftUI
import OpenBurnBarCore

// MARK: - Pi Conversation List View
//
// Sibling of `HermesConversationListView`. Renders a single Pi chat thread
// with a composer, message stream, and connection state banner. The
// surface intentionally stays minimal in this wave — Plan 2's deferred items
// include rich tool cards, library import, and per-host conversation
// listing.

struct PiConversationListView: View {
    @Bindable var service: PiService

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
                        service.clear()
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
        .task {
            await service.refreshRuntime()
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
