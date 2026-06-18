import SwiftUI

struct OnboardingProviderCloudView: View {
    @Binding var selectedProviders: Set<AgentProvider>
    let detectedProviders: [AgentProvider: Bool]

    @State private var appeared = false

    /// Detected-first ordering: detected providers sorted by name, then remaining sorted by name.
    private var sortedProviders: [AgentProvider] {
        let detected = AgentProvider.allCases
            .filter { detectedProviders[$0] == true }
            .sorted { $0.displayName < $1.displayName }
        let rest = AgentProvider.allCases
            .filter { detectedProviders[$0] != true }
            .sorted { $0.displayName < $1.displayName }
        return detected + rest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Choose your agents")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Select the coding agents you use. OpenBurnBar detected the highlighted ones on this Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                FlowLayout(
                    horizontalSpacing: DesignSystem.Spacing.sm,
                    verticalSpacing: DesignSystem.Spacing.sm
                ) {
                    ForEach(Array(sortedProviders.enumerated()), id: \.element.id) { index, provider in
                        OnboardingProviderPill(
                            provider: provider,
                            isSelected: selectedProviders.contains(provider),
                            isDetected: detectedProviders[provider] == true,
                            onTap: {
                                withAnimation(DesignSystem.Animation.snappy) {
                                    if selectedProviders.contains(provider) {
                                        selectedProviders.remove(provider)
                                    } else {
                                        selectedProviders.insert(provider)
                                    }
                                }
                            }
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(
                            DesignSystem.Animation.gentle.delay(Double(index) * 0.03),
                            value: appeared
                        )
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.xs)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                let detectedCount = detectedProviders.values.filter { $0 }.count
                if detectedCount > 0 {
                    Button("Select all detected (\(detectedCount))") {
                        withAnimation(DesignSystem.Animation.snappy) {
                            for (provider, found) in detectedProviders where found {
                                selectedProviders.insert(provider)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                }

                Spacer()

                Text("\(selectedProviders.count) selected")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.snappy, value: selectedProviders.count)
            }
        }
        .onAppear {
            // Short delay so the view is mounted before stagger starts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appeared = true
            }
        }
    }
}
