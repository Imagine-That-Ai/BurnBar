import SwiftUI
import OpenBurnBarCore

// MARK: - Device Icon Picker

struct DeviceIconPicker: View {
    let deviceId: String
    let currentIcon: String
    var dataStore: DataStore
    var onDismiss: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: DesignSystem.Spacing.sm), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Device Icon")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }

            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.sm) {
                ForEach(DeviceHardwareIcon.allIcons, id: \.symbol) { item in
                    let isSelected = currentIcon == item.symbol
                    Button {
                        Task { @MainActor in
                            try? await dataStore.updateDeviceIcon(deviceId: deviceId, customIcon: item.symbol)
                            onDismiss()
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(isSelected ? DesignSystem.Colors.teal : DesignSystem.Colors.textPrimary)
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .fill(isSelected ? DesignSystem.Colors.teal.opacity(0.15) : DesignSystem.Colors.surfaceElevated)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? DesignSystem.Colors.teal.opacity(0.5) : DesignSystem.Colors.border.opacity(0.3),
                                            lineWidth: isSelected ? 1.5 : 0.5
                                        )
                                )
                            Text(item.label)
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                Task { @MainActor in
                    try? await dataStore.updateDeviceIcon(deviceId: deviceId, customIcon: nil)
                    onDismiss()
                }
            } label: {
                Text("Reset to Auto")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 220)
        .background(DesignSystem.Colors.surface)
    }
}
