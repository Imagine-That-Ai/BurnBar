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
// Drag: shrinks to 0.92, dims to 0.7, ring pauses. Spring snap on release.
// Tap: opens the Mission Console sheet where full detail lives.
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
    @State private var orbitRotation: Double = 0
    @State private var glowPulse: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fabSize: CGFloat = 56
    private let orbitSize: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let bounds = geo.size
            ZStack {
                if isVisible {
                    orbButton
                        .position(positionFor(bounds: bounds, safeArea: safeArea))
                        .gesture(dragGesture(bounds: bounds, safeArea: safeArea))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(isVisible)
        .onAppear {
            hasAppeared = true
            startOrbitalAnimation()
        }
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
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: fabSize, height: fabSize)
                    .overlay(
                        Circle()
                            .stroke(
                                state.isActive
                                    ? AngularGradient(
                                        gradient: Gradient(colors: [
                                            state.accent.opacity(0.9),
                                            state.accent.opacity(0.3),
                                            state.accent.opacity(0.9)
                                        ]),
                                        center: .center,
                                        startAngle: .degrees(-90),
                                        endAngle: .degrees(270)
                                    )
                                    : Color.white.opacity(0.12),
                                lineWidth: state.isActive ? 1.5 : 0.8
                            )
                    )
                    .shadow(
                        color: state.isActive
                            ? state.accent.opacity(0.25)
                            : Color.black.opacity(0.25),
                        radius: state.isActive ? 16 : 10,
                        x: 0,
                        y: state.isActive ? 6 : 4
                    )

                // Orbiting dashed ring when active
                if state.isActive && !isDragging && !reduceMotion {
                    orbitingRing(accent: state.accent)
                }

                // Center content
                centerContent(state: state)
            }
            .frame(width: fabSize, height: fabSize)
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

        // Derive honest one-word label from actual event or tile
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

        // Clamp label to one word / short phrase that fits
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

    // MARK: - Drag

    private func dragGesture(bounds: CGSize, safeArea: EdgeInsets) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                isDragging = false
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

    private var accessibilityValue: String {
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }.count
        let approvals = host.snapshot.approvalAsks.count
        var bits: [String] = []
        if live > 0 { bits.append("\(live) in flight") }
        if approvals > 0 { bits.append("\(approvals) awaiting approval") }
        return bits.isEmpty ? "Idle" : bits.joined(separator: ", ")
    }
}
