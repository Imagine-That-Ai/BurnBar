import SwiftUI
import OpenBurnBarCore

// MARK: - Mobile Mission FAB (iOS)
//
// Draggable Mission Console launcher. Sibling to `ChartStudioFloatingButton`.
//
// Two modes, morphing with spring physics:
//   • Collapsed — 56pt living gauge. When idle, shows the compass glyph.
//     When live, the gauge face renders a tiny mono snippet of the
//     current activity so the surface is never silent.
//   • Expanded — ~260×56pt honest capsule. Left edge shows the runtime
//     call-sign badge (CLD, CDX, HRM) in provider color. Center shows
//     the actual tool icon + specific action text (file path, grep query,
//     LLM response preview). Right edge shows a 20pt mini progress ring.
//
// The capsule auto-expands when missions go live and auto-collapses after
// 4s of quiescence. During drag it snaps to compact so it doesn't fight
// the user's finger. Text cycles through active missions every 2.5s with
// a gentle cross-fade + 4pt vertical slide. New events trigger a breath
// (scale 1 → 1.02 → 1) so the surface feels alive.
//
// Colors are honest to the activity: amber for tooling, teal for LLM
// streaming, ember for errors / blocked, hermes-aureate for approval,
// success for completed-only. The gradient border shifts smoothly.
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
    @State private var isExpanded: Bool = false
    @State private var cycleIndex: Int = 0
    @State private var breath: Bool = false
    @State private var lastEventCount: Int = 0
    @State private var cycleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let fabSize: CGFloat = 56
    private let expandedWidth: CGFloat = 260

    var body: some View {
        GeometryReader { geo in
            let safeArea = geo.safeAreaInsets
            let bounds = geo.size
            ZStack {
                if isVisible {
                    capsule
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
            startBreath()
            startCycle()
        }
        .onDisappear {
            cycleTask?.cancel()
        }
        .onChange(of: host.snapshot.recentTicker.count) { oldValue, newValue in
            if newValue > oldValue {
                breathPulse()
            }
        }
        .onChange(of: liveMissions.isEmpty) { _, isEmpty in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                isExpanded = !isEmpty
            }
        }
    }

    // MARK: - Capsule body

    @ViewBuilder
    private var capsule: some View {
        if isExpanded && !liveMissions.isEmpty && dragOffset == .zero {
            expandedCapsule
        } else {
            compactGauge
        }
    }

    // MARK: Expanded — honest live capsule

    private var expandedCapsule: some View {
        let frame = currentFrame
        return Button(action: onTap) {
            HStack(spacing: 0) {
                // Runtime badge
                runtimeBadge(for: frame.runtimeCallSign, color: frame.accentColor)
                    .padding(.leading, 14)

                // Divider
                Rectangle()
                    .fill(frame.accentColor.opacity(0.25))
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 10)

                // Icon + honest text
                HStack(spacing: 6) {
                    Image(systemName: frame.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(frame.accentColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: frame.phase == .awaitingApproval && !reduceMotion)

                    Text(frame.honestText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                // Mini progress ring
                MiniProgressRing(
                    progress: frame.progress,
                    color: frame.accentColor,
                    size: 20
                )
                .padding(.trailing, 14)
            }
            .frame(width: expandedWidth, height: fabSize)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        frame.accentColor.opacity(0.85),
                                        frame.accentColor.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.2
                            )
                    )
            )
            .shadow(color: Color.black.opacity(0.40), radius: 16, x: 0, y: 6)
            .scaleEffect(breath ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: frame.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: breath)
        .accessibilityLabel("Mission Console. \(frame.honestText)")
        .accessibilityHint("Tap to open the Mission Control Console. Drag to reposition.")
    }

    // MARK: Collapsed — living gauge

    private var compactGauge: some View {
        Button(action: onTap) {
            ZStack {
                // Halo behind the bubble
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
            .frame(width: fabSize, height: fabSize)
            .scaleEffect(hasAppeared ? (breath ? 1.03 : 1.0) : 0.001)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mission Console")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to open the Mission Control Console. Drag to reposition.")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasAppeared)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: breath)
    }

    // MARK: - Frame builder (cycles through live missions)

    private var liveMissions: [MissionConsoleActiveTile] {
        host.snapshot.activeTiles.filter { $0.phase.isLive }
    }

    private var currentFrame: LiveMissionFrame {
        let tiles = liveMissions
        guard !tiles.isEmpty else {
            return LiveMissionFrame(
                id: "idle",
                runtimeCallSign: "",
                accentColor: UnifiedDesignSystem.Colors.textMuted,
                iconName: "compass.drawing",
                honestText: "Idle",
                phase: .queued,
                progress: 0
            )
        }
        let idx = min(cycleIndex, max(0, tiles.count - 1))
        let tile = tiles[idx]
        return frame(for: tile)
    }

    private func frame(for tile: MissionConsoleActiveTile) -> LiveMissionFrame {
        let accent = accentColor(for: tile)
        let (icon, text) = honestLabel(for: tile)
        let progress = tile.progressFraction ?? 0.5
        let callSign = runtimeCallSign(for: tile.runtimeID)
        return LiveMissionFrame(
            id: tile.id,
            runtimeCallSign: callSign,
            accentColor: accent,
            iconName: icon,
            honestText: text,
            phase: tile.phase,
            progress: progress
        )
    }

    private struct LiveMissionFrame: Equatable {
        let id: String
        let runtimeCallSign: String
        let accentColor: Color
        let iconName: String
        let honestText: String
        let phase: MissionConsoleActiveTile.Phase
        let progress: Double
    }

    // MARK: Honest label derivation

    private func honestLabel(for tile: MissionConsoleActiveTile) -> (icon: String, text: String) {
        // Prefer the actual latest ticker event for this mission
        let latestTicker = host.snapshot.recentTicker
            .first { $0.missionID == tile.id }

        if let ticker = latestTicker {
            switch ticker.kind {
            case .toolCall:
                let name = ticker.toolName ?? tile.currentToolName ?? "Tool"
                let detail = ticker.pathDetail?.split(separator: "/").last.map(String.init)
                    ?? ticker.message.split(separator: " ").prefix(3).joined(separator: " ")
                return ("hammer.fill", "\(name) · \(detail)")
            case .toolResult:
                let name = ticker.toolName ?? "Tool"
                let detail = ticker.pathDetail?.split(separator: "/").last.map(String.init)
                    ?? "done"
                return ("checkmark.circle.fill", "\(name) · \(detail)")
            case .llmResponse:
                let preview = ticker.message
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(28)
                    .description
                return ("quote.bubble.fill", "\"\(preview)\"")
            case .approval:
                return ("hand.raised.fill", "Approval · \(ticker.message.prefix(24))")
            case .error:
                return ("exclamationmark.triangle.fill", "Error · \(ticker.message.prefix(24))")
            case .changedFile:
                let file = ticker.pathDetail?.split(separator: "/").last.map(String.init) ?? "file"
                return ("doc.badge.gearshape.fill", "Edited · \(file)")
            case .artifact:
                return ("cube.fill", "Artifact · \(ticker.message.prefix(24))")
            default:
                break
            }
        }

        // Fallback to tile fields
        if tile.approvalPending {
            return ("hand.raised.fill", "Approval · \(tile.title.prefix(24))")
        }
        if let tool = tile.currentToolName {
            let detail = tile.phaseDetail?.prefix(24) ?? tile.lastEventSnippet?.prefix(24) ?? ""
            return ("hammer.fill", "\(tool) · \(detail)")
        }
        if let snippet = tile.lastEventSnippet {
            return ("sparkles", snippet.prefix(32).description)
        }
        return ("sparkles", tile.phase.displayLabel)
    }

    private func accentColor(for tile: MissionConsoleActiveTile) -> Color {
        if tile.approvalPending { return UnifiedDesignSystem.Colors.hermesAureate }
        switch tile.phase {
        case .failed, .blocked: return UnifiedDesignSystem.Colors.ember
        case .tooling: return UnifiedDesignSystem.Colors.amber
        case .streaming: return UnifiedDesignSystem.Colors.whimsy
        case .queued, .starting: return UnifiedDesignSystem.Colors.textSecondary
        default: return UnifiedDesignSystem.Colors.amber
        }
    }

    private func runtimeCallSign(for runtimeID: MissionConsoleRuntime.ID?) -> String {
        guard let id = runtimeID else { return "AUTO" }
        let runtime = host.snapshot.runtimes.first { $0.id == id }
        return runtime?.callSign ?? id.uppercased().prefix(3).description
    }

    // MARK: Runtime badge

    private func runtimeBadge(for callSign: String, color: Color) -> some View {
        Text(callSign)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(color.opacity(0.14))
                    .overlay(
                        Capsule()
                            .stroke(color.opacity(0.45), lineWidth: 0.5)
                    )
            }
    }

    // MARK: Gauge configuration

    private var gaugeConfiguration: MissionFABGauge.Configuration {
        let live = liveMissions
        let snippet = live.first.flatMap { tile -> String? in
            let (_, text) = honestLabel(for: tile)
            return text
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

    private var haloColor: Color {
        if host.snapshot.health.daemonState == .macOffline {
            return UnifiedDesignSystem.Colors.textMuted
        }
        if host.snapshot.approvalAsks.count > 0 {
            return UnifiedDesignSystem.Colors.hermesAureate
        }
        let blocked = host.snapshot.activeTiles.contains { $0.phase == .blocked || $0.phase == .failed }
        if blocked { return UnifiedDesignSystem.Colors.ember }
        if !liveMissions.isEmpty {
            return liveMissions.first.map { accentColor(for: $0) } ?? UnifiedDesignSystem.Colors.amber
        }
        return UnifiedDesignSystem.Colors.hermesAureate
    }

    private var accessibilityValue: String {
        let live = liveMissions.count
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
                withAnimation(.easeOut(duration: 0.15)) {
                    dragOffset = value.translation
                    isExpanded = false
                }
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
                    isExpanded = !liveMissions.isEmpty
                }
            }
    }

    // MARK: Position math

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

    // MARK: Animation lifecycle

    private func startBreath() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    private func breathPulse() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            breath = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                breath = false
            }
        }
    }

    private func startCycle() {
        cycleTask?.cancel()
        cycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !liveMissions.isEmpty else { continue }
                withAnimation(.easeInOut(duration: 0.25)) {
                    cycleIndex = (cycleIndex + 1) % max(1, liveMissions.count)
                }
            }
        }
    }
}

// MARK: - Mini progress ring

private struct MiniProgressRing: View {
    let progress: Double
    let color: Color
    let size: CGFloat

    private var lineWidth: CGFloat { size / 8 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: progress)
        }
        .frame(width: size, height: size)
    }
}
