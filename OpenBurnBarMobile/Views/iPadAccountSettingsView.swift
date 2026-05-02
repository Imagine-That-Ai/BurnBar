import SwiftUI
import OpenBurnBarCore

struct iPadAccountSettingsView: View {
    @State private var authStore = AuthStore()
    @State private var showSignOutConfirmation = false

    var body: some View {
        Form {
            profileSection
            authStatusSection
            actionsSection
        }
        .formStyle(.grouped)
        .task { authStore.clearError() }
        .alert("Sign Out?", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                authStore.signOut()
            }
        } message: {
            Text("You will need to sign in again to access your data.")
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            HStack(spacing: MobileTheme.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(MobileTheme.Colors.accent.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(MobileTheme.Colors.accent)
                }
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                    if let identity = authStore.currentIdentity {
                        Text(identity.displayName ?? identity.email ?? "Authenticated User")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if let email = identity.email {
                            Text(email)
                                .font(MobileTheme.Typography.body)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                        Text("Provider: \(providerLabel(for: identity))")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    } else {
                        Text("Not signed in")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, MobileTheme.Spacing.sm)
        }
    }

    private func providerLabel(for identity: MobileAuthIdentity) -> String {
        // MobileAuthIdentity may expose provider info differently.
        // Fallback to a generic label if provider detail is unavailable.
        if let email = identity.email, email.contains("@") {
            return "Email"
        }
        return "Cloud"
    }

    // MARK: - Auth Status

    private var authStatusSection: some View {
        Section("Status") {
            HStack {
                Text("Authentication")
                    .font(MobileTheme.Typography.body)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(authStore.state.isSignedIn ? MobileTheme.Colors.success : MobileTheme.Colors.error)
                        .frame(width: 8, height: 8)
                    Text(authStore.state.isSignedIn ? "Signed In" : "Signed Out")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
            }
            if let error = authStore.lastError {
                Label(error.label, systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.error)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showSignOutConfirmation = true
            }
            .disabled(!authStore.state.isSignedIn)
        }
    }
}
