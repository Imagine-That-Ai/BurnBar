import SwiftUI
import OpenBurnBarCore

// MARK: - UI Mode Picker
//
// Horizontal scrolling card grid for switching between UI modes.
// Each mode shows an icon, name, and brief description inside an
// Aurora-styled glass card. Selected state gets an accent stroke.

struct UIModePicker: View {
    @Binding var selection: String

    private var selectedMode: UIMode {
        UIMode(rawValue: selection) ?? .standard
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ForEach(UIMode.allCases) { mode in
                    modeCard(mode)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.sm)
        }
    }

    private func modeCard(_ mode: UIMode) -> some View {
        let isSelected = selectedMode == mode
        let theme = UIModeTheme(mode: mode)

        return Button {
            withAnimation(AuroraDesign.Motion.auroraSnap) {
                selection = mode.rawValue
            }
            HapticBus.tabChange()
        } label: {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack {
                    modeIcon(for: mode, theme: theme)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.primaryAccent)
                            .transition(.scale(scale: 0.1).combined(with: .opacity))
                    }
                }

                Text(mode.displayName)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(isSelected ? theme.primaryAccent : MobileTheme.Colors.textPrimary)

                Text(mode.description)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(MobileTheme.Spacing.md)
            .frame(width: 160, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                    .fill(isSelected ? theme.primaryAccent.opacity(0.08) : MobileTheme.Colors.surface.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                            .stroke(isSelected ? theme.primaryAccent.opacity(0.35) : MobileTheme.Colors.border.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: isSelected)
    }

    @ViewBuilder
    private func modeIcon(for mode: UIMode, theme: UIModeTheme) -> some View {
        switch mode {
        case .standard:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MobileTheme.ember.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MobileTheme.ember)
            }
        case .cooking:
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.primaryAccent.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image("CookingIconSkillet")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            }
        }
    }
}

#Preview {
    @Previewable @State var mode = UIMode.standard.rawValue
    VStack {
        UIModePicker(selection: $mode)
    }
    .padding()
    .background(AuroraBackdrop(density: .subtle))
}
