import SwiftUI
import OpenBurnBarIrohRelay

/// Signed keep-awake switch for You (iPhone) and the iPad You rail.
///
/// The toggle is the sticky phone hold. A live Watch / Mirror / iroh
/// session can still keep the Mac awake without this switch. Lock,
/// loginwindow, and panic-on-sleep are not overridden.
struct KeepAwakeHostCard: View {
    @ObservedObject var client: HostReachabilityClient

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Toggle(isOn: phoneToggleBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Mac awake")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text(statusDetail)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(MobileTheme.ember)
            .accessibilityIdentifier("you.keepAwake.toggle")
            .accessibilityLabel("Keep Mac awake")
            .accessibilityHint("Asks the paired Mac to stay a host. Display may sleep. Lock and panic still win.")
            .accessibilityValue(client.desiredPhoneToggleEnabled ? "On" : "Off")

            HostReachabilityStatusLine(status: client.status)

            if let toggleError = client.toggleError {
                Text(toggleError)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.error)
                    .accessibilityIdentifier("you.keepAwake.error")
            }

            Text("Does not disable lid-close sleep and does not talk to the daemon.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.8))
        }
        .accessibilityIdentifier("you.keepAwake.card")
    }

    private var phoneToggleBinding: Binding<Bool> {
        Binding(
            get: { client.desiredPhoneToggleEnabled },
            set: { client.setPhoneToggle($0) }
        )
    }

    private var statusDetail: String {
        if client.desiredPhoneToggleEnabled {
            return "This device asked the Mac to stay a host. Display may sleep. Lock and panic still win."
        }
        if client.status.isAwake {
            return "A live session is holding the Mac awake. Flip this to keep it a host after the session ends."
        }
        return "The Mac can idle-sleep. A live Watch or Mirror session wakes it automatically."
    }
}

/// The one way host reachability reads on every surface — You, the iPad Watch
/// inspector footer, and the iPad sidebar. Keeping it here stops the wording
/// ("Mac awake" vs "Host awake") from drifting per surface.
struct HostReachabilityStatusLine: View {
    let status: HostReachabilityStatus
    var opacity: Double = 1

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status.isAwake ? MobileTheme.success : MobileTheme.warning)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.isAwake ? "Mac awake · last seen " : "Mac asleep · last seen ")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted.opacity(opacity))
            + Text(status.lastSeenAt, style: .relative)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted.opacity(opacity))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.isAwake ? "Mac awake" : "Mac asleep")
    }
}
