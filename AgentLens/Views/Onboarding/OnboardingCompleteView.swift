import SwiftUI

struct OnboardingCompleteView: View {
    struct Summary: Equatable {
        let sessionCount: Int
        let providerCount: Int
        let selectedProviderCount: Int
        let headline: String
        let body: String
        let showsEmptyHistoryNotice: Bool
    }

    let dataStore: DataStore
    let selectedProviders: Set<AgentProvider>
    let onOpenDashboard: () -> Void
    let onDismiss: () -> Void

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0

    private var summary: Summary {
        Self.summary(dataStore: dataStore, selectedProviders: selectedProviders)
    }

    /// Pure presentation copy used by the view and host-safe unit tests.
    /// Keep this free of SwiftUI layout so XCTest never has to inspect a
    /// GeometryReader/animation tree (ViewInspector has crashed the host here).
    static func summary(
        dataStore: DataStore,
        selectedProviders: Set<AgentProvider>
    ) -> Summary {
        let sessionCount = dataStore.totalUsageSessionCount
        let providerCount = dataStore.providerSummaries(for: .allTime).count
        let selectedProviderCount = selectedProviders.count
        let headline: String
        if sessionCount > 0 {
            headline =
                "Found \(sessionCount) session\(sessionCount == 1 ? "" : "s") across \(providerCount) provider\(providerCount == 1 ? "" : "s")"
        } else {
            headline = "You're all set"
        }
        let body =
            "OpenBurnBar is now tracking \(selectedProviderCount) agent\(selectedProviderCount == 1 ? "" : "s"). Your dashboard, session logs, and Hermes chat are ready."
        return Summary(
            sessionCount: sessionCount,
            providerCount: providerCount,
            selectedProviderCount: selectedProviderCount,
            headline: headline,
            body: body,
            showsEmptyHistoryNotice: sessionCount == 0
        )
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            // Center the hero within the scroll viewport by sizing the content to
            // the available height. This runtime GeometryReader is safe: the host
            // crash came from ViewInspector walking this tree in XCTest, and
            // OnboardingCompleteViewTests is ViewInspector-free by design.
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DesignSystem.Spacing.xl) {
                        Spacer(minLength: 0)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(DesignSystem.Colors.success)
                            .scaleEffect(checkmarkScale)
                            .opacity(checkmarkOpacity)
                            .accessibilityHidden(true)

                        VStack(spacing: DesignSystem.Spacing.sm) {
                            Text(summary.headline)
                                .font(DesignSystem.Typography.headline)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .multilineTextAlignment(.center)

                            Text(summary.body)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            if summary.showsEmptyHistoryNotice {
                                HStack(spacing: DesignSystem.Spacing.xs) {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignSystem.Colors.warning)
                                    Text("No historical sessions were found. Your dashboard may look empty until your agents log new activity. You can trigger a manual scan anytime from the toolbar.")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, DesignSystem.Spacing.md)
                                .padding(.vertical, DesignSystem.Spacing.sm)
                                .background {
                                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                        .fill(DesignSystem.Colors.warning.opacity(0.06))
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    onOpenDashboard()
                } label: {
                    Text("Open Dashboard")
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)

                Button("Stay in menu bar") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.15)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
        }
    }
}
