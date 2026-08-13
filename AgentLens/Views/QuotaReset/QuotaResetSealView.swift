import SwiftUI
import OpenBurnBarCore

struct QuotaResetSealView: View {
    let event: QuotaResetEvent
    var compact: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: SealPhase = .idle
    @State private var displayedPercent: Double = 0

    private var provider: AgentProvider {
        AgentProvider.fromPersistedToken(event.providerToken)
            ?? AgentProvider.fromProviderID(event.providerID)
            ?? .codex
    }

    private var palette: QuotaResetPalette {
        .resolved(for: provider, kind: event.kind, colorScheme: colorScheme)
    }

    private var sealSize: CGFloat { compact ? 92 : 124 }

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            ZStack {
                atmosphere
                seal
                objectOverlay
            }
            .frame(width: sealSize + 36, height: sealSize + 36)

            VStack(spacing: 4) {
                Text(event.captionEyebrow)
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.1)
                    .foregroundStyle(palette.metal)
                Text(event.captionHeadline)
                    .font(compact ? DesignSystem.Typography.headline : DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
        }
        .onAppear(perform: play)
        .onChange(of: event.resetBoundary) { _, _ in
            play()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.captionEyebrow). \(event.captionHeadline)")
    }

    private var seal: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [palette.fill.opacity(0.55), palette.ring.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 8,
                        endRadius: sealSize / 2
                    )
                )
                .frame(width: sealSize, height: sealSize)
                .scaleEffect(phase == .slam ? 1.08 : 1.0)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [palette.metal, palette.ring, palette.metal.opacity(0.4), palette.metal],
                        center: .center
                    ),
                    lineWidth: compact ? 3 : 4
                )
                .frame(width: sealSize, height: sealSize)
                .shadow(color: palette.dust, radius: phase == .idle ? 6 : 16)

            ProviderLogoView(provider: provider, size: compact ? 36 : 46, useFallbackColor: false)
                .clipShape(Circle())
                .scaleEffect(phase == .reveal ? 1.06 : 1.0)

            Text(percentText)
                .font(.system(size: compact ? 13 : 16, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .offset(y: compact ? 28 : 36)
                .opacity(event.kind == .bankedGrant ? 0 : 1)
        }
    }

    @ViewBuilder
    private var objectOverlay: some View {
        switch event.choreography {
        case .plungerSlam, .tiboHand, .doubleTap:
            Image(systemName: "hand.point.down.fill")
                .font(.system(size: compact ? 22 : 28, weight: .bold))
                .foregroundStyle(palette.metal)
                .offset(y: phase == .slam ? 8 : -28)
                .opacity(phase == .idle ? 0 : 1)
        case .foilCard, .bankerStamp:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "F3E0A8"), Color(hex: "C9A04A"), Color(hex: "F7E7B4")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    Text(event.kind == .bankedRedeem ? "REDEEMED" : "RESET")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Color(hex: "3B2A08"))
                }
                .frame(width: compact ? 54 : 68, height: compact ? 34 : 42)
                .rotation3DEffect(.degrees(phase == .reveal ? 0 : 80), axis: (x: 0, y: 1, z: 0))
                .offset(y: phase == .reveal ? 42 : 8)
        case .calendarTear, .clockStrike, .moonCycle, .emberRekindle:
            Image(systemName: event.choreography == .clockStrike ? "clock.fill" : "sun.horizon.fill")
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(palette.metal)
                .offset(y: -sealSize / 2 + 4)
                .opacity(phase == .reveal ? 1 : 0.35)
        case .dashboardFall, .vaultFlood, .hourglassFlip:
            EmptyView()
        }
    }

    private var atmosphere: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                guard !reduceMotion else { return }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let count = event.kind == .surprise ? 18 : 10
                for index in 0..<count {
                    let seed = Double((event.resetBoundary.hashValue &+ index) & 0xFFFF)
                    let angle = (seed / 6_000) + t * (event.kind == .surprise ? 1.8 : 0.55)
                    let radius = 18 + (seed.truncatingRemainder(dividingBy: 28))
                    let point = CGPoint(
                        x: size.width / 2 + CGFloat(cos(angle) * radius),
                        y: size.height / 2 + CGFloat(sin(angle) * radius * 0.72)
                    )
                    let rect = CGRect(x: point.x, y: point.y, width: 2.2, height: 2.2)
                    context.fill(Path(ellipseIn: rect), with: .color(palette.dust))
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(reduceMotion ? 0 : 1)
    }

    private var percentText: String {
        let value = event.kind == .bankedGrant
            ? Int(event.previousUsedPercent ?? 0)
            : Int(displayedPercent.rounded())
        return "\(max(0, min(100, value)))%"
    }

    private func play() {
        displayedPercent = event.previousUsedPercent ?? 80
        phase = .idle
        let spring: Animation = event.kind == .surprise
            ? .spring(response: 0.28, dampingFraction: 0.52)
            : DesignSystem.Animation.gentle
        if reduceMotion {
            displayedPercent = event.currentUsedPercent ?? 0
            phase = .reveal
            return
        }
        withAnimation(spring) {
            phase = .slam
        }
        withAnimation(.easeOut(duration: 0.9).delay(0.18)) {
            displayedPercent = event.kind == .bankedGrant
                ? (event.previousUsedPercent ?? displayedPercent)
                : (event.currentUsedPercent ?? 0)
            phase = .reveal
        }
    }

    private enum SealPhase {
        case idle
        case slam
        case reveal
    }
}
