import SwiftUI
import OpenBurnBarCore

struct ProviderConnectionsView: View {
    @State private var store = AccountStore()
    @State private var connectionStore = ProviderConnectionStore()
    @State private var showAddSheet = false
    @State private var selectedProvider: AgentProvider?

    var body: some View {
        NavigationStack {
            List {
                Section("Connected") {
                    if store.connections.isEmpty {
                        Text("No providers connected yet.")
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    } else {
                        ForEach(store.connections) { connection in
                            ConnectionRow(
                                connection: connection,
                                onDelete: { Task { await connectionStore.delete(provider: connection.provider) } }
                            )
                        }
                    }
                }
                Section("Available") {
                    ForEach(AgentProvider.allCases) { provider in
                        if !store.connections.contains(where: { $0.provider == provider.persistedToken }) {
                            AvailableProviderRow(provider: provider) {
                                selectedProvider = provider
                                showAddSheet = true
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                if let selectedProvider {
                    AddProviderConnectionView(provider: selectedProvider)
                }
            }
            .task { await store.fetchConnections() }
            .refreshable { await store.fetchConnections() }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - Connection Row

private struct ConnectionRow: View {
    let connection: ProviderConnectionDoc
    let onDelete: () -> Void

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(connection.provider)
    }

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderBadge(provider: providerEnum, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(providerEnum?.displayName ?? connection.provider)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(connection.redactedLabel)
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
            StatusDot(status: connection.status)
        }
        .swipeActions {
            Button(role: .destructive, action: onDelete) {
                Label("Revoke", systemImage: "trash")
            }
        }
    }
}

// MARK: - Available Provider Row

private struct AvailableProviderRow: View {
    let provider: AgentProvider
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: MobileTheme.Spacing.md) {
                ProviderBadge(provider: provider, size: 36)
                Text(provider.displayName)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(MobileTheme.Colors.accent)
            }
        }
    }
}

// MARK: - Status Dot

private struct StatusDot: View {
    let status: ProviderConnectionStatus

    var color: Color {
        switch status {
        case .connected: return MobileTheme.Colors.success
        case .disconnected: return MobileTheme.Colors.textMuted
        case .error: return MobileTheme.Colors.error
        case .stale: return MobileTheme.Colors.warning
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .accessibilityLabel(status.rawValue)
    }
}

#Preview {
    ProviderConnectionsView()
}
