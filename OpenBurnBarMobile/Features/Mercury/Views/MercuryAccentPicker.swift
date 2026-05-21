import SwiftUI

/// Horizontal swatch row + leading "Auto" capsule. Selection animates
/// with a single shared `matchedGeometryEffect` ring so the accent feels
/// like a physical object the user is moving.
struct MercuryAccentPicker: View {
    @Binding var selection: MercuryAccent
    let sampledAuto: Color
    let haptics: MercuryHapticsLevel

    @Namespace private var selectionNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                autoChip
                ForEach(MercuryAccent.swatchOrder, id: \.self) { accent in
                    swatch(for: accent)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var autoChip: some View {
        let isSelected = selection == .autoFromWallpaper
        Button {
            haptics.play()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                selection = .autoFromWallpaper
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(sampledAuto)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                Text("Auto")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    Capsule().fill(Color.white.opacity(0.08))
                    if isSelected {
                        Capsule()
                            .stroke(sampledAuto, lineWidth: 1.5)
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto accent from wallpaper")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func swatch(for accent: MercuryAccent) -> some View {
        let isSelected = selection == accent
        Button {
            haptics.play()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                selection = accent
            }
        } label: {
            ZStack {
                Circle()
                    .fill(accent.staticColor)
                    .frame(width: 30, height: 30)
                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accent.displayName) accent")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
