import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Capability
//
// Shape of a single benefit. Each capability owns:
//   • a punchy headline written as a *user benefit*, not a feature.
//   • a measurable subtitle ("30/day · 300/month") so the value is concrete.
//   • a scenario paragraph that *shows*, not tells.
//   • a numbers table — the proof.
//   • a stagecraft visual the detail sheet renders so the user *sees* it
//     working before they commit.

struct CloudCapability: Identifiable, Hashable {
    let id: String
    let icon: String
    let headline: String          // user benefit headline
    let metric: String            // concrete measurable subtitle
    let scenario: String          // a "you are at the airport…" story
    let proofPoints: [ProofPoint] // 3 hard numbers / facts
    let stage: Stage              // which animated demo to show

    struct ProofPoint: Hashable {
        let label: String
        let value: String
    }

    enum Stage: String {
        case quotaRefresh
        case crossDeviceResume
        case sessionSearch
        case remoteRelay
    }

    static let all: [CloudCapability] = [
        .init(
            id: "hosted-codex",
            icon: "cloud.fill",
            headline: "Refresh your Codex quota from anywhere",
            metric: "30 refreshes / day · 300 / month · no laptop required",
            scenario: "You're at the airport. Codex is dry. You tap one button on your iPhone — our hosted runner refreshes your quota, signed in to your account, and pings you when it's ready. Your Mac stays asleep.",
            proofPoints: [
                .init(label: "DAILY",      value: "30 hosted refreshes"),
                .init(label: "MONTHLY",    value: "300 (rollover)"),
                .init(label: "AVG. TIME",  value: "12s end-to-end")
            ],
            stage: .quotaRefresh
        ),
        .init(
            id: "conversation-resume",
            icon: "arrow.triangle.2.circlepath",
            headline: "Pick up your chat on any device",
            metric: "iPhone → iPad → Mac · encrypted · sub-2-second sync",
            scenario: "You start a Hermes conversation on the train. Switch to your iPad at the café — every message, every tool call, every artefact is already there. Walk to your Mac. Same thread, same place in the scrollback.",
            proofPoints: [
                .init(label: "TRANSPORT",  value: "AES + Apple Sign-In"),
                .init(label: "SYNC",       value: "≈ 1.4s typical"),
                .init(label: "RETENTION",  value: "Full history kept")
            ],
            stage: .crossDeviceResume
        ),
        .init(
            id: "session-search",
            icon: "text.alignleft",
            headline: "Search every agent run, ever",
            metric: "Every tool call · every chunk · every cost line",
            scenario: "“What did Claude burn last Wednesday during the auth refactor?” Type `auth refactor` — your full session log returns in milliseconds. Tool calls, generated diffs, token spend per turn. Searchable, replayable, on every device.",
            proofPoints: [
                .init(label: "STORAGE",    value: "Encrypted at rest"),
                .init(label: "QUERY",      value: "< 200 ms on-device"),
                .init(label: "SCOPE",      value: "All sessions, forever")
            ],
            stage: .sessionSearch
        ),
        .init(
            id: "remote-relay",
            icon: "antenna.radiowaves.left.and.right",
            headline: "Your Mac's AI, anywhere on Earth",
            metric: "Verified WebSocket · App Check + Apple JWS · sub-200ms",
            scenario: "You're at a coffee shop, your laptop is asleep at home. From your phone, you wake your Mac's Hermes, ask it to refactor a file, and stream the answer back to your hand. End-to-end signed. Nothing leaves your devices unencrypted.",
            proofPoints: [
                .init(label: "TRUST",      value: "App Check + JWS"),
                .init(label: "LATENCY",    value: "≈ 180 ms typical"),
                .init(label: "FALLBACK",   value: "LAN if reachable")
            ],
            stage: .remoteRelay
        )
    ]
}

// MARK: - Capability Detail Sheet
//
// The "HOW it helps in practice" surface. Opens when a free user (or a
// curious member) taps a capability card. Lives on a `ProPosterScaffold`
// so the destination stays in the Pro world.

struct CapabilityDetailSheet: View {
    let capability: CloudCapability
    var ctaLabel: String
    let onCTA: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            EmberSurfaceBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    header
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .padding(.top, MobileTheme.Spacing.lg)

                    CapabilityStageView(stage: capability.stage)
                        .frame(height: 220)
                        .padding(.horizontal, MobileTheme.Spacing.lg)

                    scenarioCard
                        .padding(.horizontal, MobileTheme.Spacing.lg)

                    proofTable
                        .padding(.horizontal, MobileTheme.Spacing.lg)

                    Button {
                        Haptics.medium()
                        onCTA()
                    } label: {
                        Label(ctaLabel, systemImage: "sparkles")
                    }
                    .buttonStyle(.aurora(.primary, fullWidth: true))
                    .padding(.horizontal, MobileTheme.Spacing.lg)

                    Spacer(minLength: MobileTheme.Spacing.xl)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                ZStack {
                    Circle().fill(MobileTheme.Colors.surfaceElevated)
                    Circle().stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.9)
                    Image(systemName: capability.icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MobileTheme.ember)
                }
                .frame(width: 32, height: 32)
                Text("CLOUD CAPABILITY")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.bold)
                    .tracking(2.4)
                    .foregroundStyle(MobileTheme.ember)
            }
            Text(capability.headline)
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(capability.metric)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scenarioCard: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("HOW IT FEELS")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.bold)
                .tracking(2.4)
                .foregroundStyle(MobileTheme.ember)
            Text(capability.scenario)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.9)
        )
    }

    private var proofTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(capability.proofPoints.enumerated()), id: \.offset) { idx, pp in
                HStack {
                    Text(pp.label)
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .tracking(2.0)
                        .foregroundStyle(MobileTheme.ember)
                        .frame(width: 120, alignment: .leading)
                    Text(pp.value)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, MobileTheme.Spacing.md)
                if idx < capability.proofPoints.count - 1 {
                    Divider().background(MobileTheme.Colors.border.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.7)
        )
    }
}

// MARK: - Capability Stage
//
// Each capability gets its own tasteful demonstration. Pure SwiftUI; honors
// `accessibilityReduceMotion` by freezing on the steady-state frame.

struct CapabilityStageView: View {
    let stage: CloudCapability.Stage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.7)
            Group {
                switch stage {
                case .quotaRefresh:      QuotaRefreshStage(reduceMotion: reduceMotion)
                case .crossDeviceResume: CrossDeviceStage(reduceMotion: reduceMotion)
                case .sessionSearch:     SessionSearchStage(reduceMotion: reduceMotion)
                case .remoteRelay:       RemoteRelayStage(reduceMotion: reduceMotion)
                }
            }
            .padding(MobileTheme.Spacing.lg)
        }
    }
}

// MARK: - Stage: Quota Refresh

private struct QuotaRefreshStage: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0/24.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let cycle = (t.truncatingRemainder(dividingBy: 4.5)) / 4.5  // 0..1 every 4.5s
            let fill = min(1.0, max(0.05, cycle))

            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "iphone")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                    Text("CODEX QUOTA")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(MobileTheme.ember)
                    Spacer()
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(MobileTheme.ember)
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MobileTheme.Colors.surfaceElevated)
                        .frame(height: 28)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [MobileTheme.ember, MobileTheme.ember],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(20, UIScreen.main.bounds.width * 0.6 * CGFloat(fill)), height: 28)
                        .animation(.easeInOut(duration: 0.3), value: fill)
                }
                .overlay(
                    Capsule().stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.7)
                )

                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(MobileTheme.ember)
                    Text("Hosted refresh · \(Int(fill * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                    Text("12s avg")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
    }
}

// MARK: - Stage: Cross-Device Resume

private struct CrossDeviceStage: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0/24.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pos = (t.truncatingRemainder(dividingBy: 5.0)) / 5.0  // 0..1

            ZStack {
                // Three device icons
                HStack(spacing: 0) {
                    deviceIcon("iphone", label: "iPhone")
                    Spacer(minLength: 0)
                    deviceIcon("ipad", label: "iPad")
                    Spacer(minLength: 0)
                    deviceIcon("macbook", label: "Mac")
                }

                // Traveling foil pulse
                if !reduceMotion {
                    Circle()
                        .fill(MobileTheme.ember)
                        .frame(width: 8, height: 8)
                        .shadow(color: MobileTheme.ember, radius: 8)
                        .offset(x: (CGFloat(pos) - 0.5) * 220, y: 0)
                }
            }
        }
    }

    private func deviceIcon(_ name: String, label: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MobileTheme.Colors.surfaceElevated)
                    .frame(width: 64, height: 64)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MobileTheme.ember.opacity(0.45), lineWidth: 0.7)
                    .frame(width: 64, height: 64)
                Image(systemName: name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.75))
        }
    }
}

// MARK: - Stage: Session Search

private struct SessionSearchStage: View {
    let reduceMotion: Bool
    @State private var typed = ""
    private let target = "auth refactor"

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 0.18)) { ctx in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MobileTheme.ember)
                    Text(reduceMotion ? target : nextString(at: ctx.date))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("|").foregroundStyle(MobileTheme.ember.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated)
                )

                VStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack {
                            Image(systemName: i == 0 ? "doc.text.fill" : "doc.text")
                                .foregroundStyle(MobileTheme.ember.opacity(i == 0 ? 1 : 0.4))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(["auth-refactor.diff", "session-2026-05-08.log", "claude-handoff.md"][i])
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                Text(["Wed · 6h ago · 42k tokens", "Wed · 8h ago · 31k tokens", "Wed · 9h ago · 12k tokens"][i])
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.55))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(MobileTheme.Colors.surface.opacity(0.6))
                        )
                    }
                }
            }
        }
    }

    private func nextString(at date: Date) -> String {
        let cycle = Int(date.timeIntervalSinceReferenceDate * 4) % (target.count + 6)
        if cycle <= target.count { return String(target.prefix(cycle)) }
        return target
    }
}

// MARK: - Stage: Remote Relay

private struct RemoteRelayStage: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0/30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * 2.5) + 1) / 2

            HStack(spacing: 8) {
                deviceTile(icon: "iphone", label: "Phone")
                relayTrack(pulse: pulse)
                deviceTile(icon: "antenna.radiowaves.left.and.right", label: "Relay", highlight: true)
                relayTrack(pulse: pulse, reversed: true)
                deviceTile(icon: "macbook", label: "Mac")
            }
        }
    }

    private func deviceTile(icon: String, label: String, highlight: Bool = false) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(highlight ? MobileTheme.Colors.surfaceElevated : MobileTheme.Colors.surface)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MobileTheme.ember.opacity(0.45), lineWidth: highlight ? 1.2 : 0.7)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(highlight ? MobileTheme.ember : MobileTheme.Colors.textPrimary)
            }
            .frame(width: 64, height: 64)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(MobileTheme.Colors.textPrimary.opacity(0.75))
        }
    }

    private func relayTrack(pulse: Double, reversed: Bool = false) -> some View {
        // Hoist arithmetic to local lets so Swift's type-checker doesn't
        // have to resolve a 3-deep nested ternary + truncatingRemainder
        // chain at the modifier site (it times out on Xcode 26.x).
        let direction: Double = reversed ? -1 : 1
        let basePulse: Double = reversed ? (1 - pulse) : pulse
        return ZStack {
            Rectangle()
                .fill(MobileTheme.Colors.border.opacity(0.5))
                .frame(height: 1.2)
            ForEach(0..<3, id: \.self) { i in
                let stride = Double(i) * 0.3
                let opacityValue = (basePulse + stride).truncatingRemainder(dividingBy: 1.0)
                let offsetValue = direction * (((pulse + stride).truncatingRemainder(dividingBy: 1.0)) - 0.5) * 28
                Circle()
                    .fill(MobileTheme.ember)
                    .frame(width: 4, height: 4)
                    .opacity(opacityValue)
                    .offset(x: offsetValue)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview("Capability Detail") {
    NavigationStack {
        CapabilityDetailSheet(
            capability: CloudCapability.all[0],
            ctaLabel: "Become a Member",
            onCTA: {},
            onDismiss: {}
        )
    }
}
