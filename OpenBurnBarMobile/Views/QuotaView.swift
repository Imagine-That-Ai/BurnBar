import SwiftUI
import OpenBurnBarCore

struct QuotaView: View {
    @State private var store = QuotaStore()
    @State private var selectedProvider: String?
    @State private var settings = QuotaSettingsStore()
    @State private var isJiggling = false

    var body: some View {
        ScrollView {
            if store.isLoading && store.visibleProviders.isEmpty {
                loadingPlaceholder
            } else if let error = store.error, store.visibleProviders.isEmpty {
                EmptyStateView(
                    icon: "exclamationmark.icloud.fill",
                    title: "Quota Sync Error",
                    message: "\(error)\n\(signedInDiagnostic)"
                )
            } else if store.visibleProviders.isEmpty {
                EmptyStateView(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "No Quota Data",
                    message: "Open the Mac app to sync provider quota snapshots. Make sure this iPhone is signed into the same OpenBurnBar account as your Mac.\n\(signedInDiagnostic)"
                )
            } else {
                VStack(spacing: MobileTheme.Spacing.xl) {
                    if isJiggling {
                        jigglingSection
                    } else {
                        if !store.urgentProviders.isEmpty {
                            urgentSection
                        }
                        healthySection
                    }
                }
                .padding(.vertical, MobileTheme.Spacing.lg)
            }
        }
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle("Quota")
        .refreshable {
            Haptics.success()
            await store.refresh()
        }
        .task {
            await store.load()
            store.startListening()
        }
        .onDisappear { store.stopListening() }
        .sheet(isPresented: .init(
            get: { selectedProvider != nil },
            set: { if !$0 { selectedProvider = nil } }
        )) {
            if let provider = selectedProvider {
                QuotaDetailSheet(
                    provider: provider,
                    snapshots: store.sortedSnapshots(for: provider),
                    routingState: store.routingState(for: ProviderID(rawValue: provider)),
                    hiddenBuckets: settings.hiddenBuckets,
                    bucketOrders: settings.bucketOrders,
                    displayMode: settings.percentageDisplayMode.rawValue,
                    onRefresh: {
                        await store.refreshAllAccounts(for: ProviderID(rawValue: provider))
                    }
                )
            }
        }
        .toolbar {
            if isJiggling {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: {
                        Haptics.light()
                        let modes = QuotaPercentageDisplayMode.allCases
                        if let idx = modes.firstIndex(of: settings.percentageDisplayMode) {
                            settings.percentageDisplayMode = modes[(idx + 1) % modes.count]
                        }
                    }) {
                        Image(systemName: "percent")
                            .foregroundStyle(MobileTheme.ember)
                    }
                    .accessibilityLabel("Toggle percentage display mode")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            isJiggling = false
                        }
                        Haptics.success()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private var emberBackground: some View {
        EmberSurfaceBackground()
            .onLongPressGesture(minimumDuration: 0.5) {
                if !isJiggling {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isJiggling = true
                    }
                    Haptics.light()
                }
            }
    }

    private var signedInDiagnostic: String {
        if let account = store.currentUserDisplayID, account.isEmpty == false {
            return "Signed into account \(account)."
        }
        return "Not signed in."
    }

    // MARK: - Jiggling Section

    private var jigglingSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Customize Board")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(Array(store.visibleProviders.enumerated()), id: \.element) { index, provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        accountCount: store.accountCount(for: provider),
                        routingState: store.routingState(for: ProviderID(rawValue: provider)),
                        settings: settings,
                        isJiggling: $isJiggling,
                        index: index,
                        totalProviders: store.visibleProviders.count,
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    // MARK: - Urgent Section

    private var urgentSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.error)
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .overlay(warningHalo, alignment: .leading)

            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.urgentProviders, id: \.self) { provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        accountCount: store.accountCount(for: provider),
                        routingState: store.routingState(for: ProviderID(rawValue: provider)),
                        settings: settings,
                        isJiggling: .constant(false),
                        index: 0,
                        totalProviders: 1,
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    private var warningHalo: some View {
        Circle()
            .fill(MobileTheme.Colors.warning.opacity(0.25))
            .frame(width: 12, height: 12)
            .blur(radius: 6)
    }

    // MARK: - Healthy Section

    private var healthySection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Healthy")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .overlay(healthyPulse, alignment: .leading)

            LazyVStack(spacing: MobileTheme.Spacing.md) {
                ForEach(store.healthyProviders, id: \.self) { provider in
                    QuotaProviderCard(
                        provider: provider,
                        snapshots: store.snapshotsByProvider[provider] ?? [],
                        accountCount: store.accountCount(for: provider),
                        routingState: store.routingState(for: ProviderID(rawValue: provider)),
                        settings: settings,
                        isJiggling: .constant(false),
                        index: 0,
                        totalProviders: 1,
                        onTap: { selectedProvider = provider }
                    )
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
        }
    }

    private var healthyPulse: some View {
        Circle()
            .fill(MobileTheme.Colors.success.opacity(0.3))
            .frame(width: 8, height: 8)
            .blur(radius: 4)
    }

    // MARK: - Loading Placeholder

    private var loadingPlaceholder: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            EmberSkeleton(height: 120, cornerRadius: MobileTheme.Radius.lg)
            EmberSkeleton(height: 120, cornerRadius: MobileTheme.Radius.lg)
            EmberSkeleton(height: 120, cornerRadius: MobileTheme.Radius.lg)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.top, MobileTheme.Spacing.xl)
    }
}

// MARK: - Quota Provider Card

struct QuotaProviderCard: View {
    let provider: String
    let snapshots: [ProviderQuotaSnapshot]
    let accountCount: Int
    let routingState: ProviderRoutingStateSnapshot?
    @Bindable var settings: QuotaSettingsStore
    @Binding var isJiggling: Bool
    var index: Int
    var totalProviders: Int
    let onTap: () -> Void

    var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(ProviderID(rawValue: provider))
    }

    private var attributedSnapshots: [ProviderQuotaSnapshot] {
        snapshots.filter { $0.accountID != nil }
    }

    private var hasMultipleAccounts: Bool {
        accountCount > 1 || attributedSnapshots.count > 1
    }

    @State private var phase: CGFloat = 0

    var body: some View {
        Button(action: {
            if !isJiggling { onTap() }
        }) {
            UnifiedGlassCard {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    headerRow
                    accountInfoRow
                    routingRow
                    bucketRow
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Tap to see per-account quota detail."))
        .rotationEffect(.degrees(isJiggling ? sin(phase) * 1.5 : 0))
        .onAppear {
            if isJiggling { startJiggling() }
        }
        .onChange(of: isJiggling) { _, newValue in
            if newValue { startJiggling() }
            else { phase = 0 }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            if !isJiggling {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    isJiggling = true
                }
                Haptics.light()
            }
        }
    }

    private func startJiggling() {
        withAnimation(.linear(duration: 0.12).repeatForever(autoreverses: true)) {
            phase = .pi / 2
        }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderAvatar(provider: providerEnum, mode: .aurora, size: 44)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(providerEnum?.displayName ?? provider)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text(accountCountLabel)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    if hasUrgentBucket {
                        Text("·")
                            .font(MobileTheme.Typography.footnote)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text("Quota under pressure")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.warning)
                    }
                }
                if !storageScopes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(storageScopes, id: \.self) { scope in
                            ProviderAccountStorageChip(scope: scope, compact: true)
                        }
                    }
                }
            }
            Spacer()
            if isJiggling {
                HStack(spacing: 12) {
                    Button {
                        moveProviderUp()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                    }
                    .disabled(index == 0)
                    .foregroundStyle(index == 0 ? .secondary.opacity(0.3) : MobileTheme.ember)

                    Button {
                        moveProviderDown()
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.headline)
                    }
                    .disabled(index == totalProviders - 1)
                    .foregroundStyle(index == totalProviders - 1 ? .secondary.opacity(0.3) : MobileTheme.ember)
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Account Info

    private var accountInfoRow: some View {
        Group {
            if hasMultipleAccounts, let primaryName = primaryAccountName {
                Text("Showing \(primaryName)\(remainingAccountsLabel) — tap for full breakdown")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var routingRow: some View {
        if let providerEnum,
           let routingState,
           routingState.hasMeaningfulRoutingDetail {
            ProviderRoutingCockpit(provider: providerEnum, state: routingState, compact: true)
        }
    }

    // MARK: - Bucket

    @ViewBuilder
    private var bucketRow: some View {
        if isJiggling, let providerEnum {
            let bucketsList = allBuckets(for: providerEnum)
            VStack(spacing: 8) {
                ForEach(Array(bucketsList.enumerated()), id: \.element.key) { bIdx, bucket in
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        Button {
                            toggleBucketVisibility(bucket, for: providerEnum)
                        } label: {
                            Image(systemName: isBucketHidden(bucket, for: providerEnum) ? "eye.slash" : "eye")
                                .foregroundStyle(isBucketHidden(bucket, for: providerEnum) ? .secondary : MobileTheme.ember)
                        }

                        UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: true, displayMode: settings.percentageDisplayMode.rawValue)
                            .opacity(isBucketHidden(bucket, for: providerEnum) ? 0.5 : 1.0)

                        HStack(spacing: 12) {
                            Button {
                                moveBucketUp(bucket, for: providerEnum)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.subheadline)
                            }
                            .disabled(bIdx == 0)
                            .foregroundStyle(bIdx == 0 ? .secondary.opacity(0.3) : MobileTheme.ember)

                            Button {
                                moveBucketDown(bucket, for: providerEnum)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.subheadline)
                            }
                            .disabled(bIdx == bucketsList.count - 1)
                            .foregroundStyle(bIdx == bucketsList.count - 1 ? .secondary.opacity(0.3) : MobileTheme.ember)
                        }
                    }
                }
            }
        } else if let bucket = mostPressuredBucket, let providerEnum {
            UnifiedQuotaSignalView(bucket: bucket, provider: providerEnum, compact: true, displayMode: settings.percentageDisplayMode.rawValue)
        } else {
            QuotaPlaceholderRow()
        }
    }

    private var accountCountLabel: String {
        if accountCount == 0 { return "No accounts attributed" }
        return accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    private var storageScopes: [ProviderAccountStorageScope] {
        let scopes = snapshots.compactMap(\.accountStorageScope)
        let order: [ProviderAccountStorageScope] = [
            .cloudRefreshable,
            .serverPrivate,
            .deviceKeychain,
            .localOnly
        ]
        var seen = Set<ProviderAccountStorageScope>()
        return order.filter { scope in
            if scopes.contains(scope) {
                seen.insert(scope).inserted
            } else {
                false
            }
        }
    }

    private var hasUrgentBucket: Bool {
        snapshots.flatMap(\.buckets).contains { bucket in
            guard let fraction = bucket.displayRemainingFraction else { return false }
            return fraction < 0.25
        }
    }

    private var primaryAccountName: String? {
        attributedSnapshots.first?.accountLabel ?? attributedSnapshots.first?.accountID
    }

    private var remainingAccountsLabel: String {
        let extra = max(attributedSnapshots.count - 1, 0)
        if extra == 0 { return "" }
        return ", +\(extra) more"
    }

    private var mostPressuredBucket: ProviderQuotaBucket? {
        let customized = snapshots
            .flatMap { $0.customizedBuckets(hiddenBuckets: settings.hiddenBuckets, bucketOrders: settings.bucketOrders) }
        return customized
            .compactMap { bucket -> (bucket: ProviderQuotaBucket, fraction: Double)? in
                guard let fraction = bucket.displayRemainingFraction else { return nil }
                return (bucket, fraction)
            }
            .min { $0.fraction < $1.fraction }?
            .bucket ?? customized.first ?? snapshots.first?.buckets.first
    }

    // MARK: - Jiggling Actions

    private func moveProviderUp() {
        guard let p = providerEnum else { return }
        var order = settings.providerOrder
        guard let idx = order.firstIndex(of: p), idx > 0 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            order.swapAt(idx, idx - 1)
            settings.providerOrder = order
        }
        Haptics.light()
    }

    private func moveProviderDown() {
        guard let p = providerEnum else { return }
        var order = settings.providerOrder
        guard let idx = order.firstIndex(of: p), idx < order.count - 1 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            order.swapAt(idx, idx + 1)
            settings.providerOrder = order
        }
        Haptics.light()
    }

    private func allBuckets(for p: AgentProvider) -> [ProviderQuotaBucket] {
        let displayable = snapshots.flatMap(\.displayableQuotaBuckets)
        var uniqueBuckets: [ProviderQuotaBucket] = []
        for b in displayable where !uniqueBuckets.contains(where: { $0.key == b.key }) {
            uniqueBuckets.append(b)
        }
        let token = p.persistedToken
        if let customOrder = settings.bucketOrders[token] {
            return uniqueBuckets.sorted { lhs, rhs in
                let lhsIdx = customOrder.firstIndex(of: lhs.key) ?? Int.max
                let rhsIdx = customOrder.firstIndex(of: rhs.key) ?? Int.max
                if lhsIdx != rhsIdx {
                    return lhsIdx < rhsIdx
                }
                return lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
        }
        return uniqueBuckets
    }

    private func moveBucketUp(_ bucket: ProviderQuotaBucket, for p: AgentProvider) {
        let token = p.persistedToken
        let unique = allBuckets(for: p)
        var currentKeys = settings.bucketOrders[token] ?? unique.map(\.key)
        guard let idx = currentKeys.firstIndex(of: bucket.key), idx > 0 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            currentKeys.swapAt(idx, idx - 1)
            settings.bucketOrders[token] = currentKeys
        }
        Haptics.light()
    }

    private func moveBucketDown(_ bucket: ProviderQuotaBucket, for p: AgentProvider) {
        let token = p.persistedToken
        let unique = allBuckets(for: p)
        var currentKeys = settings.bucketOrders[token] ?? unique.map(\.key)
        guard let idx = currentKeys.firstIndex(of: bucket.key), idx < currentKeys.count - 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            currentKeys.swapAt(idx, idx + 1)
            settings.bucketOrders[token] = currentKeys
        }
        Haptics.light()
    }

    private func toggleBucketVisibility(_ bucket: ProviderQuotaBucket, for p: AgentProvider) {
        let compositeKey = "\(p.persistedToken):\(bucket.key)"
        var hidden = settings.hiddenBuckets
        if hidden.contains(compositeKey) {
            hidden.remove(compositeKey)
        } else {
            hidden.insert(compositeKey)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            settings.hiddenBuckets = hidden
        }
        Haptics.light()
    }

    private func isBucketHidden(_ bucket: ProviderQuotaBucket, for p: AgentProvider) -> Bool {
        let compositeKey = "\(p.persistedToken):\(bucket.key)"
        return settings.hiddenBuckets.contains(compositeKey)
    }

    private var accessibilityLabel: String {
        let name = providerEnum?.displayName ?? provider
        var parts: [String] = [name, accountCountLabel]
        if let routingState, let active = routingState.activeAccount {
            parts.append("active account \(active.accountLabel)")
        }
        if hasUrgentBucket { parts.append("quota under pressure") }
        if let bucket = mostPressuredBucket, let pct = bucket.displayRemainingPercent {
            parts.append("\(bucket.name) \(Int(pct.rounded())) percent remaining")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Quota Placeholder Row

private struct QuotaPlaceholderRow: View {
    var body: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No quota signal yet")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        QuotaView()
    }
}
