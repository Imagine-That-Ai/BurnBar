import SwiftUI
import OpenBurnBarCore

struct ProviderConnectionsView: View {
    let showsDoneButton: Bool

    @State private var store = AccountStore()
    @State private var connectionStore = ProviderConnectionStore()
    @State private var showAddSheet = false
    @State private var selectedProvider: AgentProvider?
    @State private var pendingError: String?

    @Environment(\.dismiss) private var dismiss

    init(showsDoneButton: Bool = true) {
        self.showsDoneButton = showsDoneButton
    }

    private var groupedAccounts: [(providerID: ProviderID, accounts: [ProviderAccountDoc])] {
        connectionStore.accountsByProvider
    }

    private var hasFirstClassAccounts: Bool {
        !connectionStore.accounts.isEmpty
    }

    private var availableProviders: [AgentProvider] {
        AgentProvider.mobileAccountConnectableProviders
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Provider Accounts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsDoneButton {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .sheet(isPresented: $showAddSheet) {
                    AddProviderConnectionView(provider: selectedProvider)
                }
                .alert(
                    "Couldn't update account",
                    isPresented: Binding(
                        get: { pendingError != nil },
                        set: { if !$0 { pendingError = nil } }
                    ),
                    actions: {
                        Button("OK", role: .cancel) { pendingError = nil }
                    },
                    message: {
                        Text(pendingError ?? "")
                    }
                )
                .task {
                    await store.fetchConnections()
                    await connectionStore.load()
                }
                .refreshable {
                    await store.fetchConnections()
                    await connectionStore.load()
                }
                .onChange(of: connectionStore.error) { _, newValue in
                    pendingError = newValue
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                if connectionStore.isLoading && !hasFirstClassAccounts && store.connections.isEmpty {
                    ConnectionLoadingPlaceholder()
                } else if !hasFirstClassAccounts && store.connections.isEmpty {
                    ConnectionsEmptyState {
                        // Open the searchable provider grid so users see the
                        // full list of supported providers in one place
                        // instead of being silently routed to whichever
                        // provider happens to be first.
                        selectedProvider = nil
                        showAddSheet = true
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(groupedAccounts, id: \.providerID) { group in
                        ProviderAccountGroupSection(
                            providerID: group.providerID,
                            accounts: group.accounts,
                            routingState: connectionStore.routingState(for: group.providerID),
                            isRefreshingID: connectionStore.refreshingAccountID,
                            isDeletingID: connectionStore.deletingAccountID,
                            onRefresh: { account in
                                Task { await connectionStore.refresh(account: account) }
                            },
                            onDelete: { account in
                                Task { await connectionStore.delete(account: account) }
                            },
                            onAddMore: {
                                if let provider = AgentProvider.fromProviderID(group.providerID) {
                                    selectedProvider = provider
                                    showAddSheet = true
                                }
                            }
                        )
                    }
                    if !hasFirstClassAccounts {
                        ForEach(store.connections) { connection in
                            LegacyConnectionRow(
                                connection: connection,
                                onDelete: { Task { await connectionStore.deleteLegacy(provider: connection.provider) } }
                            )
                        }
                    }
                }
            } header: {
                connectedSectionHeader
            } footer: {
                if hasFirstClassAccounts {
                    Text("OpenBurnBar shows where each account is stored. Cloud accounts can refresh from any signed-in device. Mac Keychain accounts only refresh from your Mac.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            Section {
                ForEach(availableProviders) { provider in
                    AvailableProviderRow(
                        provider: provider,
                        accountCount: connectionStore.accounts.filter { $0.providerID == provider.providerID && $0.status != .deleted }.count
                    ) {
                        selectedProvider = provider
                        showAddSheet = true
                    }
                }
            } header: {
                Text("Add Account")
            } footer: {
                Text("Accounts added here appear on signed-in Macs. Backend-refreshable providers update from cloud; local quota bridges refresh from the Mac.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }

    private var connectedSectionHeader: some View {
        HStack {
            Text("Connected")
            Spacer()
            if hasFirstClassAccounts {
                Text("\(connectionStore.accounts.filter { $0.status != .deleted }.count)")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .accessibilityLabel("\(connectionStore.accounts.filter { $0.status != .deleted }.count) connected accounts")
            }
        }
    }
}

// MARK: - Connections Empty State

private struct ConnectionsEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.accent.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.accent)
            }
            .padding(.top, MobileTheme.Spacing.xl)

            Text("No provider accounts yet")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            Text("Connect a provider with real quota or routing credentials. You can add multiple accounts per provider — for example, one personal and one work Cursor account.")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileTheme.Spacing.lg)

            Button(action: onAdd) {
                Label("Connect a Provider", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(MobileTheme.Colors.accent)
            .padding(.horizontal, MobileTheme.Spacing.xl)
            .padding(.bottom, MobileTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ConnectionLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            ForEach(0..<2, id: \.self) { _ in
                EmberSkeleton(height: 72, cornerRadius: MobileTheme.Radius.md)
            }
        }
        .padding(.vertical, MobileTheme.Spacing.sm)
        .listRowInsets(EdgeInsets(top: MobileTheme.Spacing.sm, leading: MobileTheme.Spacing.lg, bottom: MobileTheme.Spacing.sm, trailing: MobileTheme.Spacing.lg))
        .listRowBackground(Color.clear)
    }
}

// MARK: - Provider Account Group (per-provider header + child accounts)

private struct ProviderAccountGroupSection: View {
    let providerID: ProviderID
    let accounts: [ProviderAccountDoc]
    let routingState: ProviderRoutingStateSnapshot?
    let isRefreshingID: String?
    let isDeletingID: String?
    let onRefresh: (ProviderAccountDoc) -> Void
    let onDelete: (ProviderAccountDoc) -> Void
    let onAddMore: () -> Void

    var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(providerID)
    }

    private var activeAccounts: [ProviderAccountDoc] {
        accounts.filter { $0.status != .deleted }
    }

    var body: some View {
        Group {
            providerHeaderRow

            if let providerEnum,
               let routingState,
               routingState.hasMeaningfulRoutingDetail {
                ProviderRoutingCockpit(provider: providerEnum, state: routingState, compact: true)
                    .listRowInsets(EdgeInsets(top: 4, leading: MobileTheme.Spacing.lg, bottom: 4, trailing: MobileTheme.Spacing.lg))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(activeAccounts) { account in
                AccountRow(
                    account: account,
                    routingHint: routingHint(for: account),
                    isRefreshing: isRefreshingID == account.id,
                    isDeleting: isDeletingID == account.id,
                    onRefresh: { onRefresh(account) },
                    onDelete: { onDelete(account) }
                )
            }

            if activeAccounts.isEmpty {
                Text("All accounts removed. Tap Add to reconnect.")
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func routingHint(for account: ProviderAccountDoc) -> AccountRoutingHint? {
        guard let routingState else { return nil }
        if routingState.activeAccount?.accountID == account.id {
            return AccountRoutingHint(
                role: .active,
                quotaState: routingState.activeAccount?.quotaState ?? .unknown
            )
        }
        if routingState.nextFallback?.accountID == account.id {
            return AccountRoutingHint(
                role: .nextFallback,
                quotaState: routingState.nextFallback?.quotaState ?? .unknown
            )
        }
        if let blocked = routingState.exhaustedOrCoolingDownAccounts.first(where: { $0.accountID == account.id }) {
            return AccountRoutingHint(role: .blocked, quotaState: blocked.quotaState)
        }
        return nil
    }

    private var providerHeaderRow: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderAvatar(provider: providerEnum, mode: .aurora, size: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(providerEnum?.displayName ?? providerID.rawValue)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text(activeAccounts.isEmpty
                         ? "No accounts"
                         : "\(activeAccounts.count) account\(activeAccounts.count == 1 ? "" : "s")")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    if !activeAccounts.isEmpty {
                        Text("·")
                            .font(MobileTheme.Typography.footnote)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        ProviderAccountStorageSummary(accounts: activeAccounts)
                    }
                }
            }

            Spacer()

            Button(action: onAddMore) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(MobileTheme.Colors.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add another \(providerEnum?.displayName ?? "account")")
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Account Row

/// Tells the connections row which lane an account currently occupies in the
/// router. Mirrors the macOS `ProviderAccountRoutingHint` so a single account
/// reads consistently across iPhone, iPad, and Mac.
struct AccountRoutingHint {
    enum Role {
        case active
        case nextFallback
        case blocked
    }

    let role: Role
    let quotaState: ProviderRoutingQuotaState
}

private struct AccountRow: View {
    let account: ProviderAccountDoc
    var routingHint: AccountRoutingHint?
    let isRefreshing: Bool
    let isDeleting: Bool
    let onRefresh: () -> Void
    let onDelete: () -> Void

    private var canRefreshFromMobile: Bool {
        ProviderAccountStorageVisual.canRefreshFromMobile(account.storageScope)
    }

    private var detailLine: String? {
        let hint = account.identityHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hint, !hint.isEmpty, hint != account.label {
            return hint
        }
        let redacted = account.redactedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !redacted.isEmpty, redacted != account.label {
            return redacted
        }
        return nil
    }

    private var refreshHistory: String? {
        if isRefreshing { return "Refreshing now…" }
        if let lastError = account.lastErrorCode?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty {
            return "Last error: \(lastError)"
        }
        if let last = account.lastRefreshAt {
            return "Refreshed \(last.formatted(.relative(presentation: .named)))"
        }
        if let validated = account.lastValidatedAt {
            return "Validated \(validated.formatted(.relative(presentation: .named)))"
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
            // Indent rail signals "child of provider above" without nesting cards.
            VStack {
                Capsule()
                    .fill(ProviderAccountStatusVisual.tint(account.status, isRefreshing: isRefreshing).opacity(0.6))
                    .frame(width: 3)
            }
            .frame(width: 3)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: MobileTheme.Spacing.xs) {
                    Text(account.label)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if account.isDefault {
                        DefaultAccountChip(compact: true)
                    }

                    if let routingHint {
                        routingHintChip(routingHint)
                    }

                    Spacer(minLength: MobileTheme.Spacing.xs)

                    ProviderAccountStatusChip(status: account.status, isRefreshing: isRefreshing, compact: true)
                }

                if let detailLine {
                    Text(detailLine)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: MobileTheme.Spacing.xs) {
                    ProviderAccountStorageChip(scope: account.storageScope, compact: true)
                    if let refreshHistory {
                        Text("·")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(refreshHistory)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(account.status == .error ? MobileTheme.Colors.warning : MobileTheme.Colors.textMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !canRefreshFromMobile {
                    Text("Refreshes from your Mac. Open OpenBurnBar on macOS to update this account.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .opacity(isDeleting ? 0.5 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRefreshFromMobile {
                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .tint(MobileTheme.Colors.accent)
                .accessibilityLabel("Refresh \(account.label)")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove \(account.label)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text(ProviderAccountStorageVisual.description(account.storageScope)))
    }

    private var accessibilityLabel: String {
        var parts: [String] = [account.label]
        if account.isDefault { parts.append("default") }
        if let routingHint {
            parts.append(routingHintAccessibilityFragment(routingHint))
        }
        parts.append(ProviderAccountStatusVisual.label(account.status, isRefreshing: isRefreshing))
        parts.append("stored in \(ProviderAccountStorageVisual.label(account.storageScope))")
        if let hint = account.identityHint, !hint.isEmpty, hint != account.label {
            parts.append(hint)
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func routingHintChip(_ hint: AccountRoutingHint) -> some View {
        let style = routingHintStyle(hint)
        HStack(spacing: 3) {
            Image(systemName: style.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(style.label)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(style.tint.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel(routingHintAccessibilityFragment(hint))
    }

    private struct RoutingHintStyle {
        let label: String
        let icon: String
        let tint: Color
    }

    private func routingHintStyle(_ hint: AccountRoutingHint) -> RoutingHintStyle {
        switch hint.role {
        case .active:
            return RoutingHintStyle(
                label: "Active",
                icon: "arrowtriangle.right.circle.fill",
                tint: MobileTheme.Colors.success
            )
        case .nextFallback:
            return RoutingHintStyle(
                label: "Next",
                icon: "arrow.triangle.branch",
                tint: MobileTheme.amber
            )
        case .blocked:
            return RoutingHintStyle(
                label: ProviderRoutingMobileVisual.label(hint.quotaState),
                icon: ProviderRoutingMobileVisual.iconName(hint.quotaState),
                tint: ProviderRoutingMobileVisual.tint(hint.quotaState)
            )
        }
    }

    private func routingHintAccessibilityFragment(_ hint: AccountRoutingHint) -> String {
        switch hint.role {
        case .active:
            return "currently active"
        case .nextFallback:
            return "next fallback"
        case .blocked:
            return "blocked: \(ProviderRoutingMobileVisual.label(hint.quotaState).lowercased())"
        }
    }
}

// MARK: - Legacy Connection Row (single-account, pre-multi-account installs)

private struct LegacyConnectionRow: View {
    let connection: ProviderConnectionDoc
    let onDelete: () -> Void

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(connection.provider)
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderAvatar(provider: providerEnum, mode: .aurora, size: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(providerEnum?.displayName ?? connection.provider)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.medium)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                HStack(spacing: 6) {
                    Text(connection.redactedLabel)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text("·")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text("Legacy single-account")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            Spacer()
            LegacyStatusChip(status: connection.status)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

private struct LegacyStatusChip: View {
    let status: ProviderConnectionStatus

    private var tint: Color {
        switch status {
        case .connected: return MobileTheme.Colors.success
        case .disconnected: return MobileTheme.Colors.textMuted
        case .error: return MobileTheme.Colors.error
        case .stale: return MobileTheme.Colors.warning
        }
    }

    private var label: String {
        switch status {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .error: return "Needs attention"
        case .stale: return "Stale"
        }
    }

    var body: some View {
        Text(label)
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel(label)
    }
}

// MARK: - Available Provider Row

private struct AvailableProviderRow: View {
    let provider: AgentProvider
    let accountCount: Int
    let onTap: () -> Void

    /// One-line setup hint pulled from the shared `ProviderSetupGuide` so the
    /// list reads like a menu instead of a wall of avatars. Falls through to
    /// the generic "Add another / Connect for the first time" line below it.
    private var setupHint: String {
        ProviderSetupGuide.guide(for: provider).oneLineHint
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ProviderAvatar(provider: provider, mode: .aurora, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if accountCount > 0 {
                            Text("· \(accountCount)")
                                .font(MobileTheme.Typography.tiny)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.success)
                        }
                    }
                    Text(setupHint)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(accountCount > 0 ? "Tap to add another account" : "Tap to connect")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(MobileTheme.Colors.accent)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName), \(accountCount > 0 ? "add another account" : "connect for the first time"). \(setupHint)")
    }
}

#Preview {
    ProviderConnectionsView()
}
