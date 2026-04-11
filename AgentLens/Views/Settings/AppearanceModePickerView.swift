import SwiftUI

// MARK: - Appearance Mode Picker

/// A styled picker for choosing the application appearance mode
struct AppearanceModePicker: View {
    @Binding var selection: AppearanceMode
    @Environment(\.colorScheme) private var colorScheme

    private struct ModeSpec {
        let mode: AppearanceMode
        let label: String
        let icon: String
        let bgHex: String
        let surfaceHex: String
        let elevatedHex: String
        let borderHex: String
        let textHex: String
        let textSecHex: String
        let accentHex: String
        let accent2Hex: String
    }

    /// DESIGN.md — Warm Charcoal (dark) & Botanical Cream (light); swatches match docs, not generic gray/white.
    private let specs: [ModeSpec] = [
        ModeSpec(
            mode: .dark, label: "Dark", icon: "moon.stars.fill",
            bgHex: "0E0D0B", surfaceHex: "171510", elevatedHex: "201E18",
            borderHex: "302C22", textHex: "F0EBE2", textSecHex: "9A9088",
            accentHex: "E87060", accent2Hex: "F0C040"
        ),
        ModeSpec(
            mode: .light, label: "Light", icon: "sun.max.fill",
            bgHex: "F3E8E6", surfaceHex: "FAF5F2", elevatedHex: "F5E8E4",
            borderHex: "E8BFB5", textHex: "2A1816", textSecHex: "6E4E48",
            accentHex: "F45B69", accent2Hex: "E86100"
        ),
        ModeSpec(
            mode: .system, label: "Auto", icon: "circle.lefthalf.filled",
            bgHex: "0E0D0B", surfaceHex: "171510", elevatedHex: "201E18",
            borderHex: "302C22", textHex: "F0EBE2", textSecHex: "9A9088",
            accentHex: "E87060", accent2Hex: "F0C040"
        ),
    ]

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ForEach(specs, id: \.mode) { spec in
                modeCard(spec)
            }
        }
    }

    private func modeCard(_ spec: ModeSpec) -> some View {
        let isSelected = selection == spec.mode

        return Button {
            withAnimation(DesignSystem.Animation.standard) {
                selection = spec.mode
            }
        } label: {
            VStack(spacing: DesignSystem.Spacing.sm) {
                swatchView(spec, isSelected: isSelected)
                    .frame(height: 72)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: spec.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            isSelected
                                ? DesignSystem.Colors.ember
                                : DesignSystem.Colors.textMuted
                        )
                    Text(spec.label)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(isSelected ? .semibold : .medium)
                        .foregroundStyle(
                            isSelected
                                ? DesignSystem.Colors.textPrimary
                                : DesignSystem.Colors.textSecondary
                        )
                }

                if isSelected {
                    Circle()
                        .fill(DesignSystem.Colors.primaryGradient)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(optionCardFill(selected: isSelected))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color(hex: spec.accentHex)
                            : Color(hex: spec.borderHex),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func swatchView(_ spec: ModeSpec, isSelected: Bool) -> some View {
        let bg = Color(hex: spec.bgHex)
        let surface = Color(hex: spec.surfaceHex)
        let elevated = Color(hex: spec.elevatedHex)
        let border = Color(hex: spec.borderHex)
        let text = Color(hex: spec.textHex)
        let textSec = Color(hex: spec.textSecHex)
        let accent = Color(hex: spec.accentHex)
        let accent2 = Color(hex: spec.accent2Hex)
        let contentPanel = isSelected ? accent.opacity(0.12) : surface

        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .fill(bg)
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(border.opacity(0.75), lineWidth: 0.5)
                    .padding(3)
            }
            .overlay {
                // Sidebar
                VStack(spacing: 0) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(text.opacity(0.88))
                            .frame(width: 5, height: 5)
                        Circle()
                            .fill(text.opacity(0.55))
                            .frame(width: 5, height: 5)
                        Circle()
                            .fill(textSec.opacity(0.35))
                            .frame(width: 5, height: 5)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(border.opacity(0.55))
                        .frame(width: 14, height: 2.5)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.leading, 6)
                .frame(width: 32)
                .background(surface)

                Rectangle()
                    .fill(divider)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(text.opacity(0.88))
                            .frame(width: 28, height: 4)
                        Spacer()
                        Circle()
                            .fill(accent)
                            .frame(width: 5, height: 5)
                    }

                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent, accent2],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(elevated)
                            .frame(height: 14)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(border.opacity(0.85), lineWidth: 0.5)
                            }
                    }

                    HStack(spacing: 3) {
                        cardSwatch(elevated: elevated, border: border, textSec: textSec)
                        cardSwatch(elevated: elevated, border: border, textSec: textSec)
                    }

                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(contentPanel)
            }
    }

    private var divider: Color {
        colorScheme == .dark ? Color(hex: "2A2820") : Color(hex: "D8CCC5")
    }

    private func optionCardFill(selected: Bool) -> Color {
        if selected {
            return colorScheme == .dark
                ? Color(hex: "1E1C18")
                : Color(hex: "F5E8E4")
        } else {
            return colorScheme == .dark
                ? Color(hex: "131210")
                : Color(hex: "F8F4F0")
        }
    }

    private func cardSwatch(elevated: Color, border: Color, textSec: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(elevated)
            .frame(height: 18)
            .overlay {
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(textSec.opacity(0.42))
                        .frame(width: 18, height: 2)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(textSec.opacity(0.22))
                        .frame(width: 14, height: 2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(border.opacity(0.75), lineWidth: 0.5)
            }
    }
}
