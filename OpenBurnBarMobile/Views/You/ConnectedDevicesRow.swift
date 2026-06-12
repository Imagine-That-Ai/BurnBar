import SwiftUI
import OpenBurnBarCore

// MARK: - Connected Devices Row
//
// Renders the trusted-device set as a chip cluster with platform glyphs.
// Tapping the row opens device management.

struct ConnectedDevicesRow: View {
    let devices: [DeviceRecord]

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
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
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected devices")
        .accessibilityValue(devicesSubtitle)
        .accessibilityIdentifier("you.connectedDevices.row")
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
        // The chips overlap (spacing -8), so on iOS 26 they must share one
        // GlassEffectContainer — glass cannot sample other glass. Pre-26 the
        // group passes content through unchanged.
        return LiquidGlassGroup {
            HStack(spacing: -8) {
                ForEach(visible) { device in
                    ZStack {
                        // Passive glass badge. On iOS 26 the disc is pure
                        // Liquid Glass (no fill underneath, so it samples the
                        // real background); on iOS 17–25 the adapter falls
                        // back to the same ultra-thin material this chip
                        // always used.
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 30, height: 30)
                            .liquidGlassSurface(in: .circle)
                        Circle()
                            .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
                            .frame(width: 30, height: 30)
                        Image(systemName: deviceIcon(device))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(deviceColor(device))
                    }
                }
                overflowChip
            }
        }
    }

    /// Opaque "+N" overflow count badge. Deliberately NOT glass: it carries a
    /// text readout that overlaps the chip stack, and the opaque surface fill
    /// keeps the count legible over the chips beneath it.
    @ViewBuilder
    private var overflowChip: some View {
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
