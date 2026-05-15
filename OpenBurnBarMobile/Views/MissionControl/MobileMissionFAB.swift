import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission FAB (iOS)
//
// Small, elegant, honest. A 56pt living gauge that never expands into a
// bloated capsule. When idle it's a quiet compass glyph with a faint
// hermes-aureate halo. When live, the gauge face renders a tiny mono
// snippet of the actual current activity — tool names, file paths, or
// LLM response previews — at 7pt inside the 44pt gauge interior.
//
// Color shifts subtly by activity type:
//   • amber  — tooling (grep, edit, build)
//   • whimsy — LLM streaming / composing
//   • ember  — error / blocked
//   • hermesAureate — approval pending
//   • textMuted — idle / mac offline
//
// Motion is restrained: a 1.6s breathing halo glow when live, a quick
// 0.25s breath pulse on new events, and gentle spring snap on drag release.
// No text cycles, no cross-fades, no expanded states. The detail lives
// inside the console sheet, not on the FAB.
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
    @State private var breath: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fabSize: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let bounds = geo.size
            ZStack {
                if isVisible {
                    gaugeButton
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

    // MARK: - Gauge button (always 56pt)

    private var gaugeButton: some View {
        Button(action: onTap) {
            ZStack {
                // Breathing halo — subtle, never aggressive
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                haloColor.opacity(pulse ? 0.45 : 0.25),
                                haloColor.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: pulse ? 36 : 30
                        )
                    )
                    .frame(width: 88, height: 88)
                    .blur(radius: 8)

                // Material disc with thin gradient stroke
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        haloColor.opacity(0.75),
                                        haloColor.opacity(0.25)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.0
                            )
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)

                // Living gauge face — 44pt interior showing honest snippet when live
                MissionFABGauge(configuration: gaugeConfiguration)
                    .frame(width: fabSize - 12, height: fabSize - 12)
            }
            .frame(width: fabSize, height: fabSize)
            .scaleEffect(hasAppeared ? (breath ? 1.04 : 1.0) : 0.001)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mission Console")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to open the Mission Control Console. Drag to reposition.")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasAppeared)
        .animation(.spring(response: 0.20, dampingFraction: 0.75), value: breath)
    }

    // MARK: - Gauge configuration (honest snippet inside)

    private var gaugeConfiguration: MissionFABGauge.Configuration {
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }
        let snippet = live.first.flatMap { tile -> String? in
            honestMicroText(for: tile)
        }
        return MissionFABGauge.Configuration(
            size: .standard,
            activeMissionCount: live.count,
            approvalPendingCount: host.snapshot.approvalAsks.count,
            blockedCount: host.snapshot.activeTiles.filter { $0.phase == .blocked || $0.phase == .failed }.count,
            hasCompletedSinceLastOpen: host.snapshot.activeTiles.contains { $0.phase == .completed },
            burnSweep: min(1.0, host.snapshot.health.burnPerHourUSD / 3.0),
            burnPerHourUSD: host.snapshot.health.burnPerHourUSD,
            macOnline: host.snapshot.health.daemonState != .macOffline,
            liveSnippet: snippet
        )
    }

    // MARK: - Honest micro text (7–9pt, fits inside 44pt gauge)

    private func honestMicroText(for tile: MissionConsoleActiveTile) -> String? {
        let latest = host.snapshot.recentTicker.first { $0.missionID == tile.id }

        if let event = latest {
            switch event.kind {
            case .toolCall:
                let name = event.toolName ?? tile.currentToolName ?? "Tool"
                let file = event.pathDetail?.split(separator: "/").last.map(String.init)
                if let file { return "\(name) \(file)" }
                return name
            case .toolResult:
                let name = event.toolName ?? "Done"
                let file = event.pathDetail?.split(separator: "/").last.map(String.init)
                if let file { return "\(name) \(file)" }
                return name
            case .llmResponse:
                return event.message
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(22).description
            case .approval:
                return "Approve?"
            case .error:
                return "Error"
            case .changedFile:
                return event.pathDetail?.split(separator: "/").last.map(String.init)
            default:
                break
            }
        }

        if tile.approvalPending { return "Approve?" }
        if let tool = tile.currentToolName { return tool }
        if let snippet = tile.lastEventSnippet { return snippet.prefix(18).description }
        return nil
    }

    // MARK: - Halo color (shifts by state)

    private var haloColor: Color {
        if host.snapshot.health.daemonState == .macOffline {
            return UnifiedDesignSystem.Colors.textMuted
        }
        if host.snapshot.approvalAsks.count > 0 {
            return UnifiedDesignSystem.Colors.hermesAureate
        }
        if host.snapshot.activeTiles.contains(where: { $0.phase == .blocked || $0.phase == .failed }) {
            return UnifiedDesignSystem.Colors.ember
        }
        let live = host.snapshot.activeTiles.filter { $0.phase.isLive }
        if let first = live.first {
            if first.approvalPending { return UnifiedDesignSystem.Colors.hermesAureate }
            switch first.phase {
            case .failed, .blocked: return UnifiedDesignSystem.Colors.ember
            case .tooling: return UnifiedDesignSystem.Colors.amber
            case .streaming: return UnifiedDesignSystem.Colors.whimsy
            default: return UnifiedDesignSystem.Colors.amber
            }
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

    // MARK: - Drag

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
}
