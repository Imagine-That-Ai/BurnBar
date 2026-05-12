import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant State Banner
//
// Single SwiftUI surface used by both Hermes and Pi conversation lists +
// settings cards to surface the eight runtime states from Plan 2 §9. Keeps
// the copy in one place so updates flow to every entry point at once.

struct AssistantStateBanner: View {
    enum State {
        case ok
        case noHosts
        case hostOffline(lastSeen: Date?)
        case relayUnavailable
        case noEntitlement
        case piCLIMissing
        case noPiInstances
        case pairingExpired
        case selectedHostRevoked
    }

    let runtime: AssistantRuntimeID
    let state: State
    var onAction: (() -> Void)?

    var body: some View {
        if let copy = renderCopy() {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                Image(systemName: copy.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(copy.tint)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(copy.title)
                        .font(MobileTheme.Typography.caption.bold())
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(copy.detail)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let actionLabel = copy.actionLabel, let onAction {
                    Button(actionLabel, action: onAction)
                        .font(MobileTheme.Typography.caption.bold())
                        .buttonStyle(.plain)
                        .foregroundStyle(copy.tint)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .background(MobileTheme.Colors.surface.opacity(0.85))
            .overlay(
                Rectangle()
                    .fill(MobileTheme.Colors.border.opacity(0.35))
                    .frame(height: 0.5),
                alignment: .bottom
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(copy.title). \(copy.detail)")
        } else {
            EmptyView()
        }
    }

    // MARK: - Copy

    private struct Copy {
        let symbol: String
        let title: String
        let detail: String
        let actionLabel: String?
        let tint: Color
    }

    private func renderCopy() -> Copy? {
        let runtimeName = runtime.displayName
        switch state {
        case .ok:
            return nil
        case .noHosts:
            return Copy(
                symbol: "antenna.radiowaves.left.and.right.slash",
                title: "No \(runtimeName) hosts yet",
                detail: "Pair from your Mac or add a direct URL to get started.",
                actionLabel: "Change Host",
                tint: MobileTheme.Colors.warning
            )
        case .hostOffline(let lastSeen):
            return Copy(
                symbol: "wifi.exclamationmark",
                title: "\(runtimeName) host offline",
                detail: lastSeen.map { "Last seen \(Self.relative($0)). Wake on Mac." }
                    ?? "Wake your Mac to bring this host back online.",
                actionLabel: "Change Host",
                tint: MobileTheme.Colors.warning
            )
        case .relayUnavailable:
            return Copy(
                symbol: "lock.shield",
                title: "Remote Relay needs OpenBurnBar Cloud",
                detail: "Upgrade to use \(runtimeName) over the network.",
                actionLabel: "Upgrade",
                tint: MobileTheme.hermesAureate
            )
        case .noEntitlement:
            return Copy(
                symbol: "lock.shield",
                title: "OpenBurnBar Cloud required",
                detail: "Subscribe to chat with \(runtimeName) over Remote Relay.",
                actionLabel: "Upgrade",
                tint: MobileTheme.hermesAureate
            )
        case .piCLIMissing:
            return Copy(
                symbol: "terminal",
                title: "Pi CLI not installed",
                detail: "Install the Pi CLI on your Mac to host this runtime.",
                actionLabel: "Help",
                tint: MobileTheme.Colors.warning
            )
        case .noPiInstances:
            return Copy(
                symbol: "circle.hexagongrid.fill",
                title: "Pi gateway is up — no instances",
                detail: "Register a Pi instance on your Mac to start chatting.",
                actionLabel: "Change Host",
                tint: MobileTheme.amber
            )
        case .pairingExpired:
            return Copy(
                symbol: "hourglass",
                title: "Pairing expired",
                detail: "Restart pairing from your Mac to reconnect this host.",
                actionLabel: "Change Host",
                tint: MobileTheme.Colors.warning
            )
        case .selectedHostRevoked:
            return Copy(
                symbol: "xmark.shield",
                title: "Host revoked",
                detail: "This host was removed from another device.",
                actionLabel: "Change Host",
                tint: MobileTheme.Colors.error
            )
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
