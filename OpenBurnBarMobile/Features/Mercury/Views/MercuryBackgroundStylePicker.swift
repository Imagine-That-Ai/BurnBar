import SwiftUI

/// Three mini preview cards for `.wallpaper` / `.aurora` / `.solid`. The
/// selected card gets an accent-tinted outline + a check.
struct MercuryBackgroundStylePicker: View {
    @Binding var selection: MercuryBackgroundStyle
    let accent: Color
    let haptics: MercuryHapticsLevel

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MercuryBackgroundStyle.allCases, id: \.self) { style in
                card(for: style)
            }
        }
    }

    @ViewBuilder
    private func card(for style: MercuryBackgroundStyle) -> some View {
        let isSelected = selection == style
        Button {
            haptics.play()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                selection = style
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    preview(for: style)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(accent))
                            .offset(x: 18, y: -18)
                    }
                }
                .frame(width: 60, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accent.opacity(isSelected ? 0.9 : 0.0), lineWidth: 1.5)
                )

                Text(style.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.displayName) background")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func preview(for style: MercuryBackgroundStyle) -> some View {
        switch style {
        case .wallpaper:
            LinearGradient(
                colors: [
                    Color(red: 0.40, green: 0.55, blue: 0.75),
                    Color(red: 0.20, green: 0.30, blue: 0.45)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.45))
            )
        case .aurora:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.12, blue: 0.14),
                        Color(red: 0.05, green: 0.05, blue: 0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [accent.opacity(0.6), Color.clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 40
                )
                RadialGradient(
                    colors: [Color.purple.opacity(0.5), Color.clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 40
                )
            }
        case .solid:
            LinearGradient(
                colors: [accent.opacity(0.4), accent.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(Color.black.opacity(0.35))
        case .website:
            ZStack {
                Color(red: 0.02, green: 0.02, blue: 0.03)
                VStack(spacing: 5) {
                    ForEach(0..<12) { _ in
                        Rectangle()
                            .fill(accent.opacity(0.15))
                            .frame(height: 0.5)
                    }
                }
                RadialGradient(
                    colors: [accent.opacity(0.45), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 25
                )
            }
        }
    }
}
