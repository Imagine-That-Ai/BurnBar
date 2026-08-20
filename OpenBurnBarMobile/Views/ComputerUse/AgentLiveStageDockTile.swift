#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// The 320×180 (compact) / 360×203 (regular) floating live mirror tile.
///
/// Visible in `.dock` mode. Mirror is **non-interactive** here — taps
/// promote to `.split`. Pinch-out promotes to `.split` then `.maximize`;
/// pinch-in collapses or hides. Dragging moves the tile and snaps to the
/// nearest corner inside the container.
///
/// Wire: reads the singleton's `AgentWatchState` and mounts the singleton's
/// shared `AgentWatchVideoCoordinator` layer. The singleton does the decode
/// work so dock/split/maximize transitions keep the last frame warm.
struct AgentLiveStageDockTile: View {
    @ObservedObject var state: AgentWatchState
    @ObservedObject var presenter: AgentLiveStagePresenter
    @ObservedObject var videoCoordinator: AgentWatchVideoCoordinator
    var horizontalSizeClass: UserInterfaceSizeClass?
    var onApprove: () -> Void
    var onReject: () -> Void
    var onRejectHalt: () -> Void
    var onPanic: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchScale: CGFloat = 1
    @State private var pulseEmber: Bool = false

    private var tileSize: CGSize {
        switch horizontalSizeClass {
        case .regular: return CGSize(width: 360, height: 203)
        default:       return CGSize(width: 320, height: 180)
        }
    }
    private var insetPadding: CGFloat { 16 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: anchor) {
                tile
                    .frame(width: tileSize.width, height: tileSize.height)
                    .offset(dragOffset)
                    .padding(insetPadding)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: presenter.dockCorner) { _, _ in
                dragOffset = .zero
            }
        }
        .onChange(of: presenter.collapseReason) { _, reason in
            guard reason == .panic else { return }
            pulseEmber = true
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                pulseEmber = false
            }
        }
    }

    private var anchor: Alignment {
        switch presenter.dockCorner {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    @ViewBuilder
    private var tile: some View {
        ZStack {
            // Black backplate so the mirror keeps its letterboxing while
            // the rest of the card paints over it.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)

            AgentWatchVideoSurface(coordinator: videoCoordinator)
                .opacity(state.currentFrame == nil ? 0 : 1)

            if state.currentFrame == nil {
                placeholder
            }

            VStack {
                top
                Spacer(minLength: 0)
                bottom
            }
            .padding(10)

            // Mercury border + shimmer
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MobileTheme.mercuryGradient, lineWidth: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )

            if !reduceMotion {
                MercuryShimmerOverlay()
                    .allowsHitTesting(false)
                    .mask(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(lineWidth: 3)
                    )
            }

            // Ember pulse one-shot after panic halt or executing actions
            if pulseEmber || isCurrentlyExecuting {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(MobileTheme.amber.opacity(0.65), lineWidth: 2)
                    .blur(radius: 2)
                    .opacity(pulseEmber ? 1 : 0.55)
                    .animation(.easeInOut(duration: 0.55).repeatCount(2, autoreverses: true),
                               value: pulseEmber)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
        .scaleEffect(pinchScale)
        .gesture(tapGesture)
        .simultaneousGesture(dragGesture)
        .simultaneousGesture(pinchGesture)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Tap to expand. Pinch out to maximize.")
        .accessibilityAddTraits(.isButton)
    }

    private var isCurrentlyExecuting: Bool {
        state.actionTimeline.last?.status == .executing
    }

    private var accessibilityLabel: String {
        var pieces: [String] = ["Mac live mirror"]
        if let summary = state.actionTimeline.last?.summary { pieces.append("Last action: \(summary)") }
        pieces.append("\(state.actionsExecuted) actions")
        if state.pendingApproval != nil { pieces.append("Approval pending") }
        return pieces.joined(separator: ". ")
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "wand.and.rays")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Text(state.sessionId == nil
                 ? "Waiting for a Mac session…"
                 : "Live mirror ready")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    @ViewBuilder
    private var top: some View {
        HStack(alignment: .top, spacing: 6) {
            AgentLiveStageTelemetryCapsule(
                startedAt: state.sessionStartedAt,
                actionsExecuted: state.actionsExecuted,
                trustMode: state.liveTrustMode
            )
            Spacer(minLength: 0)
            Button {
                onPanic()
            } label: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(
                        Circle()
                            .fill(MobileTheme.error)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Panic halt the agent")
        }
    }

    @ViewBuilder
    private var bottom: some View {
        VStack(spacing: 6) {
            if let pending = state.pendingApproval {
                AgentLiveStageApprovalStripe(
                    request: pending,
                    style: .compact,
                    onApprove: onApprove,
                    onReject: onReject,
                    onRejectHalt: onRejectHalt
                )
            } else {
                AgentLiveStageActionTicker(entry: state.actionTimeline.last)
                    .padding(.horizontal, 2)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Tap to drive")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .tracking(0.4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Gestures

    private var tapGesture: some Gesture {
        TapGesture()
            .onEnded {
                HapticBus.sheetOpen()
                withAnimation(reduceMotion
                              ? .easeInOut(duration: 0.18)
                              : .spring(response: 0.42, dampingFraction: 0.82)) {
                    presenter.requestExpand()
                }
            }
    }

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
                // Snap to nearest corner of the screen via dock offset
                // sign — translate the final centroid into a corner
                // choice. The container itself is full-size, so we use
                // the predicted end velocity.
                let predicted = CGPoint(
                    x: value.predictedEndLocation.x,
                    y: value.predictedEndLocation.y
                )
                let frame = UIScreen.main.bounds.size
                let corner = AgentLiveStagePresenter.nearestCorner(for: predicted, in: frame)
                withAnimation(reduceMotion
                              ? .easeInOut(duration: 0.18)
                              : .spring(response: 0.42, dampingFraction: 0.78)) {
                    presenter.snapDock(to: corner)
                    dragOffset = .zero
                }
                HapticBus.toggle()
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.05)
            .onChanged { value in
                pinchScale = max(0.85, min(value, 1.18))
            }
            .onEnded { value in
                withAnimation(reduceMotion
                              ? .easeInOut(duration: 0.18)
                              : .spring(response: 0.4, dampingFraction: 0.84)) {
                    if value > 1.08 {
                        presenter.requestExpand()
                    }
                    pinchScale = 1
                }
            }
    }
}
#endif
