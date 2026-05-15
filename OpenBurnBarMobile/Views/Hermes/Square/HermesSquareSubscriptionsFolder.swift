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

    @State private var topicStore = AgentSubscriptionTopicStore.shared
    @State private var pendingTopicIDs: Set<String> = []
    @State private var operationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if topicStore.topics.isEmpty {
                    emptyState
                        .padding(.top, 60)
                        .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 10) {
                        ForEach(topicStore.topics) { topic in
                            row(for: topic)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Subscriptions")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                topicStore.bootstrap()
                await topicStore.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Subscription action failed", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("OK", role: .cancel) { operationError = nil }
            } message: {
                Text(operationError ?? "")
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
            Text("Tap Subscribe in an agent brand zone to add a topic. Muted topics stay saved and can be resumed later.")
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
            HStack(spacing: 8) {
                Text(topic.displayName)
                    .font(.callout.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                if topic.isMuted {
                    Text("Muted")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystemColors.surface))
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                Spacer()
                if pendingTopicIDs.contains(topic.id) {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Menu {
                        Button(topic.isMuted ? "Unmute" : "Mute") {
                            mutate(topicID: topic.id) {
                                try await topicStore.setMuted(
                                    agentURI: topic.agentURI,
                                    topicID: topic.topicID,
                                    muted: !topic.isMuted
                                )
                            }
                        }
                        Button("Unsubscribe", role: .destructive) {
                            mutate(topicID: topic.id) {
                                try await topicStore.unsubscribe(
                                    agentURI: topic.agentURI,
                                    topicID: topic.topicID
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
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

    private func mutate(
        topicID: String,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        pendingTopicIDs.insert(topicID)
        Task {
            do {
                try await operation()
            } catch {
                operationError = error.localizedDescription
            }
            pendingTopicIDs.remove(topicID)
        }
    }
}
