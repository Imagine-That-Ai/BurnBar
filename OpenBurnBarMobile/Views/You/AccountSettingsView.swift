import SwiftUI
import OpenBurnBarCore

// MARK: - Account Settings
//
// Apple-ID-style account page reached from the Settings profile banner.
// Consolidates what used to be the hub's separate "Account" and "Cloud"
// rows: identity, sign in / sign out, the OpenBurnBar Cloud subscription
// row, and account deletion. Native grouped `Form` — no Aurora chrome.

struct AccountSettingsView: View {
    let authStore: AuthStore

    @Environment(\.cloudSubscriptionStore) private var sharedSubscriptionStore
    @State private var localSubscriptionStore = HostedQuotaSubscriptionStore()
    @State private var didLoadLocalSubscription = false
    @State private var showSignIn = false
    @State private var showDeleteAccountConfirmation = false
    @State private var accountDeletionError: String?

    var body: some View {
        Form {
            Section {
                profileRow
                    .settingsAnchor(SettingsAnchor.accountRow)
            }

            Section {
                NavigationLink(value: SettingsPageRoute.cloud) {
                    cloudRow
                }
                .settingsAnchor(SettingsAnchor.cloudRow)
            } header: {
                Text("Subscription")
            } footer: {
                Text("Quota, encrypted backups, and Hermes access across every device you sign in on.")
            }

            Section {
                if authStore.currentIdentity == nil {
                    Button {
                        showSignIn = true
                    } label: {
                        SettingsLabel(
                            icon: "person.crop.circle.badge.checkmark",
                            color: MobileTheme.ember,
                            title: "Sign in for Cloud"
                        )
                    }
                } else {
                    Button(role: .destructive) {
                        authStore.signOut()
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }

            Section {
                deleteAccountButton
            } footer: {
                Text("Deleting your account permanently removes your OpenBurnBar cloud data, provider account records, devices, usage history, and sign-in. This cannot be undone.")
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete OpenBurnBar account?",
            isPresented: $showDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your OpenBurnBar cloud data, provider account records, devices, usage history, and sign-in. This cannot be undone.")
        }
        .alert("Account deletion failed", isPresented: deletionErrorBinding) {
            Button("OK", role: .cancel) { accountDeletionError = nil }
        } message: {
            Text(accountDeletionError ?? "Try signing in again, then delete the account from Settings.")
        }
        .sheet(isPresented: $showSignIn) {
            SignInScene(authStore: authStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: authStore.state.isSignedIn) { _, isSignedIn in
            if isSignedIn { showSignIn = false }
        }
        .task {
            if sharedSubscriptionStore == nil, !didLoadLocalSubscription {
                didLoadLocalSubscription = true
                await localSubscriptionStore.load()
            }
        }
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                if let identity = authStore.currentIdentity {
                    Text(identity.displayName ?? identity.email ?? "OpenBurnBar account")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let email = identity.email, identity.displayName != nil {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(subscriptionStore.isActive ? "OpenBurnBar Cloud · Active" : "Free plan")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not signed in")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Sign in to sync quota, backups, and Hermes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Cloud row

    @ViewBuilder
    private var cloudRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenBurnBar Cloud")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(cloudRowSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(UnifiedDesignSystem.mercuryGradient)
                    .frame(width: 29, height: 29)
                Image(systemName: "cloud.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var cloudRowSubtitle: String {
        if subscriptionStore.isActive {
            if let expires = subscriptionStore.expirationDate {
                let formatted = expires.formatted(.dateTime.month(.abbreviated).day())
                return "Active · renews \(formatted)"
            }
            return "Active"
        }
        if let priceText = subscriptionStore.product?.displayPrice {
            return "Upgrade — \(priceText)/mo"
        }
        return "Quota, backups, Hermes — anywhere"
    }

    // MARK: - Delete

    @ViewBuilder
    private var deleteAccountButton: some View {
        Button(role: .destructive) {
            showDeleteAccountConfirmation = true
        } label: {
            HStack(spacing: 10) {
                if authStore.isDeletingAccount {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .foregroundStyle(MobileTheme.Colors.error)
                }
                Text(authStore.isDeletingAccount ? "Deleting account…" : "Delete account")
            }
        }
        .disabled(!authStore.state.isSignedIn || authStore.isDeletingAccount)
        .accessibilityIdentifier("settings.deleteAccount")
        .accessibilityHint("Permanently deletes your OpenBurnBar account and cloud data.")
        .settingsAnchor(SettingsAnchor.deleteAccount)
    }

    // MARK: - Helpers

    private var subscriptionStore: HostedQuotaSubscriptionStore {
        sharedSubscriptionStore ?? localSubscriptionStore
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { accountDeletionError != nil },
            set: { if !$0 { accountDeletionError = nil } }
        )
    }

    private func deleteAccount() async {
        await authStore.deleteAccount()
        if let error = authStore.lastError {
            accountDeletionError = error.label
        }
    }
}
