import SwiftUI
import FirebaseAuth
import OpenBurnBarCore

struct AccountView: View {
    @State private var store = AccountStore()
    @State private var showConnections = false

    var body: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.xl) {
                profileCard
                syncHealthCard
                connectionsCard
                appCheckCard
                signOutButton
            }
            .padding(.vertical, MobileTheme.Spacing.lg)
        }
        .background(MobileTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Account")
        .refreshable { await store.fetchConnections() }
        .task { await store.fetchConnections() }
        .sheet(isPresented: $showConnections) {
            ProviderConnectionsView()
        }
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.accent.opacity(0.15))
                    .frame(width: 80, height: 80)
                if let photoURL = store.user?.photoURL {
                    AsyncImage(url: photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(MobileTheme.Colors.accent)
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(MobileTheme.Colors.accent)
                }
            }
            Text(store.user?.displayName ?? store.user?.email ?? "Guest")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            if let email = store.user?.email {
                Text(email)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Text(store.isSignedIn ? "Signed In" : "Anonymous")
                .font(MobileTheme.Typography.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(store.isSignedIn ? MobileTheme.Colors.success.opacity(0.15) : MobileTheme.Colors.textMuted.opacity(0.15))
                .foregroundStyle(store.isSignedIn ? MobileTheme.Colors.success : MobileTheme.Colors.textMuted)
                .clipShape(Capsule())
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Sync Health

    private var syncHealthCard: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("Sync Health")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            HStack {
                Image(systemName: syncHealthIcon)
                    .foregroundStyle(syncHealthColor)
                Text(store.syncHealth.displayText)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Spacer()
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var syncHealthIcon: String {
        switch store.syncHealth {
        case .unknown: return "questionmark.circle"
        case .healthy: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var syncHealthColor: Color {
        switch store.syncHealth {
        case .unknown: return MobileTheme.Colors.textMuted
        case .healthy: return MobileTheme.Colors.success
        case .stale: return MobileTheme.Colors.warning
        case .error: return MobileTheme.Colors.error
        }
    }

    // MARK: - Connections Card

    private var connectionsCard: some View {
        Button {
            showConnections = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                    Text("Provider Connections")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("\(store.connections.count) connected")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .padding(MobileTheme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(MobileTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(MobileTheme.Colors.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - App Check Card

    private var appCheckCard: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Text("App Check")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(MobileTheme.Colors.success)
                Text("Firebase App Check is active")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
            }
        }
        .padding(MobileTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface)
        )
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Sign Out

    private var signOutButton: some View {
        Button {
            Task { await store.signOut() }
        } label: {
            Text("Sign Out")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.error)
                .frame(maxWidth: .infinity)
                .padding(MobileTheme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(MobileTheme.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.Colors.error.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
}
