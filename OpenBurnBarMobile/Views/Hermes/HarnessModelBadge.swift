import SwiftUI
import OpenBurnBarCore

// MARK: - Harness + Model Composite Badge
//
// Big harness logo + smaller model logo tucked into the bottom-right
// corner. Replaces every place we used to show only the harness icon
// in the Assistants tab. The model logo is sized at ~52% of the harness
// logo and overlaps the corner by ~30% — close enough to read as "this
// harness, running this model" without obscuring either glyph.
//
// Optional `availability` parameter renders a tiny status dot at the
// bottom-right of the model badge so the composite stays a single
// glance: harness identity → model identity → connection state.

struct HarnessModelBadge: View {
    let harness: AgentProvider
    let model: AgentProvider?
    var size: CGFloat = 44
    var availability: RuntimeStatus? = nil
    /// When true, applies an accent ring around the harness logo. Used in
    /// the Hermes Square pinned grid where each tile gets a brand halo.
    var ringStroke: Color? = nil

    private var modelBadgeSize: CGFloat { size * 0.52 }
    /// Outer chrome footprint so callers can size containers correctly —
    /// the badge sticks ~22% past the harness logo's bottom-right corner.
    static func totalSize(harnessSize: CGFloat) -> CGSize {
        CGSize(width: harnessSize + harnessSize * 0.22,
               height: harnessSize + harnessSize * 0.22)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            harnessLogo

            if let model {
                modelBadge(for: model)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var harnessLogo: some View {
        UnifiedProviderLogoView(provider: harness, size: size, useFallbackColor: true)
            .overlay {
                if let ringStroke {
                    RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                        .stroke(ringStroke.opacity(0.55), lineWidth: max(0.8, size * 0.03))
                }
            }
    }

    @ViewBuilder
    private func modelBadge(for provider: AgentProvider) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // White-ish ring around the model logo so it pops off the
            // harness — works whether the harness logo is light or dark.
            UnifiedProviderLogoView(provider: provider, size: modelBadgeSize, useFallbackColor: true)
                .padding(modelBadgeSize * 0.06)
                .background(
                    RoundedRectangle(cornerRadius: modelBadgeSize * 0.27, style: .continuous)
                        .fill(MobileTheme.Colors.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: modelBadgeSize * 0.27, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.55), lineWidth: 0.6)
                )

            if let availability {
                Circle()
                    .fill(availability.color)
                    .frame(width: modelBadgeSize * 0.28, height: modelBadgeSize * 0.28)
                    .overlay(
                        Circle()
                            .stroke(MobileTheme.Colors.background, lineWidth: 1.2)
                    )
                    .offset(x: modelBadgeSize * 0.18, y: modelBadgeSize * 0.18)
            }
        }
        .offset(x: modelBadgeSize * 0.30, y: modelBadgeSize * 0.30)
    }

    private var accessibilityDescription: String {
        var parts: [String] = [harness.rawValue]
        if let model { parts.append("running \(model.rawValue)") }
        if let availability { parts.append(availability.label) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Convenience constructors

extension HarnessModelBadge {
    /// Build a badge from an `AssistantRuntimeID` + an optional
    /// `AssistantModelLens.ModelSnapshot`. The lens already resolved the
    /// model's provider; we just plug it in.
    init(runtime: AssistantRuntimeID,
         modelSnapshot: AssistantModelLens.ModelSnapshot?,
         size: CGFloat = 44,
         availability: RuntimeStatus? = nil,
         ringStroke: Color? = nil) {
        self.harness = runtime.agentProvider
        self.model = modelSnapshot?.provider
        self.size = size
        self.availability = availability
        self.ringStroke = ringStroke
    }
}
