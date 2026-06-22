import SwiftUI
import OpenBurnBarCore

// MARK: - Pets Settings View

struct PetsSettingsView: View {
    @Bindable var settingsManager: SettingsManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                enableSection
                petSelectionSection
                sizeSection
                chatBubbleSection
                positionSection
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Enable / Disable

    private var enableSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Desktop Pet")

            SettingsToggle(
                title: "Show Desktop Pet",
                subtitle: "A floating companion that sits on your screen and shows the latest chat response as a TLDR bubble.",
                icon: "pawprint.fill",
                isOn: Binding(
                    get: { settingsManager.pets.petEnabled },
                    set: { settingsManager.pets.petEnabled = $0 }
                )
            )
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
            )
        }
    }

    // MARK: - Pet Selection

    private var petSelectionSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Choose Your Pet")

            Text("Pick a companion that floats on your desktop. Drag the pet to reposition it. Long-press or right-click the pet for quick options.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            LazyVGrid(columns: gridColumns, spacing: DesignSystem.Spacing.md) {
                ForEach(DesktopPetKind.allCases) { kind in
                    petSelectionCard(kind)
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: DesignSystem.Spacing.md), count: 3)
    }

    private func petSelectionCard(_ kind: DesktopPetKind) -> some View {
        let isSelected = settingsManager.pets.selectedPet == kind
        let petColor = colorFor(kind.accentColor)

        return Button {
            settingsManager.pets.selectedPet = kind
        } label: {
            VStack(spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [petColor.opacity(0.3), Color.clear],
                                center: .center,
                                startRadius: 12,
                                endRadius: 32
                            )
                        )
                        .frame(width: 64, height: 64)

                    Circle()
                        .fill(petColor.gradient.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.3), petColor.opacity(0.5)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )

                    Image(systemName: kind.sfSymbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }

                VStack(spacing: 2) {
                    Text(kind.displayName)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(kind.detailText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isSelected {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(petColor)
                        Text("Selected")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(petColor)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected
                          ? petColor.opacity(0.08)
                          : DesignSystem.Colors.surface.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                            .strokeBorder(
                                isSelected
                                ? LinearGradient(colors: [petColor.opacity(0.6), petColor.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [DesignSystem.Colors.border.opacity(0.3), DesignSystem.Colors.border.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: isSelected ? 1.5 : 0.75
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!settingsManager.pets.petEnabled)
        .opacity(settingsManager.pets.petEnabled ? 1 : 0.5)
    }

    // MARK: - Size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Pet Size")

            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Slider(value: Binding(
                    get: { settingsManager.pets.petSize },
                    set: { settingsManager.pets.petSize = $0 }
                ), in: 48...128, step: 4)

                Image(systemName: "circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Text("\(Int(settingsManager.pets.petSize))px")
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
            )
        }
    }

    // MARK: - Chat Bubble

    private var chatBubbleSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Chat Bubble")

            SettingsToggle(
                title: "Show TLDR Chat Bubble",
                subtitle: "A small bubble above the pet showing the latest AI response in plain English.",
                icon: "bubble.left.fill",
                isOn: Binding(
                    get: { settingsManager.pets.chatBubbleEnabled },
                    set: { settingsManager.pets.chatBubbleEnabled = $0 }
                )
            )

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Full Chat Opens In")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Text("When you click the ellipses (...) on the chat bubble, the full chat opens here. Your choice is remembered.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                HStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(PetChatDestination.allCases) { dest in
                        destinationPicker(dest)
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.4))
        )
    }

    private func destinationPicker(_ dest: PetChatDestination) -> some View {
        let isSelected = settingsManager.pets.preferredChatDestination == dest
        return Button {
            settingsManager.pets.preferredChatDestination = dest
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: dest.sfSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? petColor : DesignSystem.Colors.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dest.displayName)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(dest.detailText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(petColor)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(isSelected
                          ? petColor.opacity(0.08)
                          : DesignSystem.Colors.surface.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .strokeBorder(isSelected ? petColor.opacity(0.4) : DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Position

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsSectionHeader(title: "Position")

            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("Drag the pet on your screen to reposition it. The position is saved automatically.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if settingsManager.pets.petPositionX >= 0 {
                Text("Current: \(Int(settingsManager.pets.petPositionX)), \(Int(settingsManager.pets.petPositionY))")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Button("Reset Position") {
                settingsManager.pets.petPositionX = -1
                settingsManager.pets.petPositionY = -1
                NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
            }
            .buttonStyle(.bordered)
            .tint(petColor)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.4))
        )
    }

    // MARK: - Helpers

    private var petColor: Color {
        colorFor(settingsManager.pets.selectedPet.accentColor)
    }

    private func colorFor(_ name: String) -> Color {
        switch name {
        case "ember":         return DesignSystem.Colors.ember
        case "hermesMercury": return DesignSystem.Colors.hermesMercury
        case "whimsy":        return DesignSystem.Colors.whimsy
        case "teal":          return DesignSystem.Colors.teal
        case "blaze":         return DesignSystem.Colors.blaze
        case "frost":         return DesignSystem.Colors.frost
        case "amber":         return DesignSystem.Colors.amber
        default:              return DesignSystem.Colors.ember
        }
    }
}
