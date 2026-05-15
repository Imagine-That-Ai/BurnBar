import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant Brand Header
//
// Logo-led header that replaces the plain `.navigationTitle("Hermes")`
// text in the conversation list views. Shows the harness logo prominently
// with the underlying model logo tucked into the corner (via
// `HarnessModelBadge`), the harness name in heavy display type, and a
// status chip plus model chip so a returning user can read everything
// they need at one glance — without the title eating two stark lines.
//
// Reused by `HermesConversationListView`, `PiConversationListView`, and
// `CLIAgentConversationListView`. Each view should switch to inline nav
// title display and drop the large title in favor of this header.

struct AssistantBrandHeader: View {
    let runtime: AssistantRuntimeID
    let runtimeStatus: RuntimeStatus
    let modelSnapshot: AssistantModelLens.ModelSnapshot
    let endpointLabel: String?
    var onTapModel: (() -> Void)? = nil
    var onTapStatus: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HarnessModelBadge(
                harness: runtime.agentProvider,
                model: modelSnapshot.provider,
                size: 56,
                availability: runtimeStatus,
                ringStroke: runtime.brandTint
            )
            .frame(width: 72, height: 72, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 6) {
                Text(runtime.displayName)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    statusChip
                    modelChip
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.md)
        .padding(.bottom, MobileTheme.Spacing.sm)
    }

    private var statusChip: some View {
        Button {
            onTapStatus?()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(runtimeStatus.color)
                    .frame(width: 6, height: 6)
                Text(endpointLabel ?? runtimeStatus.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.65))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(onTapStatus == nil)
        .accessibilityLabel("Connection: \(runtimeStatus.label)")
    }

    private var modelChip: some View {
        Button {
            onTapModel?()
        } label: {
            HStack(spacing: 5) {
                UnifiedProviderLogoView(provider: modelSnapshot.provider, size: 12)
                Text(modelSnapshot.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.65))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(runtime.brandTint.opacity(0.35), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(onTapModel == nil)
        .accessibilityLabel("Running model \(modelSnapshot.displayName)")
        .accessibilityHint("Opens the model picker")
    }
}

// MARK: - Identifiable conformance for sheet routing
//
// `AssistantRuntimeID` is declared in `OpenBurnBarCore`. We bridge it to
// `Identifiable` here so SwiftUI's `.sheet(item:)` can be driven by a
// runtime selection.
extension AssistantRuntimeID: @retroactive Identifiable {
    public var id: String { rawValue }
}
