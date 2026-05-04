import SwiftUI
import OpenBurnBarCore

// MARK: - Connected Devices Row
//
// Renders the trusted-device set as a chip cluster with platform glyphs.
// Tapping the row opens device management.

struct ConnectedDevicesRow: View {
    let devices: [DeviceRecord]
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            AuroraGlassCard(variant: .standard, cornerRadius: 16, interactive: true) {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.connected.to.line.below")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MobileTheme.whimsy)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(MobileTheme.whimsy.opacity(0.16))
                        )
                        .symbolEffect(.bounce, value: devices.count)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected devices")
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(devicesSubtitle)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    Spacer()
                    deviceChips
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var devicesSubtitle: String {
        if devices.isEmpty {
            return "Tap to register this device"
        }
        let approved = devices.filter { $0.trustState == .trusted || $0.trustState == .current }.count
        return "\(approved) trusted · \(devices.count - approved) pending"
    }

    private var deviceChips: some View {
        let visible = Array(devices.prefix(4))
        return HStack(spacing: -8) {
            ForEach(visible) { device in
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 30, height: 30)
                    Circle()
                        .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
                        .frame(width: 30, height: 30)
                    Image(systemName: deviceIcon(device))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(deviceColor(device))
                }
            }
            if devices.count > 4 {
                ZStack {
                    Circle()
                        .fill(MobileTheme.Colors.surface)
                        .frame(width: 30, height: 30)
                    Text("+\(devices.count - 4)")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                }
            }
        }
    }

    private func deviceIcon(_ device: DeviceRecord) -> String {
        switch device.platform.lowercased() {
        case let p where p.contains("ios") || p.contains("iphone"): return "iphone"
        case let p where p.contains("ipad"): return "ipad"
        case let p where p.contains("mac"):  return "laptopcomputer"
        case let p where p.contains("watch"): return "applewatch"
        default: return "questionmark.circle"
        }
    }

    private func deviceColor(_ device: DeviceRecord) -> Color {
        switch device.trustState {
        case .trusted, .current: return MobileTheme.success
        case .pending: return MobileTheme.amber
        case .revoked: return MobileTheme.error
        }
    }
}
