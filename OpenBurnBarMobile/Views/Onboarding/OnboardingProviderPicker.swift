import SwiftUI
import OpenBurnBarCore

/// First real step of the wizard. The user picks the providers they want to
/// connect; the wizard then walks them through one connect-flow per pick.
///
/// Recommended providers float to the top (`ProviderSetupGuide.recommended`),
/// with already-connected providers de-emphasized but still selectable so a
/// user can add another account.
struct OnboardingProviderPicker: View {
    @Binding var selected: Set<AgentProvider>
    let alreadyConnected: Set<ProviderID>

    @State private var appeared = false

    private var orderedProviders: [AgentProvider] {
        ProviderSetupGuide.sortedProvidersForOnboarding()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            header

            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: MobileTheme.Spacing.sm),
                        GridItem(.flexible(), spacing: MobileTheme.Spacing.sm)
                    ],
                    spacing: MobileTheme.Spacing.sm
                ) {
                    ForEach(Array(orderedProviders.enumerated()), id: \.element.id) { index, provider in
                        ProviderPickerTile(
                            provider: provider,
                            isSelected: selected.contains(provider),
                            isRecommended: ProviderSetupGuide.recommended.contains(provider),
                            isAlreadyConnected: alreadyConnected.contains(provider.providerID),
                            onTap: { toggle(provider) }
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(
                            MobileTheme.Animation.gentle.delay(Double(index) * 0.025),
                            value: appeared
                        )
                    }
                }
                .padding(.bottom, MobileTheme.Spacing.lg)
            }

            footer
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
    }

    private func toggle(_ provider: AgentProvider) {
        Haptics.light()
        withAnimation(MobileTheme.Animation.snappy) {
            if selected.contains(provider) {
                selected.remove(provider)
            } else {
                selected.insert(provider)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            Text("Pick your providers")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            Text("We'll walk through one at a time. You can always add more later.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if selected.isEmpty {
                Text("Tap a provider to start")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            } else {
                Text("\(selected.count) selected")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            if alreadyConnected.isEmpty == false {
                Text("\(alreadyConnected.count) already connected")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.success)
            }
        }
        .animation(MobileTheme.Animation.snappy, value: selected.count)
    }
}

// MARK: - Tile

private struct ProviderPickerTile: View {
    let provider: AgentProvider
    let isSelected: Bool
    let isRecommended: Bool
    let isAlreadyConnected: Bool
    let onTap: () -> Void

    private var tint: Color {
        MobileTheme.Colors.primary(for: provider)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack(alignment: .top) {
                    ProviderAvatar(provider: provider, mode: .aurora, size: 44)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tint)
                            .transition(.scale.combined(with: .opacity))
                    } else if isRecommended {
                        Text("Top pick")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(provider.displayName)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(ProviderSetupGuide.guide(for: provider).oneLineHint)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isAlreadyConnected {
                    Label("Connected", systemImage: "checkmark.seal.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.success)
                }
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.14) : MobileTheme.Colors.surface.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? tint : MobileTheme.Colors.border, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(MobileTheme.Animation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        var parts: [String] = [provider.displayName]
        if isRecommended { parts.append("Top pick") }
        if isAlreadyConnected { parts.append("Already connected") }
        parts.append(isSelected ? "Selected" : "Not selected")
        return parts.joined(separator: ", ")
    }
}

#Preview {
    OnboardingProviderPicker(
        selected: .constant([.cursor]),
        alreadyConnected: [.openAI]
    )
    .padding()
    .background(EmberSurfaceBackground().ignoresSafeArea())
}
