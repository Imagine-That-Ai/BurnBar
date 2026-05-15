import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Subscriptions Folder (Hermes Square §6.2 / Pillar 2)
//
// Phase A placeholder. Subscription-tier delivery ships in Phase B/C.
// This sheet explains the model and lists any locally-active topic
// subscriptions (typically none on first install).

struct HermesSquareSubscriptionsFolder: View {
    let registry: AgentIdentityRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var topics: [SubscriptionTopic] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                if topics.isEmpty {
                    emptyState
                        .padding(.top, 60)
                        .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 10) {
                        ForEach(topics) { topic in
                            row(for: topic)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Subscriptions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(DesignSystemColors.ember)
            Text("No subscriptions yet")
                .font(.headline)
                .foregroundStyle(DesignSystemColors.textPrimary)
            Text("Subscription-tier agents broadcast on a schedule — research scouts, weekly recaps, monitoring agents. Pick one in Discover → Marketplace once Phase C ships, then opt-in per topic.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignSystemColors.textSecondary)
            Text("Platform-enforced cap: \(AgentTier.subscriptionMonthlyBudget) deliveries / agent / month by default.")
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textMuted)
                .padding(.top, 4)
        }
    }

    private func row(for topic: SubscriptionTopic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.displayName)
                .font(.callout.bold())
                .foregroundStyle(DesignSystemColors.textPrimary)
            Text(topic.description)
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textMuted)
            HStack {
                Text(topic.cadence.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystemColors.surface))
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                Text("\(topic.deliveryCountThisMonth)/\(min(topic.cadence.maxPerMonth, AgentTier.subscriptionMonthlyHardCap)) this month")
                    .font(.caption2.monospaced())
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystemColors.surface.opacity(0.5))
        )
    }
}
