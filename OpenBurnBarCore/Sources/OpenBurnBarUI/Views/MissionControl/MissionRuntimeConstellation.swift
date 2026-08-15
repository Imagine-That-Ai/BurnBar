import SwiftUI
import OpenBurnBarKernel

// MARK: - Mission Runtime Picker
//
// Grouped list of runtime rows. First row is always AUTO (the planner picks);
// the rest are the runtimes the host advertises. Each row shows:
//   • Provider logo + availability dot
//   • Display name, with a "Suggested" pill when the selected kind prefers it
//   • One detail line — tagline, median burn ("$0.41 median · 14 runs"), or
//     "No recent history"
//   • Checkmark when selected
// Offline runtimes are dimmed but remain selectable.

public struct MissionRuntimePicker: View {
    public let runtimes: [MissionConsoleRuntime]
    public let selectedRuntimeID: MissionConsoleRuntime.ID
    public let selectedKind: MissionConsoleKind
    public let onSelect: (MissionConsoleRuntime.ID) -> Void

    public init(
        runtimes: [MissionConsoleRuntime],
        selectedRuntimeID: MissionConsoleRuntime.ID,
        selectedKind: MissionConsoleKind,
        onSelect: @escaping (MissionConsoleRuntime.ID) -> Void
    ) {
        self.runtimes = runtimes
        self.selectedRuntimeID = selectedRuntimeID
        self.selectedKind = selectedKind
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            MissionSectionHeader(
                title: "Runtime",
                trailing: selectedRuntimeID == "auto" ? "Planner picks for \(selectedKind.displayName)" : nil
            )

            MissionConsoleCard {
                VStack(spacing: 0) {
                    runtimeRow(.auto, isAuto: true)
                    ForEach(runtimes) { runtime in
                        MissionRowDivider(indent: 48)
                        runtimeRow(runtime, isAuto: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Row

    private func runtimeRow(_ runtime: MissionConsoleRuntime, isAuto: Bool) -> some View {
        let isSelected = runtime.id == selectedRuntimeID
        let isPreferred = !isAuto && selectedKind.preferredRuntimes.first == runtime.id
        let isOffline = runtime.availability == .offline

        return Button { onSelect(runtime.id) } label: {
            HStack(spacing: UnifiedDesignSystem.Spacing.md) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if isAuto {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MissionChrome.accent)
                                .frame(width: 30, height: 30)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(MissionChrome.accent.opacity(0.12))
                                }
                        } else {
                            UnifiedProviderLogoView(provider: runtime.provider, size: 30)
                        }
                    }
                    Circle()
                        .fill(dotColor(for: runtime.availability))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(MissionChrome.cardFill, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(runtime.displayName)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        if isPreferred && !isSelected {
                            Text("Suggested")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(MissionChrome.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(MissionChrome.accent.opacity(0.12)) }
                        }
                    }
                    Text(detailLine(for: runtime, isAuto: isAuto))
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(isOffline ? UnifiedDesignSystem.Colors.warning : UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? MissionChrome.accent : UnifiedDesignSystem.Colors.textMuted.opacity(0.5))
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isOffline && !isSelected ? 0.65 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(runtime.displayName), \(isSelected ? "selected" : "tap to select")\(isPreferred ? ", suggested for \(selectedKind.displayName)" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detailLine(for runtime: MissionConsoleRuntime, isAuto: Bool) -> String {
        if runtime.availability == .offline {
            return runtime.tagline ?? "Offline"
        }
        if let tagline = runtime.tagline, !tagline.isEmpty {
            return tagline
        }
        if let median = runtime.recentMedianBurnUSD, runtime.recentSampleSize > 0 {
            return "\(MissionConsoleFormatting.cost(median, precise: median < 1)) median · \(runtime.recentSampleSize) runs"
        }
        return isAuto ? "Let the planner pick" : "No recent history"
    }

    private func dotColor(for availability: MissionConsoleRuntime.Availability) -> Color {
        switch availability {
        case .online:  return UnifiedDesignSystem.Colors.success
        case .offline: return UnifiedDesignSystem.Colors.error
        case .unknown: return UnifiedDesignSystem.Colors.textMuted
        }
    }
}
