import SwiftUI

// MARK: - Mission Kind Chooser
//
// 4-column grid of mission-kind tiles. Each tile carries:
//   • Glyph
//   • Display name
//   • Tagline (1 line)
//   • Small "recommends ▸ <runtime>" hint (when known)
// Tap to select. Selected tile gets ember stripe + soft glow.

public struct MissionKindChooser: View {
    public let runtimes: [MissionConsoleRuntime]
    public let selectedKind: MissionConsoleKind
    public let onSelect: (MissionConsoleKind) -> Void

    public init(
        runtimes: [MissionConsoleRuntime],
        selectedKind: MissionConsoleKind,
        onSelect: @escaping (MissionConsoleKind) -> Void
    ) {
        self.runtimes = runtimes
        self.selectedKind = selectedKind
        self.onSelect = onSelect
    }

    private let rows: [GridItem] = Array(
        repeating: GridItem(.fixed(92), spacing: UnifiedDesignSystem.Spacing.sm),
        count: 2
    )

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            sectionHeader

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
                    ForEach(MissionConsoleKind.allCases) { kind in
                        kindTile(kind)
                    }
                }
                .padding(.leading, 1)
                .padding(.trailing, UnifiedDesignSystem.Spacing.xl)
                .padding(.vertical, 2)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("01 · KIND")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            Text(selectedKind.displayName.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
        }
    }

    @ViewBuilder
    private func kindTile(_ kind: MissionConsoleKind) -> some View {
        let isSelected = kind == selectedKind
        let recommendedID = kind.preferredRuntimes.first
        let recommendedDisplay = runtimes.first(where: { $0.id == recommendedID })?.displayName

        Button { onSelect(kind) } label: {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(UnifiedDesignSystem.primaryGradient)
                                : AnyShapeStyle(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.7))
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: kind.glyph)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : UnifiedDesignSystem.Colors.ember)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Text(kind.tagline)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let name = recommendedDisplay {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.right.fill")
                                .font(.system(size: 7, weight: .bold))
                            Text("Recommends \(name)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(0.5)
                        }
                        .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.85))
                        .padding(.top, 1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(UnifiedDesignSystem.Spacing.sm)
            .frame(minWidth: 260, maxWidth: 260, minHeight: 88, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surface.opacity(isSelected ? 0.95 : 0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? UnifiedDesignSystem.Colors.ember.opacity(0.85)
                            : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6),
                        lineWidth: isSelected ? 1.2 : 0.6
                    )
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(UnifiedDesignSystem.primaryGradient)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous))
                }
            }
            .shadow(
                color: isSelected ? UnifiedDesignSystem.Colors.ember.opacity(0.25) : Color.black.opacity(0.05),
                radius: isSelected ? 10 : 3,
                y: isSelected ? 4 : 1
            )
            .animation(UnifiedDesignSystem.Animation.standard, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.displayName) — \(kind.tagline). \(isSelected ? "Selected." : "Tap to select.")")
    }
}
