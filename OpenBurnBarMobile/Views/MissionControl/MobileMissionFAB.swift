import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission FAB (iOS)
//
// A 56pt living orb. Small, circular, repositionable, beautiful.
//
// Idle: quiet compass glyph, muted stroke, no motion.
// Active: a slow grace rotating dashed ring (like a satellite orbit)
// tinted by activity type. Center shows the actual tool icon + one
// honest word — "Edit", "Grep", "LLM", "Approve". Soft radial glow
// pulses gently behind the orb. Color speaks: amber for tooling,
// whimsy for LLM streams, hermes-aureate for approvals, ember for errors.
//
// Interactions:
//   • Tap          → opens Mission Console sheet
//   • Press & hold → elegant tooltip fades in above the orb:
//                    "Drag to move · flick to dismiss"
//   • Drag         → orb shrinks to 0.92, dims to 0.7, ring pauses.
//                    Spring snap on release within bounds.
//   • Flick        → rapid drag release with velocity > 600 pt/s
//                    sends the orb flying off-screen in that direction,
//                    then hidden. A tiny 12 pt restore dot appears at
//                    the nearest edge — tap to summon the orb back.
//
// Hidden when Chart Studio is fullscreen.

struct MobileMissionFAB: View {
    @Bindable var host: MobileMissionConsoleHost
    var isVisible: Bool
    var anchorOffset: Binding<CGSize>
    var onTap: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var hasAppeared = false
    @State private var showTooltip = false
    @State private var tooltipTask: Task<Void, Never>?
    @State private var flickExitPosition: CGSize = .zero
    @State private var orbitRotation: Double = 0
    @State private var glowPulse: Bool = false
    @State private var resurrection = MissionFABResurrectionController.shared
    @State private var showResurrectToast: Bool = false
    @State private var resurrectToastTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cloudSubscriptionStore) private var cloudStore

    /// Convenience accessor — reads from the resurrection controller so
    /// dismiss/restore state is shared across the view tree.
    private var isDismissed: Bool { resurrection.isDismissed }

    private let fabSize: CGFloat = 56
    private let orbitSize: CGFloat = 64
    private let flickVelocityThreshold: CGFloat = 600
    private let tooltipHoldDuration: Double = 0.45

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let bounds = geo.size
            ZStack {
                if isVisible && !isDismissed {
                    tooltipOverlay
                        .position(
                            x: positionFor(bounds: bounds, safeArea: safeArea).x,
                            y: positionFor(bounds: bounds, safeArea: safeArea).y - 42
                        )
                        .opacity(showTooltip ? 1 : 0)
                        .scaleEffect(showTooltip ? 1 : 0.85)
                        .animation(.spring(response: 0.30, dampingFraction: 0.72), value: showTooltip)

                    orbButton
                        .position(flickPositionFor(bounds: bounds, safeArea: safeArea))
                        .gesture(
                            combinedGesture(bounds: bounds, safeArea: safeArea)
                        )
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                if isDismissed && isVisible {
                    restoreDot
                        .position(restoreDotPosition(bounds: bounds, safeArea: safeArea))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }

                // One-shot "I'm back because…" toast when the orb
                // auto-resurrects (approval ask appeared, mission
                // failed, etc.). Anchors above the orb's resting
                // position so it doesn't collide with the tooltip.
                if showResurrectToast,
                   let reason = resurrection.autoResurrectReason,
                   !isDismissed {
                    resurrectToast(reason: reason)
                        .position(
                            x: positionFor(bounds: bounds, safeArea: safeArea).x,
                            y: positionFor(bounds: bounds, safeArea: safeArea).y - 60
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(isVisible)
        .onAppear {
            hasAppeared = true
            startOrbitalAnimation()
            // Catch up any approval that landed while we were on a
            // different tab — auto-resurrect immediately if needed.
            resurrection.reconcile(against: host.snapshot)
            consumeAutoResurrectIfNeeded()
        }
        .onChange(of: host.snapshot.approvalAsks) { _, _ in
            resurrection.reconcile(against: host.snapshot)
            consumeAutoResurrectIfNeeded()
        }
        .onChange(of: host.snapshot.activeTiles) { _, _ in
            resurrection.reconcile(against: host.snapshot)
            consumeAutoResurrectIfNeeded()
        }
    }

    // MARK: - Auto-resurrect toast

    private func resurrectToast(reason: MissionFABResurrectionController.AutoResurrectReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph(for: reason))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.amber)
            Text(reason.displayMessage)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule().stroke(UnifiedDesignSystem.Colors.amber.opacity(0.40), lineWidth: 0.6)
                )
        )
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        .accessibilityLabel(reason.displayMessage)
    }

    private func glyph(for reason: MissionFABResurrectionController.AutoResurrectReason) -> String {
        switch reason {
        case .approvalAsk:       return "hand.raised.fill"
        case .missionFailed:     return "exclamationmark.triangle.fill"
        case .settingsToggle:    return "gearshape.fill"
        case .longPressTab:      return "hand.tap.fill"
        case .manualRestoreDot:  return "circle.dotted"
        }
    }

    private func consumeAutoResurrectIfNeeded() {
        guard resurrection.wasAutoResurrected, !isDismissed else { return }
        resurrectToastTask?.cancel()
        withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
            showResurrectToast = true
        }
        resurrectToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeOut(duration: 0.22)) {
                showResurrectToast = false
            }
            // Allow the dismiss animation to finish before clearing
            // the signal so the toast text doesn't blank mid-fade.
            try? await Task.sleep(nanoseconds: 240_000_000)
            resurrection.consumeAutoResurrectSignal()
        }
    }

    // MARK: - Tooltip

    private var tooltipOverlay: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Text("Drag to move · flick to dismiss")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 3)
    }

    // MARK: - The Orb

    private var orbButton: some View {
        let state = currentState
        return Button(action: onTap) {
            ZStack {
                // Soft radial glow when active
                if state.isActive {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    state.accent.opacity(glowPulse ? 0.35 : 0.18),
                                    state.accent.opacity(0.0)
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 42
                            )
                        )
                        .frame(width: 84, height: 84)
                        .blur(radius: 6)
                }

                // Main disc
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: fabSize, height: fabSize)
                        .shadow(
                            color: state.isActive
                                ? state.accent.opacity(0.25)
                                : Color.black.opacity(0.25),
                            radius: state.isActive ? 16 : 10,
                            x: 0,
                            y: state.isActive ? 6 : 4
                        )

                    if state.isActive {
                        Circle()
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        state.accent.opacity(0.9),
                                        state.accent.opacity(0.3),
                                        state.accent.opacity(0.9)
                                    ]),
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: fabSize, height: fabSize)
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                            .frame(width: fabSize, height: fabSize)
                    }
                }

                // Orbiting dashed ring when active
                if state.isActive && !isDragging && !reduceMotion {
                    orbitingRing(accent: state.accent)
                }

                // Center content
                centerContent(state: state)
            }
            .frame(width: fabSize, height: fabSize)
            .overlay(alignment: .topTrailing) {
                // Pro vocabulary — whisper at the orb corner. Free users see
                // a breathing foil dot; members see a tiny mercury crest.
                // Always-visible reminder that the Mission FAB lives in a
                // world where Cloud unlocks remote orchestration.
                proIndicator
                    .offset(x: 2, y: -2)
            }
            .scaleEffect(scaleFactor)
            .opacity(isDragging ? 0.75 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mission Console")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to open the Mission Control Console. Drag to reposition.")
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasAppeared)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isDragging)
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: glowPulse)
    }

    // MARK: - Pro indicator

    @ViewBuilder
    private var proIndicator: some View {
        if let cloudStore {
            if cloudStore.isActive {
                MercuryCrest(size: .small, shimmer: !reduceMotion)
                    .scaleEffect(0.55)
            } else {
                ProBadgeDot(pulse: .breathing, diameter: 7)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - Center content

    @ViewBuilder
    private func centerContent(state: OrbState) -> some View {
        if state.isActive, let label = state.honestLabel {
            VStack(spacing: 1) {
                Image(systemName: state.iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.accent)

                Text(label)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.accent.opacity(0.92))
                    .lineLimit(1)
            }
        } else {
            Image(systemName: state.iconName)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(
                    state.isActive
                        ? state.accent
                        : UnifiedDesignSystem.Colors.textSecondary.opacity(0.7)
                )
        }
    }

    // MARK: - Orbiting ring

    private func orbitingRing(accent: Color) -> some View {
        Circle()
            .trim(from: 0, to: 0.35)
            .stroke(
                accent.opacity(0.65),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [4, 10])
            )
            .frame(width: orbitSize, height: orbitSize)
            .rotationEffect(.degrees(orbitRotation))
    }

    // MARK: - Restore dot
    //
    // Bigger than before (16pt visual, 32pt hit target via padding so the
    // user can find it with a thumb), gently breathing so it doesn't
    // disappear into the background, and haloed when an approval is
    // waiting so the user knows there's a reason to look at it.

    private var restoreDot: some View {
        let state = currentState
        let hasPendingApproval = !host.snapshot.approvalAsks.isEmpty
        return Button {
            HapticBus.tabChange()
            withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) {
                resurrection.restoreFromDot()
                flickExitPosition = .zero
            }
        } label: {
            ZStack {
                // Halo — only when an approval is waiting. Loud enough to
                // attract a glance, calm enough to stay editorial.
                if hasPendingApproval && !reduceMotion {
                    Circle()
                        .stroke(state.accent.opacity(glowPulse ? 0.55 : 0.20), lineWidth: 1.5)
                        .frame(width: 36, height: 36)
                        .scaleEffect(glowPulse ? 1.08 : 0.9)
                        .opacity(0.85)
                }
                // Visible disc — 16pt, breath ±10% scale when idle.
                Circle()
                    .fill(state.accent.opacity(hasPendingApproval ? 0.85 : 0.62))
                    .frame(width: 16, height: 16)
                    .scaleEffect(reduceMotion ? 1.0 : (glowPulse ? 1.06 : 0.96))
                    .shadow(color: state.accent.opacity(hasPendingApproval ? 0.50 : 0.30), radius: 8, x: 0, y: 2)
            }
            // 32pt tap target — comfortably thumb-sized on every device.
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasPendingApproval
                            ? "Restore Mission Console orb — approval waiting"
                            : "Restore Mission Console orb")
        .accessibilityHint("Tap to bring the floating orb back. Also restorable from Settings or by long-pressing the Assistants tab.")
    }

    // MARK: - Combined gesture (drag + long-press tooltip)

    private func combinedGesture(bounds: CGSize, safeArea: EdgeInsets) -> some Gesture {
        SimultaneousGesture(
            dragGesture(bounds: bounds, safeArea: safeArea),
            LongPressGesture(minimumDuration: tooltipHoldDuration)
                .onEnded { _ in
                    guard !isDragging else { return }
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                        showTooltip = true
                    }
                    // Auto-hide after 2.5s if finger is still down
                    tooltipTask?.cancel()
                    tooltipTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation(.easeOut(duration: 0.20)) {
                            showTooltip = false
                        }
                    }
                }
        )
        .onEnded { _ in
            tooltipTask?.cancel()
            withAnimation(.easeOut(duration: 0.20)) {
                showTooltip = false
            }
        }
    }

    // MARK: - Drag

    private func dragGesture(bounds: CGSize, safeArea: EdgeInsets) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                showTooltip = false
                tooltipTask?.cancel()
                dragOffset = value.translation
            }
            .onEnded { value in
                isDragging = false

                // Flick-to-dismiss: high velocity release
                let velocity = hypot(value.velocity.width, value.velocity.height)
                if velocity > flickVelocityThreshold {
                    dismissWithFlick(velocity: value.velocity, bounds: bounds, safeArea: safeArea)
                    return
                }

                // Normal snap
                let newOffset = clampedOffset(
                    candidate: CGSize(
                        width: anchorOffset.wrappedValue.width + value.translation.width,
                        height: anchorOffset.wrappedValue.height + value.translation.height
                    ),
                    bounds: bounds,
                    safeArea: safeArea
                )
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    anchorOffset.wrappedValue = newOffset
                    dragOffset = .zero
                }
            }
    }

    private func dismissWithFlick(velocity: CGSize, bounds: CGSize, safeArea: EdgeInsets) {
        let speed = hypot(velocity.width, velocity.height)
        let unitX = velocity.width / speed
        let unitY = velocity.height / speed

        // Fly off-screen in the flick direction
        let exitDx = unitX * bounds.width * 0.6
        let exitDy = unitY * bounds.height * 0.6

        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            flickExitPosition = CGSize(width: exitDx, height: exitDy)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeOut(duration: 0.15)) {
                resurrection.dismiss()
                flickExitPosition = .zero
                dragOffset = .zero
            }
        }
    }

    // MARK: - Position math

    private func positionFor(bounds: CGSize, safeArea: EdgeInsets) -> CGPoint {
        let baseX = safeArea.leading + fabSize / 2 + 16
        let baseY = bounds.height - safeArea.bottom - fabSize / 2 - 96
        let candidate = CGSize(
            width: anchorOffset.wrappedValue.width + dragOffset.width,
            height: anchorOffset.wrappedValue.height + dragOffset.height
        )
        let clamped = clampedOffset(candidate: candidate, bounds: bounds, safeArea: safeArea)
        return CGPoint(x: baseX + clamped.width, y: baseY + clamped.height)
    }

    private func flickPositionFor(bounds: CGSize, safeArea: EdgeInsets) -> CGPoint {
        let base = positionFor(bounds: bounds, safeArea: safeArea)
        return CGPoint(
            x: base.x + flickExitPosition.width,
            y: base.y + flickExitPosition.height
        )
    }

    private func restoreDotPosition(bounds: CGSize, safeArea: EdgeInsets) -> CGPoint {
        let normal = positionFor(bounds: bounds, safeArea: safeArea)
        // Clamp to nearest edge
        let x = min(max(normal.x, safeArea.leading + 14), bounds.width - safeArea.trailing - 14)
        let y = min(max(normal.y, safeArea.top + 14), bounds.height - safeArea.bottom - 14)
        return CGPoint(x: x, y: y)
    }

    private func clampedOffset(candidate: CGSize, bounds: CGSize, safeArea: EdgeInsets) -> CGSize {
        let baseX = safeArea.leading + fabSize / 2 + 16
        let baseY = bounds.height - safeArea.bottom - fabSize / 2 - 96
        let resolvedX = baseX + candidate.width
        let resolvedY = baseY + candidate.height

        let minX = safeArea.leading + fabSize / 2 + 8
        let maxX = bounds.width - safeArea.trailing - fabSize / 2 - 8
        let minY = safeArea.top + fabSize / 2 + 60
        let maxY = bounds.height - safeArea.bottom - fabSize / 2 - 88

        let clampedX = min(max(resolvedX, minX), maxX)
        let clampedY = min(max(resolvedY, minY), maxY)

        return CGSize(width: clampedX - baseX, height: clampedY - baseY)
    }

    // MARK: - State

    private var currentState: OrbState {
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }
        let blocked = host.snapshot.activeTiles.filter { $0.phase == .blocked || $0.phase == .failed }
        let approvals = host.snapshot.approvalAsks

        if host.snapshot.health.daemonState == .macOffline {
            return OrbState(accent: UnifiedDesignSystem.Colors.textMuted, iconName: "wifi.slash", honestLabel: nil, isActive: false)
        }
        if !blocked.isEmpty {
            return OrbState(accent: UnifiedDesignSystem.Colors.ember, iconName: "exclamationmark.triangle.fill", honestLabel: "Error", isActive: true)
        }
        if !approvals.isEmpty {
            return OrbState(accent: UnifiedDesignSystem.Colors.hermesAureate, iconName: "hand.raised.fill", honestLabel: "Approve", isActive: true)
        }
        if let tile = live.first {
            return state(for: tile)
        }
        if host.snapshot.activeTiles.contains(where: { $0.phase == .completed }) {
            return OrbState(accent: UnifiedDesignSystem.Colors.success, iconName: "checkmark.seal.fill", honestLabel: nil, isActive: false)
        }
        return OrbState(accent: UnifiedDesignSystem.Colors.textMuted, iconName: "compass.drawing", honestLabel: nil, isActive: false)
    }

    private func state(for tile: MissionConsoleActiveTile) -> OrbState {
        let latest = host.snapshot.recentTicker.first { $0.missionID == tile.id }

        var label: String? = nil
        var icon = "sparkles"
        var accent = UnifiedDesignSystem.Colors.amber

        if let event = latest {
            switch event.kind {
            case .toolCall, .toolResult:
                label = event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? tile.currentToolName
                    ?? event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                icon = "hammer.fill"
                accent = UnifiedDesignSystem.Colors.amber
            case .llmResponse:
                label = "LLM"
                icon = "quote.bubble.fill"
                accent = UnifiedDesignSystem.Colors.whimsy
            case .approval:
                label = "Approve"
                icon = "hand.raised.fill"
                accent = UnifiedDesignSystem.Colors.hermesAureate
            case .error:
                label = "Error"
                icon = "exclamationmark.triangle.fill"
                accent = UnifiedDesignSystem.Colors.ember
            case .changedFile:
                label = event.pathDetail?.split(separator: "/").last.map(String.init)
                    ?? tile.currentToolName
                icon = "doc.badge.gearshape.fill"
                accent = UnifiedDesignSystem.Colors.amber
            default:
                label = tile.currentToolName ?? tile.phase.displayLabel
                accent = UnifiedDesignSystem.Colors.amber
            }
        } else {
            if tile.approvalPending {
                label = "Approve"
                icon = "hand.raised.fill"
                accent = UnifiedDesignSystem.Colors.hermesAureate
            } else if let tool = tile.currentToolName {
                label = tool
                icon = "hammer.fill"
                accent = UnifiedDesignSystem.Colors.amber
            } else if tile.phase == .streaming {
                label = "LLM"
                icon = "quote.bubble.fill"
                accent = UnifiedDesignSystem.Colors.whimsy
            } else {
                label = tile.phase.displayLabel
                accent = UnifiedDesignSystem.Colors.amber
            }
        }

        let clean = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .first?
            .prefix(8)
            .description
        return OrbState(accent: accent, iconName: icon, honestLabel: clean, isActive: true)
    }

    private struct OrbState {
        let accent: Color
        let iconName: String
        let honestLabel: String?
        let isActive: Bool
    }

    private var scaleFactor: CGFloat {
        if !hasAppeared { return 0.001 }
        if isDragging { return 0.92 }
        return 1.0
    }

    // MARK: - Animation

    private func startOrbitalAnimation() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.1).repeatForever(autoreverses: false)) {
            orbitRotation = 360
        }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            glowPulse = true
        }
    }

    private var accessibilityValue: String {
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }.count
        let approvals = host.snapshot.approvalAsks.count
        var bits: [String] = []
        if live > 0 { bits.append("\(live) in flight") }
        if approvals > 0 { bits.append("\(approvals) awaiting approval") }
        return bits.isEmpty ? "Idle" : bits.joined(separator: ", ")
    }
}
