#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Mercury-stroked pill that surfaces during split/maximize to remind
/// the user their taps and typing are driving the Mac. Fades in on the
/// first touch and reappears after a 4-second input lull.
struct AgentLiveStageDrivingPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 12, weight: .bold))
            Text("YOU ARE DRIVING")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(MobileTheme.mercuryGradient, lineWidth: 1)
                )
        )
        .opacity(isActive ? 1 : 0)
        .scaleEffect(isActive ? 1 : 0.92)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.78),
                   value: isActive)
        .accessibilityLabel("You are driving the Mac")
    }
}

/// Compact monospaced capsule showing elapsed session time + action
/// counter. Mirrors the existing AgentWatchView top hairline but in a
/// floating-card form factor.
struct AgentLiveStageTelemetryCapsule: View {
    var startedAt: Date?
    var actionsExecuted: Int
    var trustMode: ComputerUseTrustMode

    @State private var now: Date = .now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(MobileTheme.success)
                .frame(width: 6, height: 6)
                .shadow(color: MobileTheme.success.opacity(0.45), radius: 3, y: 0)
            Text("LIVE")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(MobileTheme.success)
            Text(elapsedString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
            Divider()
                .frame(height: 9)
                .background(Color.white.opacity(0.18))
            Text("\(actionsExecuted)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            Text("acts")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Divider()
                .frame(height: 9)
                .background(Color.white.opacity(0.18))
            Text(trustMode.rawValue.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(trustTint)
                .tracking(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        )
        .onReceive(ticker) { value in now = value }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live mirror, \(elapsedString), \(actionsExecuted) actions, \(trustMode.rawValue) trust")
    }

    private var elapsedString: String {
        guard let startedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var trustTint: Color {
        switch trustMode {
        case .manual:  return MobileTheme.amber
        case .step:    return MobileTheme.warning
        case .trusted: return MobileTheme.success
        }
    }
}

/// Pending-approval stripe shared between the dock tile (compact form)
/// and the maximize layer (full-width form). Buttons route through the
/// caller so the action paths to `AgentWatchReceiver.approve(_:)` /
/// `reject(_:halt:)` aren't duplicated.
struct AgentLiveStageApprovalStripe: View {
    enum Style { case compact, expanded }

    var request: HermesRealtimeRelayApprovalRequest
    var style: Style = .expanded
    var onApprove: () -> Void
    var onReject: () -> Void
    var onRejectHalt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 6 : 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.warning)
                Text("APPROVAL NEEDED")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(MobileTheme.warning)
                Spacer(minLength: 0)
            }

            Text(request.actionSummary)
                .font(.system(size: style == .compact ? 11.5 : 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(style == .compact ? 2 : 4)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                Button(action: onRejectHalt) {
                    Text(style == .compact ? "Halt" : "Reject + Halt")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.error)

                Button(action: onReject) {
                    Text("Reject")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button(action: onApprove) {
                    Text("Approve")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(MobileTheme.success)
            }
        }
        .padding(.horizontal, style == .compact ? 10 : 14)
        .padding(.vertical, style == .compact ? 8 : 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.warning.opacity(0.6), lineWidth: 1)
                )
        )
    }
}

/// Single-line action ticker shown along the bottom of the dock tile.
/// Renders the most recent timeline entry with a mercury-glowing dot
/// while an action is executing.
struct AgentLiveStageActionTicker: View {
    var entry: HermesRealtimeRelayActionLogEntry?

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            Text(entry?.summary ?? "Waiting for the agent…")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(entry == nil ? 0.55 : 0.95))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .shadow(color: statusColor.opacity(0.55), radius: 3, y: 0)
    }

    private var statusColor: Color {
        switch entry?.status {
        case .executing:        return MobileTheme.amber
        case .completed:        return MobileTheme.success
        case .failed, .rejected, .panicHalted: return MobileTheme.error
        case .awaitingApproval: return MobileTheme.warning
        default:                return MobileTheme.textMuted
        }
    }
}
#endif
