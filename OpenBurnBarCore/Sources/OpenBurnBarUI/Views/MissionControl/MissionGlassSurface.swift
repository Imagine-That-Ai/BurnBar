import SwiftUI
import OpenBurnBarRecap

// MARK: - Mission Control Chrome
//
// Shared chrome primitives for the Mission Control console. The console uses
// one quiet visual language across every section:
//   • `MissionSectionHeader` — plain-language section title + optional trailing
//     status text. No numbered steps, no hairline rules, no mono eyebrows.
//   • `MissionConsoleCard` — the single grouped-container treatment: surface fill,
//     12pt continuous corners, hairline border.
//   • `MissionFieldLabel` — small secondary label above a control.
//
// Internal to the module; the public views compose these.

enum MissionChrome {
    static let cardCorner: CGFloat = 12
    static let controlCorner: CGFloat = 10
    static let hairline: CGFloat = 0.5

    static var cardFill: Color { UnifiedDesignSystem.Colors.surface }
    static var fieldFill: Color { UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.55) }
    static var hairlineColor: Color { UnifiedDesignSystem.Colors.borderSubtle.opacity(0.85) }
    static var accent: Color { UnifiedDesignSystem.Colors.ember }
}

// MARK: - Section header

struct MissionSectionHeader: View {
    let title: String
    var trailing: String?
    var trailingTint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(trailingTint ?? UnifiedDesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Field label

struct MissionFieldLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
    }
}

// MARK: - Card container

struct MissionConsoleCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                    .fill(MissionChrome.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MissionChrome.cardCorner, style: .continuous)
                    .strokeBorder(MissionChrome.hairlineColor, lineWidth: MissionChrome.hairline)
            }
    }
}

// MARK: - Card row divider

struct MissionRowDivider: View {
    var indent: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(MissionChrome.hairlineColor)
            .frame(height: MissionChrome.hairline)
            .padding(.leading, indent)
    }
}
