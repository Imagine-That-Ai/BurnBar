import SwiftUI
import FirebaseAuth
import OpenBurnBarCore

struct AccountView: View {
    @State private var store = AccountStore()
    @State private var showConnections = false
    @State private var showSignOutConfirmation = false

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
        .background(emberBackground.ignoresSafeArea())
        .navigationTitle("Account")
        .refreshable {
            Haptics.success()
            await store.fetchConnections()
        }
        .task { await store.fetchConnections() }
        .sheet(isPresented: $showConnections) {
            ProviderConnectionsView()
        }
        .confirmationDialog("Sign Out?", isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Haptics.error()
                Task { await store.signOut() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You will need to sign in again to access your data.")
        }
    }

    private var emberBackground: some View {
        EmberSurfaceBackground()
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        UnifiedGlassCard {
            VStack(spacing: MobileTheme.Spacing.md) {
                ZStack {
                    // Animated gradient halo
                    animatedHalo

                    avatarContent
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                }
                .frame(width: 96, height: 96)

                Text(store.user?.displayName ?? store.user?.email ?? "Guest")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                if let email = store.user?.email {
                    Text(email)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }

                accountHealthLine

                statusChip
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var avatarContent: some View {
        Group {
            if let photoURL = store.user?.photoURL {
                AsyncImage(url: photoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallbackAvatar
                }
            } else {
                fallbackAvatar
            }
        }
    }

    private var fallbackAvatar: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 36))
            .foregroundStyle(MobileTheme.Colors.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MobileTheme.Colors.accent.opacity(0.15))
    }

    private var animatedHalo: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        MobileTheme.Colors.accent.opacity(0.3),
                        MobileTheme.Colors.amber.opacity(0.2),
                        MobileTheme.Colors.accent.opacity(0.0),
                        MobileTheme.Colors.accent.opacity(0.3)
                    ],
                    center: .center
                ),
                lineWidth: 2
            )
            .rotationEffect(.degrees(haloRotation))
            .onAppear {
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                    haloRotation = 360
                }
            }
    }

    @State private var haloRotation: Double = 0

    private var accountHealthLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(syncDotColor)
                .frame(width: 6, height: 6)
            Text("Account health: \(healthLabel)")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    private var healthLabel: String {
        let syncOk = store.syncHealth == .healthy
        let hasConnections = !store.connections.isEmpty
        switch (syncOk, hasConnections) {
        case (true, true):  return "Excellent"
        case (true, false): return "Sync OK — no providers"
        case (false, true): return "Check sync"
        default:            return "Setup incomplete"
        }
    }

    private var syncDotColor: Color {
        store.syncHealth == .healthy ? MobileTheme.Colors.success : MobileTheme.Colors.warning
    }

    private var statusChip: some View {
        Text(store.isSignedIn ? "Signed In" : "Anonymous")
            .font(MobileTheme.Typography.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(store.isSignedIn ? MobileTheme.Colors.success.opacity(0.15) : MobileTheme.Colors.textMuted.opacity(0.15))
            .foregroundStyle(store.isSignedIn ? MobileTheme.Colors.success : MobileTheme.Colors.textMuted)
            .clipShape(Capsule())
    }

    // MARK: - Sync Health

    private var syncHealthCard: some View {
        UnifiedGlassCard {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack {
                    Text("Sync Health")
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                    // Pulsing status dot
                    PulsingStatusDot(color: syncHealthColor)
                }

                HStack(spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: syncHealthIcon)
                        .foregroundStyle(syncHealthColor)
                    Text(store.syncHealth.displayText)
                        .font(MobileTheme.Typography.body)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Spacer()
                }

                if let lastSync = store.lastPublishedAt {
                    Text("Last successful write: \(lastSync, style: .relative) ago")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
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
            UnifiedGlassCard(interactive: true) {
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

                    // Overlapping aurora avatars
                    overlappingAvatars

                    Image(systemName: "chevron.right")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private var overlappingAvatars: some View {
        let providers = store.connections.prefix(5).compactMap {
            AgentProvider.fromProviderID(ProviderID(rawValue: $0.providerID))
        }
        return ZStack {
            ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                ProviderAvatar(provider: provider, mode: .aurora, size: 28)
                    .offset(x: CGFloat(index) * -20)
                    .zIndex(Double(providers.count - index))
            }
        }
        .frame(width: max(0, CGFloat(providers.count) * 20 - 8), height: 32)
    }

    // MARK: - App Check Card

    private var appCheckCard: some View {
        UnifiedGlassCard {
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
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    // MARK: - Sign Out

    private var signOutButton: some View {
        Button {
            showSignOutConfirmation = true
        } label: {
            Text("Sign Out")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.error)
                .frame(maxWidth: .infinity)
                .padding(MobileTheme.Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(MobileTheme.Colors.error.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(MobileTheme.Colors.error.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

// MARK: - Pulsing Status Dot

private struct PulsingStatusDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

#Preview {
    NavigationStack {
        AccountView()
    }
}
