import SwiftUI

/// Three-way segmented haptics picker — tapping a segment plays a sample
/// so the user feels the choice before committing.
struct MercuryHapticsPicker: View {
    @Binding var selection: MercuryHapticsLevel
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MercuryHapticsLevel.allCases) { level in
                segment(for: level)
            }
        }
    }

    @ViewBuilder
    private func segment(for level: MercuryHapticsLevel) -> some View {
        let isSelected = selection == level
        Button {
            selection = level
            level.play()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: level.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.65))
                Text(level.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.28) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(level.displayName) haptics")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
