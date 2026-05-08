import SwiftUI

// MARK: - Chart Studio Prompt Carousel
//
// Horizontally scrolling chip rail of suggested prompts. Tapping a chip
// invokes the `onSelect` closure with the prompt text. Chips ride a
// gentle floating animation and pulse-glow on the chip the user is
// hovering on iPad / Mac Catalyst.

struct ChartStudioPromptCarousel: View {
    let prompts: [String]
    let onSelect: (String) -> Void

    @State private var hoverIndex: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    Button {
                        HapticBus.chipChange()
                        onSelect(prompt)
                    } label: {
                        chip(prompt, isHovering: hoverIndex == index)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover in
                        withAnimation(AuroraDesign.Motion.cardHover) {
                            hoverIndex = hover ? index : nil
                        }
                    }
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    private func chip(_ prompt: String, isHovering: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
            Text(prompt)
                .font(MobileTheme.Typography.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(MobileTheme.hermesAureate)
        .background(
            Capsule()
                .fill(MobileTheme.hermesAureate.opacity(isHovering ? 0.22 : 0.12))
        )
        .overlay(
            Capsule()
                .stroke(MobileTheme.hermesAureate.opacity(isHovering ? 0.6 : 0.35), lineWidth: 0.5)
        )
        .scaleEffect(isHovering ? 1.04 : 1.0)
    }
}
