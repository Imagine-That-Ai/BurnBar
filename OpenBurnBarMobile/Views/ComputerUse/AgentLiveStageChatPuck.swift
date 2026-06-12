#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore

/// The "Chat Puck" — the floating, draggable representation of the
/// Hermes chat that appears in `.maximize` mode so the user never loses
/// touch with the agent while the mirror fills the screen.
///
/// Collapsed: 56×56 caduceus puck with slow mercury shimmer and (when
/// Hermes is streaming) three pooling droplets that ride the lower edge.
/// Tap → expands into a 320×420 floating panel showing the last few
/// messages + a composer. Tap again (or the chevron) → collapses.
struct AgentLiveStageChatPuck: View {
    @ObservedObject var presenter: AgentLiveStagePresenter
    @Bindable var hermesService: HermesService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: anchor) {
                Group {
                    if presenter.chatPuckExpanded {
                        expandedPanel
                            .transition(.scale(scale: 0.7, anchor: scaleAnchor)
                                .combined(with: .opacity))
                    } else {
                        collapsedPuck
                            .transition(.scale(scale: 0.7, anchor: scaleAnchor)
                                .combined(with: .opacity))
                    }
                }
                .offset(dragOffset)
                .padding(16)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(reduceMotion ? .easeInOut(duration: 0.18)
                                    : .spring(response: 0.42, dampingFraction: 0.82),
                       value: presenter.chatPuckExpanded)
        }
    }

    private var anchor: Alignment {
        switch presenter.puckCorner {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    private var scaleAnchor: UnitPoint {
        switch presenter.puckCorner {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    // MARK: - Collapsed puck

    @ViewBuilder
    private var collapsedPuck: some View {
        ZStack {
            Circle()
                .fill(MobileTheme.mercuryGradient)
                .frame(width: 56, height: 56)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                        .blur(radius: 0.5)
                        .blendMode(.multiply)
                )

            if !reduceMotion {
                MercuryShimmerOverlay()
                    .mask(Circle().inset(by: 1))
                    .frame(width: 56, height: 56)
            }

            VStack(spacing: 0) {
                Text("\u{263F}") // ☿ caduceus
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                if hermesService.isStreaming {
                    HermesThinkingSpinner()
                        .frame(height: 8)
                        .scaleEffect(0.45)
                        .padding(.top, -8)
                }
            }

            if unreadDelta > 0, !presenter.chatPuckExpanded {
                Text("\(unreadDelta)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(MobileTheme.ember)
                    )
                    .offset(x: 20, y: -22)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .accessibilityLabel("Hermes chat puck. \(unreadDelta) new characters.")
        .accessibilityHint("Tap to expand chat.")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            HapticBus.sheetOpen()
            presenter.toggleChatPuck()
        }
        .onLongPressGesture(minimumDuration: 0.6) {
            presenter.snapPuck(to: cyclePuck(corner: presenter.puckCorner))
            HapticBus.toggle()
        }
        .simultaneousGesture(dragGesture)
    }

    // MARK: - Expanded panel

    @ViewBuilder
    private var expandedPanel: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(Color.white.opacity(0.12))
            messageList
            Divider()
                .background(Color.white.opacity(0.12))
            composer
        }
        .frame(width: 320, height: 420)
        .chatPanelChrome()
        .simultaneousGesture(dragGesture)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text("\u{263F}")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(MobileTheme.mercuryGradient)
            Text("Hermes")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if hermesService.isStreaming {
                HermesThinkingSpinner()
                    .scaleEffect(0.5)
                    .frame(height: 8)
            }
            Spacer(minLength: 0)
            Button {
                presenter.toggleChatPuck()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    if visibleMessages.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.32))
                            Text("Type to brief Hermes while the agent works.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(visibleMessages) { message in
                            puckBubble(message)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: hermesService.messages.count) { _, _ in
                if let last = visibleMessages.last {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func puckBubble(_ message: HermesChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(message.text)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(message.role == .user
                                  ? Color.white.opacity(0.12)
                                  : Color.black.opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                message.role == .assistant
                                    ? AnyShapeStyle(MobileTheme.mercuryGradient)
                                    : AnyShapeStyle(Color.white.opacity(0.18)),
                                lineWidth: 0.75
                            )
                    )
            }
            if message.role != .user { Spacer(minLength: 28) }
        }
    }

    @ViewBuilder
    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Brief Hermes…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .focused($inputFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(canSend ? AnyShapeStyle(MobileTheme.mercuryGradient)
                                          : AnyShapeStyle(Color.white.opacity(0.15)))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var visibleMessages: [HermesChatMessage] {
        hermesService.messages.filter { $0.role != .tool }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !hermesService.isStreaming
    }

    private var unreadDelta: Int {
        // Approximate unread signal: characters in the latest assistant
        // message while it's streaming. Cheap heuristic, no persistence.
        guard let last = hermesService.messages.last,
              last.role == .assistant,
              last.isStreaming else { return 0 }
        return min(last.text.count, 99)
    }

    private func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        HapticBus.send()
        hermesService.sendMessage(trimmed)
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = dragOffset }
                let start = dragStart ?? .zero
                dragOffset = CGSize(width: start.width + value.translation.width,
                                    height: start.height + value.translation.height)
            }
            .onEnded { value in
                dragStart = nil
                let predicted = CGPoint(
                    x: value.predictedEndLocation.x,
                    y: value.predictedEndLocation.y
                )
                let frame = UIScreen.main.bounds.size
                let corner = AgentLiveStagePresenter.nearestCorner(for: predicted, in: frame)
                withAnimation(reduceMotion
                              ? .easeInOut(duration: 0.18)
                              : .spring(response: 0.42, dampingFraction: 0.78)) {
                    presenter.snapPuck(to: corner)
                    dragOffset = .zero
                }
                HapticBus.toggle()
            }
    }

    private func cyclePuck(corner current: AgentLiveStagePresenter.Corner) -> AgentLiveStagePresenter.Corner {
        let cycle: [AgentLiveStagePresenter.Corner] = [
            .bottomLeading, .bottomTrailing, .topTrailing, .topLeading
        ]
        let index = cycle.firstIndex(of: current) ?? 0
        return cycle[(index + 1) % cycle.count]
    }
}

private extension View {
    /// Expanded-panel chrome. On iOS 26 the panel is interactive Liquid
    /// Glass tinted dark to keep the white chat text legible (no
    /// `compositingGroup` — it would flatten the glass specular); older
    /// systems keep the ultra-thin material + dark scrim stack. The mercury
    /// stroke stays in both branches for brand continuity.
    ///
    /// Shadow note (iOS 26): `.shadow` on the un-composited hierarchy would
    /// re-shadow every primitive (header text, bubbles, dividers, the 1pt
    /// stroke) because `clipShape` does not composite, so the ambient depth
    /// is rendered once on a dedicated silhouette layer behind the glass.
    /// The silhouette background is appended *after* the clip so the shadow
    /// spill is not clipped away; backgrounds render backmost, behind glass.
    @ViewBuilder
    func chatPanelChrome() -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(.clear)
                .liquidGlassEffect(
                    .regular.tint(Color.black.opacity(0.55)).interactive(),
                    in: .rect(cornerRadius: 18)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(MobileTheme.mercuryGradient, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.001))
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
                )
        } else {
            self
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(MobileTheme.mercuryGradient, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .compositingGroup()
                .shadow(color: .black.opacity(0.45), radius: 22, y: 14)
        }
    }
}
#endif
