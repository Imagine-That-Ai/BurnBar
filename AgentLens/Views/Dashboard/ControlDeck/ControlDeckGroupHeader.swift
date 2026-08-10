import SwiftUI

// MARK: - Control Deck Group Header
//
// One band's eyebrow: the group name, its one-line caption, and a hairline rule
// that runs to the edge of the content column. Six of these are what stop a
// wall of plates from reading as an undifferentiated grid — the labelled bands
// are the map.

struct ControlDeckGroupHeader: View {
    let group: ControlGroup
    let tileCount: Int
    let onCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Text(group.title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(group.caption)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                .lineLimit(1)

            Rectangle()
                .fill(DesignSystem.Colors.border.opacity(0.5))
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)

            Text("\(onCount)/\(tileCount) on")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(group.accent.opacity(0.85))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title). \(group.caption). \(onCount) of \(tileCount) on.")
        .accessibilityAddTraits(.isHeader)
    }
}
