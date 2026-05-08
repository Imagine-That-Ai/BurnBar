import SwiftUI
import FirebaseAuth

// MARK: - Account Settings View

/// Settings view for account management and authentication
struct AccountSettingsView: View {
    let currentUser: User?
    let isAnonymous: Bool
    let isFirebaseAvailable: Bool
    let onLinkGoogle: () async throws -> Void
    let onEmailSignIn: (String, String) async throws -> Void
    let onEmailSignUp: (String, String) async throws -> Void
    let onLinkApple: () async throws -> Void
    let onUpgradeToPremium: () -> Void
    let onDeleteAccount: () -> Void
    let onSignOut: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var showEmailLinkSheet = false
    @State private var emailMode: EmailAuthMode = .signIn
    @State private var emailLinkEmail = ""
    @State private var emailLinkPassword = ""
    @State private var emailLinkError: String?
    @State private var authError: String?
    @State private var activeAuthProvider: AuthProviderAction?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Account header
            if let user = currentUser {
                accountHeaderView(user)
            } else {
                anonymousHeaderView
            }

            // Sign-in methods section
            if isAnonymous {
                signInMethodsSection
            } else {
                linkedAccountsSection
            }

            // Premium upgrade section
            premiumSection

            // Actions section
            actionsSection
        }
        .sheet(isPresented: $showEmailLinkSheet) {
            emailLinkSheet
        }
        .alert("Delete Account?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDeleteAccount() }
        } message: {
            Text("This will permanently delete your account and all associated data. This action cannot be undone.")
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func accountHeaderView(_ user: User) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Avatar
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.blaze.opacity(0.2))
                    .frame(width: 64, height: 64)
                if let photoURL = user.photoURL {
                    AsyncImage(url: photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(DesignSystem.Colors.blaze)
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                if let displayName = user.displayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                if let email = user.email {
                    Text(email)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text("Account verified")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.success)
                }
            }

            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
    }

    @ViewBuilder
    private var anonymousHeaderView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.textMuted.opacity(0.2))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Anonymous Account")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Sign in to sync your data across devices")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
    }

    @ViewBuilder
    private var signInMethodsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Sign In Methods")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if !isFirebaseAvailable {
                Text("Cloud auth is unavailable in this build. Add a local `GoogleService-Info.plist` to enable Google, Apple, and email authentication.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }

            if let authError {
                Text(authError)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .padding(DesignSystem.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignSystem.Colors.error.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }

            VStack(spacing: 0) {
                signInMethodRow(
                    logo: .apple,
                    title: "Sign in with Apple",
                    subtitle: "Recommended for macOS",
                    provider: .apple,
                    action: onLinkApple
                )
                Divider().background(DesignSystem.Colors.border)
                signInMethodRow(
                    logo: .google,
                    title: "Sign in with Google",
                    subtitle: "Use your Google account",
                    provider: .google,
                    action: onLinkGoogle
                )
                Divider().background(DesignSystem.Colors.border)
                signInMethodRow(
                    logo: .email,
                    title: "Continue with Email",
                    subtitle: "Sign in or create an account",
                    provider: .email,
                    action: {
                        authError = nil
                        emailLinkError = nil
                        showEmailLinkSheet = true
                    }
                )
            }
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func signInMethodRow(
        logo: AuthProviderLogo,
        title: String,
        subtitle: String,
        provider: AuthProviderAction,
        action: @escaping () async throws -> Void
    ) -> some View {
        Button {
            guard isFirebaseAvailable else { return }
            authError = nil
            activeAuthProvider = provider
            Task {
                do {
                    try await action()
                } catch {
                    authError = error.localizedDescription
                }
                activeAuthProvider = nil
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                AuthProviderLogoView(logo: logo, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if activeAuthProvider == provider {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .buttonStyle(.plain)
        .disabled(!isFirebaseAvailable || activeAuthProvider != nil)
    }

    @ViewBuilder
    private var linkedAccountsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Linked Accounts")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            VStack(spacing: 0) {
                linkedAccountRow(
                    logo: .apple,
                    title: "Apple ID",
                    isLinked: currentUser?.providerData.contains { $0.providerID == "apple.com" } ?? false
                )
                Divider().background(DesignSystem.Colors.border)
                linkedAccountRow(
                    logo: .google,
                    title: "Google",
                    isLinked: currentUser?.providerData.contains { $0.providerID == "google.com" } ?? false
                )
            }
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func linkedAccountRow(logo: AuthProviderLogo, title: String, isLinked: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            AuthProviderLogoView(logo: logo, size: 28)

            Text(title)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()

            if isLinked {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Linked")
                        .font(DesignSystem.Typography.tiny)
                }
                .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Button("Link") { }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    @ViewBuilder
    private var premiumSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Subscription")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            HStack(spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Text("Free Plan")
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("Current")
                            .font(DesignSystem.Typography.tiny)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DesignSystem.Colors.success.opacity(0.15))
                            .foregroundStyle(DesignSystem.Colors.success)
                            .clipShape(Capsule())
                    }

                    Text("50 summaries per month")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                Button("Upgrade") { onUpgradeToPremium() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.blaze)
            }
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            if !isAnonymous {
                Button("Sign Out") { onSignOut() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }

            if !isAnonymous {
                Button("Delete Account", role: .destructive) { showDeleteConfirmation = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var emailLinkSheet: some View {
        NavigationStack {
            VStack(spacing: DesignSystem.Spacing.lg) {
                if let error = emailLinkError {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
                }

                TextField("Email", text: $emailLinkEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)

                SecureField("Password", text: $emailLinkPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)

                Picker("Mode", selection: $emailMode) {
                    ForEach(EmailAuthMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Button(emailMode.submitTitle) {
                    emailLinkError = nil
                    authError = nil
                    activeAuthProvider = .email
                    Task {
                        do {
                            switch emailMode {
                            case .signIn:
                                try await onEmailSignIn(emailLinkEmail, emailLinkPassword)
                            case .signUp:
                                try await onEmailSignUp(emailLinkEmail, emailLinkPassword)
                            }
                            showEmailLinkSheet = false
                        } catch {
                            emailLinkError = error.localizedDescription
                        }
                        activeAuthProvider = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
                .disabled(emailLinkEmail.isEmpty || emailLinkPassword.isEmpty)
            }
            .padding()
            .navigationTitle(emailMode.navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showEmailLinkSheet = false }
                }
            }
        }
        .frame(width: 320)
    }
}

// MARK: - iCloud Session Setup View

/// View for setting up iCloud session sync
struct ICloudSessionSetupView: View {
    let onSetupComplete: (Bool) -> Void
    let onSkip: () -> Void

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedBackupOption: ICloudBackupOption = .merge

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.blaze.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "icloud.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(DesignSystem.Colors.blaze)
            }

            // Title and description
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Set Up iCloud Sync")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Sync your session data across all your devices using iCloud.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .multilineTextAlignment(.center)
            }

            // Backup options
            VStack(spacing: DesignSystem.Spacing.sm) {
                backupOptionRow(
                    option: .merge,
                    title: "Merge",
                    description: "Keep existing local data and add iCloud data",
                    icon: "arrow.triangle.merge"
                )

                backupOptionRow(
                    option: .replace,
                    title: "Replace",
                    description: "Use iCloud data and remove local data",
                    icon: "arrow.triangle.swap"
                )

                backupOptionRow(
                    option: .localOnly,
                    title: "Local Only",
                    description: "Don't sync, keep all data on this device",
                    icon: "iphone"
                )
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
                    .padding(.horizontal)
            }

            // Buttons
            VStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    isLoading = true
                    errorMessage = nil
                    // Simulate setup
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isLoading = false
                        onSetupComplete(selectedBackupOption != .localOnly)
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Text(selectedBackupOption == .localOnly ? "Continue" : "Set Up iCloud")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
                .disabled(isLoading)
                .frame(maxWidth: .infinity)

                Button("Skip for Now") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.lg)

            Spacer()
        }
        .frame(width: 400)
    }

    @ViewBuilder
    private func backupOptionRow(option: ICloudBackupOption, title: String, description: String, icon: String) -> some View {
        Button {
            selectedBackupOption = option
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(selectedBackupOption == option ? DesignSystem.Colors.blaze : DesignSystem.Colors.textMuted)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(description)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer()

                if selectedBackupOption == option {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.blaze)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(selectedBackupOption == option ? DesignSystem.Colors.blaze.opacity(0.1) : DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(selectedBackupOption == option ? DesignSystem.Colors.blaze : DesignSystem.Colors.border, lineWidth: selectedBackupOption == option ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Supporting Types

enum ICloudBackupOption {
    case merge
    case replace
    case localOnly
}

private enum AuthProviderAction {
    case apple
    case google
    case email
}

// MARK: - Auth Provider Logo

private enum AuthProviderLogo {
    case apple
    case google
    case email
}

/// Renders real brand logos for auth providers (Apple, Google) with an
/// SF Symbol fallback for email. Sized to fit a square frame of `size` pts.
private struct AuthProviderLogoView: View {
    let logo: AuthProviderLogo
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch logo {
            case .apple:
                appleLogoView
            case .google:
                googleLogoView
            case .email:
                Image(systemName: "envelope.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(DesignSystem.Colors.blaze)
                    .frame(width: size, height: size)
            }
        }
    }

    @ViewBuilder
    private var appleLogoView: some View {
        if NSImage(named: "AppleLogo") != nil {
            Image("AppleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "apple.logo")
                .font(.system(size: size * 0.7))
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private var googleLogoView: some View {
        if NSImage(named: "GoogleLogo") != nil {
            Image("GoogleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "g.circle.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(Color(hex: "4285F4"))
                .frame(width: size, height: size)
        }
    }
}

private enum EmailAuthMode: CaseIterable {
    case signIn
    case signUp

    var title: String {
        switch self {
        case .signIn: return "Sign In"
        case .signUp: return "Create Account"
        }
    }

    var submitTitle: String {
        switch self {
        case .signIn: return "Sign In"
        case .signUp: return "Create Account"
        }
    }

    var navigationTitle: String {
        switch self {
        case .signIn: return "Email Sign In"
        case .signUp: return "Create Account"
        }
    }
}
