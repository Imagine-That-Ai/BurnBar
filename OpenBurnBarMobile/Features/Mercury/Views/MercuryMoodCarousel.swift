import SwiftUI

/// Compact swatch strip of mood presets. Each swatch is a 32pt circle
/// showing the preset's preview gradient; tapping it applies the preset
/// (accent + background + haptics + avatar style) instantly. Designed
/// to take ~50pt vertical so the device identity + live status stay
/// above the fold.
///
/// Replaces the chunky card carousel that previously dominated the
/// screen. The full deep-options sheet is reached from the chip strip
/// above (Accent / Mood chips both open `MercuryCustomizeSheet`).
struct MercuryMoodCarousel: View {
    @Binding var personalization: MercuryDevicePersonalization
    let sampledAuto: Color
    let onOpenCustomize: () -> Void

    @Namespace private var selectionRing

    private var matchingPresetID: String? {
        MercuryMoodPreset.matching(personalization)?.id
    }

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(MercuryMoodPreset.allPresets) { preset in
                        swatch(for: preset)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            customizeChevron
        }
    }

    @ViewBuilder
    private func swatch(for preset: MercuryMoodPreset) -> some View {
        let isSelected = preset.id == matchingPresetID
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                preset.apply(to: &personalization)
            }
            personalization.haptics.play()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: preset.previewColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    if isSelected {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 38, height: 38)
                            .matchedGeometryEffect(id: "moodRing", in: selectionRing)
                    }
                }
                Text(preset.name)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) — \(preset.tagline)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var customizeChevron: some View {
        Button(action: onOpenCustomize) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            Circle().strokeBorder(
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                            .foregroundStyle(Color.white.opacity(0.3))
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                Text("More")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open customize sheet")
    }
}
