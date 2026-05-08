import SwiftUI
import OpenBurnBarCore

// MARK: - Rolling Number Text

/// Text wrapper that animates numeric transitions with `.numericText`.
struct RollingNumberText: View {
    let value: String
    let font: Font
    let foregroundStyle: Color

    init(
        _ value: String,
        font: Font = MobileTheme.Typography.display,
        foregroundStyle: Color = MobileTheme.Colors.textPrimary
    ) {
        self.value = value
        self.font = font
        self.foregroundStyle = foregroundStyle
    }

    var body: some View {
        Text(value)
            .font(font)
            .foregroundStyle(foregroundStyle)
            .contentTransition(.numericText(countsDown: false))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        RollingNumberText("$12.45", font: MobileTheme.Typography.display)
        RollingNumberText("1.2M tokens", font: MobileTheme.Typography.headline)
    }
    .padding()
    .background(MobileTheme.Colors.background)
}
