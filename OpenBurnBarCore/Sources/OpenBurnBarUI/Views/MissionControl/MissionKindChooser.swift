import SwiftUI
import OpenBurnBarKernel

// MARK: - Mission Kind Chooser
//
// Adaptive grid of mission-kind tiles — two columns on a phone, more as width
// allows. Every kind is visible without scrolling. Each tile carries a glyph
// chip, display name, and one-line tagline. The selected tile gets a tinted
// fill and accent border; nothing glows.

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

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 158, maximum: 260), spacing: UnifiedDesignSystem.Spacing.sm, alignment: .top)
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            MissionSectionHeader(
                title: "Mission type",
                trailing: recommendedRuntimeName.map { "Best fit: \($0)" }
            )

            LazyVGrid(columns: columns, spacing: UnifiedDesignSystem.Spacing.sm) {
                ForEach(MissionConsoleKind.allCases) { kind in
                    kindTile(kind)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recommendedRuntimeName: String? {
        guard let id = selectedKind.preferredRuntimes.first else { return nil }
        return runtimes.first(where: { $0.id == id })?.displayName
    }

    private func kindTile(_ kind: MissionConsoleKind) -> some View {
        let isSelected = kind == selectedKind
        return Button { onSelect(kind) } label: {
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : MissionChrome.accent)
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? MissionChrome.accent : MissionChrome.accent.opacity(0.12))
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Text(kind.tagline)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                    .fill(isSelected ? MissionChrome.accent.opacity(0.14) : MissionChrome.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                    .strokeBorder(
                        isSelected ? MissionChrome.accent.opacity(0.75) : MissionChrome.hairlineColor,
                        lineWidth: isSelected ? 1 : MissionChrome.hairline
                    )
            }
            .animation(UnifiedDesignSystem.Animation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.displayName) — \(kind.tagline). \(isSelected ? "Selected." : "Tap to select.")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
