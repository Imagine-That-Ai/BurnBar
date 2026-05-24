import SwiftUI
import OpenBurnBarCore

struct QuotaCustomizationSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = QuotaSettingsStore()
    @State private var store = QuotaStore()
    @State private var expandedProvider: AgentProvider?

    // Mock bucket for the live visual preview
    private let previewBucket = ProviderQuotaBucket(
        name: "GPT-4o",
        used: 7_500_000,
        limit: 10_000_000,
        remaining: 2_500_000,
        meta: ["label": "GPT-4o"]
    )

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)

            Form {
                // MARK: Live Preview Section
                Section {
                    VStack(spacing: MobileTheme.Spacing.md) {
                        Text("Live Preview")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        UnifiedQuotaSignalView(
                            bucket: previewBucket,
                            provider: .openAI,
                            compact: false,
                            displayMode: settings.percentageDisplayMode.rawValue
                        )
                        .padding(.vertical, 4)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Interactive Preview")
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                // MARK: Display Mode Selector Section
                Section {
                    Picker("Format", selection: $settings.percentageDisplayMode) {
                        ForEach(QuotaPercentageDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Percentage display mode")
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                // MARK: Provider Order & Visibility Section
                Section {
                    let providers = settings.providerOrder
                    ForEach(providers) { provider in
                        let isVisible = settings.visibleProviders.contains(provider)
                        let isExpanded = expandedProvider == provider

                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: MobileTheme.Spacing.md) {
                                // Toggle visibility checkbox
                                Button {
                                    toggleProviderVisibility(provider)
                                } label: {
                                    Image(systemName: isVisible ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isVisible ? MobileTheme.ember : .secondary)
                                }
                                .buttonStyle(.plain)

                                // Provider Logo & Display Name
                                UnifiedProviderLogoView(provider: provider, size: 24)

                                Text(provider.rawValue)
                                    .font(MobileTheme.Typography.body)
                                    .foregroundStyle(isVisible ? .primary : .secondary)

                                Spacer()

                                // Accordion Expand Indicator (only if has buckets)
                                let providerBuckets = buckets(for: provider)
                                if !providerBuckets.isEmpty {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if isExpanded {
                                                expandedProvider = nil
                                            } else {
                                                expandedProvider = provider
                                            }
                                        }
                                        Haptics.light()
                                    } label: {
                                        Image(systemName: "chevron.right")
                                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                            .padding(.horizontal, 4)
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Order Adjustment Buttons
                                HStack(spacing: 8) {
                                    let idx = providers.firstIndex(of: provider) ?? 0
                                    Button {
                                        moveUp(provider)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                            .font(.caption.weight(.bold))
                                    }
                                    .disabled(idx == 0)
                                    .buttonStyle(.borderless)
                                    .tint(idx == 0 ? .secondary.opacity(0.3) : MobileTheme.ember)

                                    Button {
                                        moveDown(provider)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                            .font(.caption.weight(.bold))
                                    }
                                    .disabled(idx == providers.count - 1)
                                    .buttonStyle(.borderless)
                                    .tint(idx == providers.count - 1 ? .secondary.opacity(0.3) : MobileTheme.ember)
                                }
                            }
                            .padding(.vertical, 8)

                            // Expanded dynamic quota buckets section
                            if isExpanded {
                                dividerLine

                                let sortedBucketsList = sortedBuckets(for: provider)
                                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                                    Text("Dynamic Buckets")
                                        .font(MobileTheme.Typography.tiny.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8)
                                        .padding(.bottom, 4)

                                    ForEach(sortedBucketsList, id: \.key) { bucket in
                                        let bucketVisible = !isBucketHidden(bucket, for: provider)

                                        HStack(spacing: MobileTheme.Spacing.md) {
                                            Button {
                                                toggleBucketVisibility(bucket, for: provider)
                                            } label: {
                                                Image(systemName: bucketVisible ? "checkmark.square.fill" : "square")
                                                    .foregroundStyle(bucketVisible ? MobileTheme.ember : .secondary)
                                            }
                                            .buttonStyle(.plain)

                                            Text(bucket.label)
                                                .font(MobileTheme.Typography.caption)
                                                .foregroundStyle(bucketVisible ? .primary : .secondary)

                                            Spacer()

                                            HStack(spacing: 12) {
                                                let bucketIdx = sortedBucketsList.firstIndex(where: { $0.key == bucket.key }) ?? 0
                                                Button {
                                                    moveBucketUp(bucket, for: provider)
                                                } label: {
                                                    Image(systemName: "chevron.up")
                                                        .font(.caption)
                                                }
                                                .disabled(bucketIdx == 0)
                                                .buttonStyle(.plain)
                                                .foregroundStyle(bucketIdx == 0 ? .secondary.opacity(0.3) : MobileTheme.ember)

                                                Button {
                                                    moveBucketDown(bucket, for: provider)
                                                } label: {
                                                    Image(systemName: "chevron.down")
                                                        .font(.caption)
                                                }
                                                .disabled(bucketIdx == sortedBucketsList.count - 1)
                                                .buttonStyle(.plain)
                                                .foregroundStyle(bucketIdx == sortedBucketsList.count - 1 ? .secondary.opacity(0.3) : MobileTheme.ember)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.leading, 8)
                                    }
                                }
                                .padding(.leading, 32)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                } header: {
                    Text("Providers order & visibility")
                } footer: {
                    Text("Toggle checkboxes to show/hide. Use arrows to change priority order.")
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Quota Customization")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.load()
            store.startListening()
        }
        .onDisappear {
            store.stopListening()
        }
    }

    // MARK: Helpers

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func toggleProviderVisibility(_ provider: AgentProvider) {
        var visible = settings.visibleProviders
        if visible.contains(provider) {
            visible.remove(provider)
        } else {
            visible.insert(provider)
        }
        settings.visibleProviders = visible
        Haptics.light()
    }

    private func toggleBucketVisibility(_ bucket: ProviderQuotaBucket, for provider: AgentProvider) {
        let compositeKey = "\(provider.persistedToken):\(bucket.key)"
        var hidden = settings.hiddenBuckets
        if hidden.contains(compositeKey) {
            hidden.remove(compositeKey)
        } else {
            hidden.insert(compositeKey)
        }
        settings.hiddenBuckets = hidden
        Haptics.light()
    }

    private func isBucketHidden(_ bucket: ProviderQuotaBucket, for provider: AgentProvider) -> Bool {
        let compositeKey = "\(provider.persistedToken):\(bucket.key)"
        return settings.hiddenBuckets.contains(compositeKey)
    }

    private func buckets(for provider: AgentProvider) -> [ProviderQuotaBucket] {
        let token = provider.persistedToken
        let displayable = store.snapshotsByProvider[token]?.flatMap(\.displayableQuotaBuckets) ?? []
        var uniqueBuckets: [ProviderQuotaBucket] = []
        for b in displayable where !uniqueBuckets.contains(where: { $0.key == b.key }) {
            uniqueBuckets.append(b)
        }
        return uniqueBuckets
    }

    private func sortedBuckets(for provider: AgentProvider) -> [ProviderQuotaBucket] {
        let unique = buckets(for: provider)
        let token = provider.persistedToken
        if let customOrder = settings.bucketOrders[token] {
            return unique.sorted { lhs, rhs in
                let lhsIdx = customOrder.firstIndex(of: lhs.key) ?? Int.max
                let rhsIdx = customOrder.firstIndex(of: rhs.key) ?? Int.max
                if lhsIdx != rhsIdx {
                    return lhsIdx < rhsIdx
                }
                return lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
        }
        return unique
    }

    private func moveUp(_ provider: AgentProvider) {
        var order = settings.providerOrder
        guard let idx = order.firstIndex(of: provider), idx > 0 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            order.swapAt(idx, idx - 1)
            settings.providerOrder = order
        }
        Haptics.light()
    }

    private func moveDown(_ provider: AgentProvider) {
        var order = settings.providerOrder
        guard let idx = order.firstIndex(of: provider), idx < order.count - 1 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            order.swapAt(idx, idx + 1)
            settings.providerOrder = order
        }
        Haptics.light()
    }

    private func moveBucketUp(_ bucket: ProviderQuotaBucket, for provider: AgentProvider) {
        let token = provider.persistedToken
        let unique = buckets(for: provider)
        var currentKeys = settings.bucketOrders[token] ?? unique.map(\.key)
        guard let idx = currentKeys.firstIndex(of: bucket.key), idx > 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            currentKeys.swapAt(idx, idx - 1)
            settings.bucketOrders[token] = currentKeys
        }
        Haptics.light()
    }

    private func moveBucketDown(_ bucket: ProviderQuotaBucket, for provider: AgentProvider) {
        let token = provider.persistedToken
        let unique = buckets(for: provider)
        var currentKeys = settings.bucketOrders[token] ?? unique.map(\.key)
        guard let idx = currentKeys.firstIndex(of: bucket.key), idx < currentKeys.count - 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            currentKeys.swapAt(idx, idx + 1)
            settings.bucketOrders[token] = currentKeys
        }
        Haptics.light()
    }
}
