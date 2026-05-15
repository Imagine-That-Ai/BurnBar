import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission FAB (iOS)
//
// Draggable Mission Console launcher. Sibling to `ChartStudioFloatingButton` —
// same drag/snap math, same nav-tray clearance, same Hermes mercury-aureate
// chrome. Wraps the shared `MissionFABGauge` so the face reflects live state
// (ticks per active mission, color by health, etc.).
//
// Hidden when Chart Studio is fullscreen.

struct MobileMissionFAB: View {
    @Bindable var host: MobileMissionConsoleHost
    var isVisible: Bool
    var anchorOffset: Binding<CGSize>
    var onTap: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var pulse: Bool = false
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fabSize: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let bounds = geo.size
            ZStack {
                if isVisible {
                    fab
                        .frame(width: fabSize, height: fabSize)
                        .position(positionFor(bounds: bounds, safeArea: safeArea))
                        .gesture(dragGesture(bounds: bounds, safeArea: safeArea))
                        .transition(
                            .scale(scale: 0.6).combined(with: .opacity)
                        )
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(isVisible)
        .onAppear {
            hasAppeared = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: FAB face

    private var fab: some View {
        Button(action: onTap) {
            ZStack {
                // Halo behind the bubble — color tinted by gauge state
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                haloColor.opacity(0.55),
                                haloColor.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: pulse ? 38 : 28
                        )
                    )
                    .frame(width: 96, height: 96)
                    .blur(radius: 9)
                    .opacity(pulse ? 0.95 : 0.6)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        haloColor.opacity(0.85),
                                        haloColor.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.0
                            )
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 5)

                MissionFABGauge(configuration: gaugeConfiguration)
                    .frame(width: fabSize - 12, height: fabSize - 12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mission Console")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to open the Mission Control Console. Drag to reposition.")
    }

    private var gaugeConfiguration: MissionFABGauge.Configuration {
        MissionFABGauge.Configuration(
            size: .standard,
            activeMissionCount: host.snapshot.activeTiles.filter { $0.phase.isLive }.count,
            approvalPendingCount: host.snapshot.approvalAsks.count,
            blockedCount: host.snapshot.activeTiles.filter { $0.phase == .blocked || $0.phase == .failed }.count,
            hasCompletedSinceLastOpen: host.snapshot.activeTiles.contains { $0.phase == .completed },
            burnSweep: min(1.0, host.snapshot.health.burnPerHourUSD / 3.0),
            burnPerHourUSD: host.snapshot.health.burnPerHourUSD,
            macOnline: host.snapshot.health.daemonState != .macOffline
        )
    }

    private var haloColor: Color {
        if host.snapshot.health.daemonState == .macOffline {
            return UnifiedDesignSystem.Colors.textMuted
        }
        if host.snapshot.approvalAsks.count > 0 {
            return UnifiedDesignSystem.Colors.hermesAureate
        }
        let blocked = host.snapshot.activeTiles.contains { $0.phase == .blocked || $0.phase == .failed }
        if blocked { return UnifiedDesignSystem.Colors.ember }
        if host.snapshot.activeTiles.contains(where: { $0.phase.isLive }) {
            return UnifiedDesignSystem.Colors.amber
        }
        return UnifiedDesignSystem.Colors.hermesAureate
    }

    private var accessibilityValue: String {
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }.count
        let approvals = host.snapshot.approvalAsks.count
        var bits: [String] = []
        if live > 0 { bits.append("\(live) in flight") }
        if approvals > 0 { bits.append("\(approvals) awaiting approval") }
        return bits.isEmpty ? "Idle" : bits.joined(separator: ", ")
    }

    // MARK: Drag

    private func dragGesture(bounds: CGSize, safeArea: EdgeInsets) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let newOffset = clampedOffset(
                    candidate: CGSize(
                        width: anchorOffset.wrappedValue.width + value.translation.width,
                        height: anchorOffset.wrappedValue.height + value.translation.height
                    ),
                    bounds: bounds,
                    safeArea: safeArea
                )
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    anchorOffset.wrappedValue = newOffset
                    dragOffset = .zero
                }
            }
    }

    // MARK: Position math (mirrors ChartStudioFloatingButton's pattern)

    private func positionFor(bounds: CGSize, safeArea: EdgeInsets) -> CGPoint {
        // Anchor: bottom-LEFT, just above the nav tray (so it doesn't fight
        // Chart Studio's bottom-right FAB by default).
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
}
