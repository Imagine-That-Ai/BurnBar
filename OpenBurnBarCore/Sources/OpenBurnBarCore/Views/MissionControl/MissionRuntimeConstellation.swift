import SwiftUI

// MARK: - Mission Runtime Constellation
//
// Horizontal row of agent capability cards. First card is always "AUTO" (let
// the planner pick); the rest are runtimes the host advertises as enabled.
//
// Each card carries:
//   • Provider-tinted accent strip down the left edge
//   • Mono call-sign (3–4 chars) and human display name
//   • Availability dot (online/offline/unknown)
//   • Optional median-burn pill ("$0.84 median, n=6")
//   • "Preferred for X" hint when the selected kind recommends this runtime
//   • Selected ring + glow when active

public struct MissionRuntimeConstellation: View {
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
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            sectionHeader

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
                    runtimeCard(for: .auto, isAuto: true)
                    Divider()
                        .frame(width: 1, height: 96)
                        .overlay(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                        .padding(.horizontal, 2)
                    ForEach(runtimes) { runtime in
                        runtimeCard(for: runtime, isAuto: false)
                    }
                }
                .padding(.leading, 1)
                .padding(.trailing, UnifiedDesignSystem.Spacing.xl)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("02 · RUNTIME")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            if selectedRuntimeID == "auto" {
                Text("Planner will route based on \(selectedKind.displayName.uppercased())")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }

    // MARK: Card

    @ViewBuilder
    private func runtimeCard(for runtime: MissionConsoleRuntime, isAuto: Bool) -> some View {
        let isSelected = runtime.id == selectedRuntimeID
        let isPreferred = selectedKind.preferredRuntimes.first == runtime.id
        let tint = isAuto
            ? UnifiedDesignSystem.Colors.ember
            : UnifiedDesignSystem.Colors.primary(for: runtime.provider)

        Button { onSelect(runtime.id) } label: {
            HStack(spacing: 0) {
                // Provider accent stripe
                Rectangle()
                    .fill(tint)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                        if isAuto {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(tint)
                                .frame(width: 18, height: 18)
                        } else {
                            UnifiedProviderLogoView(provider: runtime.provider, size: 18)
                        }
                        availabilityDot(runtime.availability)
                        Text(runtime.callSign)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(tint)
                    }
                    Text(runtime.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    if let tagline = runtime.tagline {
                        Text(tagline)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let median = runtime.recentMedianBurnUSD, runtime.recentSampleSize > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "scalemass")
                                .font(.system(size: 8, weight: .semibold))
                            Text("\(MissionConsoleFormatting.cost(median, precise: median < 1)) median · n=\(runtime.recentSampleSize)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    } else if !isAuto {
                        Text("No recent history")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }

                    if isPreferred && !isSelected && !isAuto {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.right.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text("Preferred for \(selectedKind.displayName)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                        }
                        .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
            }
            .frame(width: 168, height: 110, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(isSelected ? 0.95 : 0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? tint.opacity(0.85) : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7),
                        lineWidth: isSelected ? 1.4 : 0.6
                    )
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 4)
                        .blur(radius: 6)
                        .padding(-2)
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: isSelected ? tint.opacity(0.30) : Color.black.opacity(0.08),
                radius: isSelected ? 14 : 6,
                y: isSelected ? 6 : 2
            )
            .scaleEffect(isSelected ? 1.0 : 0.98)
            .animation(UnifiedDesignSystem.Animation.standard, value: isSelected)
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(runtime.displayName), \(isSelected ? "selected" : "tap to select")\(isPreferred ? ", preferred for \(selectedKind.displayName)" : "")")
    }

    private func availabilityDot(_ availability: MissionConsoleRuntime.Availability) -> some View {
        Circle()
            .fill(dotColor(for: availability))
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            )
    }

    private func dotColor(for availability: MissionConsoleRuntime.Availability) -> Color {
        switch availability {
        case .online:  return UnifiedDesignSystem.Colors.success
        case .offline: return UnifiedDesignSystem.Colors.error
        case .unknown: return UnifiedDesignSystem.Colors.textMuted
        }
    }
}
