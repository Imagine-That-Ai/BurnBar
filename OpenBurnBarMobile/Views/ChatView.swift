import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Chat View

struct ChatView: View {
    @State private var service = HermesService()
    @State private var inputText = ""
    @State private var showClearConfirmation = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            connectionStatusBar
            messageList
            Divider()
                .background(MobileTheme.Colors.border)
            inputBar
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Hermes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear Chat", systemImage: "trash")
                    }
                    .disabled(service.messages.isEmpty)
                    Button {
                        Task { await service.checkReachability() }
                    } label: {
                        Label("Check Connection", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .alert("Clear Chat?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                withAnimation(MobileTheme.Animation.standard) {
                    service.clearChat()
                }
            }
        } message: {
            Text("This will remove all messages from the current conversation.")
        }
        .onAppear {
            service.loadHistory()
            Task { await service.checkReachability() }
        }
    }

    // MARK: - Connection Status

    private var connectionStatusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.isReachable ? MobileTheme.Colors.success : MobileTheme.Colors.warning)
                .frame(width: 6, height: 6)
            Text(service.isReachable ? "Hermes connected" : "Hermes not reachable")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(service.isReachable ? MobileTheme.Colors.success : MobileTheme.Colors.warning)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MobileTheme.Colors.surfaceElevated.opacity(0.5))
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: MobileTheme.Spacing.lg) {
                    ForEach(service.messages) { message in
                        HermesChatBubble(message: message)
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    if service.isStreaming {
                        HermesThinkingIndicator()
                            .id("thinking")
                    }
                }
                .padding(MobileTheme.Spacing.lg)
            }
            .onChange(of: service.messages.count) { _, _ in
                if let last = service.messages.last {
                    withAnimation(MobileTheme.Animation.gentle) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: service.isStreaming) { _, new in
                if new {
                    withAnimation(MobileTheme.Animation.gentle) {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            textField
            sendButton
        }
        .padding(MobileTheme.Spacing.md)
        .background(MobileTheme.Colors.surface.ignoresSafeArea())
    }

    private var textField: some View {
        TextField("Ask Hermes…", text: $inputText, axis: .vertical)
            .font(MobileTheme.Typography.body)
            .focused($isInputFocused)
            .lineLimit(1...5)
            .padding(MobileTheme.Spacing.md)
            .background(inputFieldBackground)
    }

    private var inputFieldBackground: some View {
        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
            .fill(MobileTheme.Colors.surfaceElevated)
            .overlay(inputFieldStroke)
    }

    private var inputFieldStroke: some View {
        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
            .stroke(inputFieldStrokeColor, lineWidth: inputFieldStrokeWidth)
    }

    private var inputFieldStrokeColor: Color {
        isInputFocused ? MobileTheme.hermesAureate : MobileTheme.Colors.border
    }

    private var inputFieldStrokeWidth: CGFloat {
        isInputFocused ? 1.5 : 0.5
    }

    private var sendButton: some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(sendButtonColor)
        }
        .disabled(inputText.isEmpty || service.isStreaming)
        .buttonStyle(.plain)
    }

    private var sendButtonColor: Color {
        inputText.isEmpty ? MobileTheme.Colors.textMuted : MobileTheme.hermesAureate
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        service.sendMessage(text)
    }
}

// MARK: - Hermes Chat Bubble

struct HermesChatBubble: View {
    let message: HermesChatMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: MobileTheme.Spacing.sm) {
            if isUser {
                Spacer(minLength: 48)
                bubble
            } else {
                bubble
                Spacer(minLength: 48)
            }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .font(MobileTheme.Typography.body)
            .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(isUser ? MobileTheme.Colors.surfaceElevated : MobileTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(bubbleStrokeColor, lineWidth: message.isError ? 1.5 : 1)
            )
    }

    private var bubbleStrokeColor: Color {
        if message.isError { return MobileTheme.Colors.error }
        return isUser ? MobileTheme.Colors.chatUserStroke : MobileTheme.Colors.chatAssistantStroke
    }
}

// MARK: - Hermes Thinking Indicator

struct HermesThinkingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(MobileTheme.mercuryGradient)
                    .frame(width: 8, height: 8)
                    .scaleEffect(1 + 0.3 * sin(phase + Double(index) * 1.2))
                    .opacity(0.5 + 0.5 * sin(phase + Double(index) * 1.2))
            }
        }
        .padding(MobileTheme.Spacing.md)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
