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

    @Environment(\.backdropInk) private var ink

    var body: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            // A band label sits directly on the backdrop with no plate under
            // it, so it is the most exposed text on the page. It gets the
            // brightest readable rung, not the quietest.
            Text(group.title.uppercased())
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(ink.primary)

            Text(group.caption)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(ink.subtle)
                .lineLimit(1)

            Rectangle()
                .fill(ink.hairline)
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)

            Text("\(onCount)/\(tileCount) on")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title). \(group.caption). \(onCount) of \(tileCount) on.")
        .accessibilityAddTraits(.isHeader)
    }
}
