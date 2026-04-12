import SwiftUI
import OpenBurnBarCore

// MARK: - Account Switcher Settings View

/// Settings view for managing account switcher profiles.
/// Supports browser profiles (Chrome, Safari) and CLI profiles (Codex, Claude, OpenCode).
///
/// Security properties (VAL-SETTINGS-008):
/// - No cookie/session import or raw credential persistence
/// - Only non-sensitive launch metadata is stored
/// - OAuth boundary messaging is explicit
struct AccountSwitcherSettingsView: View {
    let dataStore: DataStore

    @State private var profiles: [SwitcherProfileRecord] = []
    @State private var activeProfileID: String?
    @State private var activeProfileState: SwitcherActiveProfileState = .init(activeProfileID: nil)
    @State private var isLoading = true
    @State private var error: String?

    // Sheet states
    @State private var showingCreateSheet = false
    @State private var showingEditSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var profileToEdit: SwitcherProfileRecord?
    @State private var profileToDelete: SwitcherProfileRecord?

    // Edit form state
    @State private var editFormName = ""
    @State private var editFormTargetKind: SwitcherProfileTargetKind = .browser
    @State private var editFormBrowserType: SwitcherBrowserProfileType = .chrome
    @State private var editFormCLIType: SwitcherCLIProfileType = .claude
    @State private var editFormProfileIdentifier = ""
    @State private var editFormWorkingDirectory = ""
    @State private var editFormAdditionalArgs = ""
    @State private var editFormEnvKeys = ""
    @State private var editFormValidationError: String?
    @State private var editFormDuplicateError: String?
    @State private var isSaving = false

    private let supportedTargets = ["Google Chrome", "Safari", "Codex", "Claude Code", "OpenCode"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                // OAuth boundary messaging (VAL-SETTINGS-007, VAL-SETTINGS-016)
                boundaryMessagingCard

                if isLoading {
                    loadingView
                } else if profiles.isEmpty {
                    emptyStateView
                } else {
                    profileListView
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(settingsBackground)
        .scrollContentBackground(.hidden)
        .onAppear(perform: loadProfiles)
        .sheet(isPresented: $showingCreateSheet) {
            createProfileSheet
        }
        .sheet(isPresented: $showingEditSheet) {
            if let profile = profileToEdit {
                editProfileSheet(profile: profile)
            }
        }
        .alert("Delete Profile?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    deleteProfile(profile)
                }
            }
        } message: {
            Text("This will permanently delete the profile '\(profileToDelete?.displayName ?? "")'. This action cannot be undone.")
        }
    }

    // MARK: - Background

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var settingsBackground: some View {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F3E8E6"),
                    Color(hex: "F5E4DE"),
                    Color(hex: "F0DDD4"),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            DesignSystem.Colors.background
        }
    }

    // MARK: - OAuth Boundary Messaging

    /// Explicit OAuth/session boundary copy (VAL-SETTINGS-007, VAL-SETTINGS-016)
    private var boundaryMessagingCard: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignSystem.Colors.amber)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Session Boundaries")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("Google, Apple, and ChatGPT login sessions are managed in your browser or at their websites. BurnBar only stores profile references for launching with the correct identity — no credentials are imported or stored.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session boundary information: Google, Apple, and ChatGPT login sessions are managed externally. BurnBar only stores profile launch references.")
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading profiles...")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.xxl)
    }

    // MARK: - Empty State

    /// Empty state with supported targets (VAL-SETTINGS-002)
    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            GlassCard {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    Text("No Profiles Yet")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("Create your first profile to start switching between accounts.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(DesignSystem.Spacing.xl)
                .frame(maxWidth: .infinity)
            }

            // Setup wizard button
            Button {
                WindowManager.shared.openSwitcherOnboardingWizard(
                    dataStore: dataStore,
                    settingsManager: SettingsManager.shared,
                    onOpenSettings: {}
                )
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Setup Wizard")
                }
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.amber)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.amber, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile setup wizard")

            // Supported targets section (VAL-SETTINGS-002)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Supported Targets")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        supportedTargetRow(icon: "globe", title: "Google Chrome", subtitle: "Browser profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(icon: "safari", title: "Safari", subtitle: "Browser profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(icon: "terminal.fill", title: "Codex", subtitle: "CLI profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(icon: "terminal.fill", title: "Claude Code", subtitle: "CLI profile")
                        Divider().background(DesignSystem.Colors.borderSubtle)
                        supportedTargetRow(icon: "terminal.fill", title: "OpenCode", subtitle: "CLI profile")
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }

            // Add profile button
            Button {
                showingCreateSheet = true
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Profile")
                }
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.amber)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add first profile")
        }
    }

    private func supportedTargetRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()
        }
    }

    // MARK: - Profile List

    /// Profile list with active state indicators (VAL-SETTINGS-014)
    private var profileListView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Header with count and add button
            HStack {
                Text("\(profiles.count) Profile\(profiles.count == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                Button {
                    showingCreateSheet = true
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "plus.circle")
                        Text("Add Profile")
                    }
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add new profile")
                .keyboardShortcut("n", modifiers: .command)
            }

            // Profile rows (VAL-SETTINGS-014: deterministic ordering)
            ForEach(profiles) { profile in
                ProfileRowView(
                    profile: profile,
                    isActive: profile.id == activeProfileID,
                    onSetActive: { setActiveProfile(profile) },
                    onEdit: { editProfile(profile) },
                    onDelete: { confirmDeleteProfile(profile) }
                )
            }
        }
    }

    // MARK: - Create Profile Sheet

    private var createProfileSheet: some View {
        NavigationView {
            ProfileFormView(
                title: "Create Profile",
                name: $editFormName,
                targetKind: $editFormTargetKind,
                browserType: $editFormBrowserType,
                cliType: $editFormCLIType,
                profileIdentifier: $editFormProfileIdentifier,
                workingDirectory: $editFormWorkingDirectory,
                additionalArgs: $editFormAdditionalArgs,
                envKeys: $editFormEnvKeys,
                validationError: $editFormValidationError,
                duplicateError: $editFormDuplicateError,
                isSaving: isSaving,
                boundaryCopyVisible: true,
                onSave: createProfile,
                onCancel: { showingCreateSheet = false }
            )
            .navigationTitle("Create Profile")
        }
        .frame(width: 480, height: 520)
        .onAppear { resetForm() }
    }

    // MARK: - Edit Profile Sheet

    private func editProfileSheet(profile: SwitcherProfileRecord) -> some View {
        NavigationView {
            ProfileFormView(
                title: "Edit Profile",
                name: $editFormName,
                targetKind: $editFormTargetKind,
                browserType: $editFormBrowserType,
                cliType: $editFormCLIType,
                profileIdentifier: $editFormProfileIdentifier,
                workingDirectory: $editFormWorkingDirectory,
                additionalArgs: $editFormAdditionalArgs,
                envKeys: $editFormEnvKeys,
                validationError: $editFormValidationError,
                duplicateError: $editFormDuplicateError,
                isSaving: isSaving,
                boundaryCopyVisible: true,
                onSave: { saveProfile(profile) },
                onCancel: {
                    showingEditSheet = false
                    profileToEdit = nil
                }
            )
            .navigationTitle("Edit Profile")
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Data Operations

    private func loadProfiles() {
        isLoading = true
        do {
            profiles = try dataStore.switcherStore.fetchAllProfiles()
            let state = try dataStore.switcherStore.validateAndRecoverActiveProfile()
            activeProfileID = state.activeProfileID
            activeProfileState = state
        } catch {
            self.error = "Failed to load profiles: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func setActiveProfile(_ profile: SwitcherProfileRecord) {
        do {
            try dataStore.switcherStore.setActiveProfile(profile.id)
            activeProfileID = profile.id
            activeProfileState = try dataStore.switcherStore.fetchActiveProfileState()
        } catch {
            self.error = "Failed to set active profile: \(error.localizedDescription)"
        }
    }

    private func resetForm() {
        editFormName = ""
        editFormTargetKind = .browser
        editFormBrowserType = .chrome
        editFormCLIType = .claude
        editFormProfileIdentifier = ""
        editFormWorkingDirectory = ""
        editFormAdditionalArgs = ""
        editFormEnvKeys = ""
        editFormValidationError = nil
        editFormDuplicateError = nil
        isSaving = false
    }

    private func createProfile() {
        guard validateForm(excludingID: nil) else { return }
        isSaving = true

        do {
            let record = buildProfileRecord(id: UUID().uuidString)
            _ = try dataStore.switcherStore.create(record)

            // VAL-SETTINGS-009: First profile create establishes deterministic active state
            if profiles.isEmpty {
                try dataStore.switcherStore.setActiveProfile(record.id)
                activeProfileID = record.id
            }

            showingCreateSheet = false
            loadProfiles()
        } catch {
            editFormValidationError = "Failed to create profile: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func saveProfile(_ original: SwitcherProfileRecord) {
        guard validateForm(excludingID: original.id) else { return }
        isSaving = true

        do {
            let updated = SwitcherProfileRecord(
                id: original.id,
                targetKind: editFormTargetKind,
                browserType: editFormTargetKind == .browser ? editFormBrowserType : nil,
                browserMetadata: editFormTargetKind == .browser ? SwitcherBrowserProfileMetadata(
                    profileIdentifier: editFormProfileIdentifier,
                    displayLabel: editFormName.isEmpty ? nil : editFormName
                ) : nil,
                cliType: editFormTargetKind == .cli ? editFormCLIType : nil,
                cliMetadata: editFormTargetKind == .cli ? SwitcherCLIProfileMetadata(
                    workingDirectory: editFormWorkingDirectory.isEmpty ? nil : editFormWorkingDirectory,
                    additionalArgs: editFormAdditionalArgs.isEmpty ? [] : editFormAdditionalArgs.split(separator: " ").map(String.init),
                    envKeysToPass: editFormEnvKeys.isEmpty ? [] : editFormEnvKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    displayLabel: editFormName.isEmpty ? nil : editFormName
                ) : nil,
                sortKey: original.sortKey,
                createdAt: original.createdAt
            )

            _ = try dataStore.switcherStore.update(updated)
            showingEditSheet = false
            profileToEdit = nil
            loadProfiles()
        } catch {
            editFormValidationError = "Failed to update profile: \(error.localizedDescription)"
        }

        isSaving = false
    }

    private func editProfile(_ profile: SwitcherProfileRecord) {
        // Initialize form state from the profile being edited so bindings
        // read from/write to mutable @State vars instead of immutable snapshots
        editFormName = profile.displayName
        editFormTargetKind = profile.targetKind
        editFormBrowserType = profile.browserType ?? .chrome
        editFormCLIType = profile.cliType ?? .claude
        editFormProfileIdentifier = profile.browserMetadata?.profileIdentifier ?? ""
        editFormWorkingDirectory = profile.cliMetadata?.workingDirectory ?? ""
        editFormAdditionalArgs = profile.cliMetadata?.additionalArgs.joined(separator: " ") ?? ""
        editFormEnvKeys = profile.cliMetadata?.envKeysToPass.joined(separator: ", ") ?? ""
        editFormValidationError = nil
        editFormDuplicateError = nil
        profileToEdit = profile
        showingEditSheet = true
    }

    private func confirmDeleteProfile(_ profile: SwitcherProfileRecord) {
        profileToDelete = profile
        showingDeleteConfirmation = true
    }

    private func deleteProfile(_ profile: SwitcherProfileRecord) {
        do {
            try dataStore.switcherStore.deleteProfile(id: profile.id)
            profileToDelete = nil

            // VAL-SETTINGS-010: Deleting active profile chooses safe fallback
            let state = try dataStore.switcherStore.fetchActiveProfileState()
            activeProfileID = state.activeProfileID

            loadProfiles()
        } catch {
            self.error = "Failed to delete profile: \(error.localizedDescription)"
        }
    }

    // MARK: - Form Validation

    /// Validates the form and sets validation/duplicate errors.
    /// Returns true if valid, false otherwise.
    private func validateForm(excludingID: String?) -> Bool {
        editFormValidationError = nil
        editFormDuplicateError = nil

        // Name validation (optional, but if provided must not be duplicate)
        if !editFormName.isEmpty {
            let checkName = editFormTargetKind == .browser
                ? (editFormBrowserType.displayName + " - " + editFormName)
                : (editFormCLIType.displayName + " - " + editFormName)

            if let excludingID = excludingID {
                // For edit, check excluding self
            } else {
                // For create, check any duplicates
            }

            do {
                // More lenient duplicate check - only check display names
                if try dataStore.switcherStore.existsProfileWithNormalizedName(editFormName, excludingID: excludingID) {
                    editFormDuplicateError = "A profile with this name already exists"
                    return false
                }
            } catch {
                // Ignore duplicate check errors
            }
        }

        // Target-specific validation (VAL-SETTINGS-011)
        switch editFormTargetKind {
        case .browser:
            if editFormProfileIdentifier.isEmpty {
                editFormValidationError = "Profile identifier is required"
                return false
            }
        case .cli:
            // CLI profiles don't require profile identifier
            break
        }

        return true
    }

    private func buildProfileRecord(id: String) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: editFormTargetKind,
            browserType: editFormTargetKind == .browser ? editFormBrowserType : nil,
            browserMetadata: editFormTargetKind == .browser ? SwitcherBrowserProfileMetadata(
                profileIdentifier: editFormProfileIdentifier,
                displayLabel: editFormName.isEmpty ? nil : editFormName
            ) : nil,
            cliType: editFormTargetKind == .cli ? editFormCLIType : nil,
            cliMetadata: editFormTargetKind == .cli ? SwitcherCLIProfileMetadata(
                workingDirectory: editFormWorkingDirectory.isEmpty ? nil : editFormWorkingDirectory,
                additionalArgs: editFormAdditionalArgs.isEmpty ? [] : editFormAdditionalArgs.split(separator: " ").map(String.init),
                envKeysToPass: editFormEnvKeys.isEmpty ? [] : editFormEnvKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                displayLabel: editFormName.isEmpty ? nil : editFormName
            ) : nil,
            sortKey: 0
        )
    }
}

// MARK: - Profile Row View

/// Individual profile row with active indicator and actions.
struct ProfileRowView: View {
    let profile: SwitcherProfileRecord
    let isActive: Bool
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                // Active indicator
                Circle()
                    .fill(isActive ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted.opacity(0.3))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(isActive ? DesignSystem.Colors.success : Color.clear, lineWidth: 2)
                    )

                // Profile info
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(profile.displayName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        if isActive {
                            Text("Active")
                                .font(DesignSystem.Typography.tiny)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, DesignSystem.Spacing.xs)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.success)
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm))
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        targetIcon
                        Text(profile.targetKind == .browser
                            ? profile.browserType?.displayName ?? "Browser"
                            : profile.cliType?.displayName ?? "CLI")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if !isActive {
                        Button("Set Active") {
                            onSetActive()
                        }
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.amber)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Set \(profile.displayName) as active profile")
                    }

                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(profile.displayName)")
                    .keyboardShortcut(.return, modifiers: .command)

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(profile.displayName)")
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.snappy) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.displayName), \(profile.targetKind == .browser ? profile.browserType?.displayName ?? "Browser" : profile.cliType?.displayName ?? "CLI"), \(isActive ? "active" : "inactive")")
        .accessibilityHint(isActive ? "" : "Double tap to set as active")
    }

    private var targetIcon: some View {
        Group {
            switch profile.targetKind {
            case .browser:
                Image(systemName: profile.browserType == .safari ? "safari" : "globe")
                    .font(.system(size: 10))
            case .cli:
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10))
            }
        }
        .foregroundStyle(DesignSystem.Colors.textMuted)
    }
}

// MARK: - Profile Form View

/// Reusable form for creating and editing profiles.
/// Includes target-specific validation and OAuth boundary copy.
struct ProfileFormView: View {
    let title: String
    @Binding var name: String
    @Binding var targetKind: SwitcherProfileTargetKind
    @Binding var browserType: SwitcherBrowserProfileType
    @Binding var cliType: SwitcherCLIProfileType
    @Binding var profileIdentifier: String
    @Binding var workingDirectory: String
    @Binding var additionalArgs: String
    @Binding var envKeys: String
    @Binding var validationError: String?
    @Binding var duplicateError: String?
    let isSaving: Bool
    let boundaryCopyVisible: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            // OAuth boundary messaging (VAL-SETTINGS-016)
            if boundaryCopyVisible {
                Section {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(DesignSystem.Colors.amber)
                        Text("BurnBar stores only profile references for launching — no credentials or session data is imported.")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
                }
            }

            // Target kind selection
            Section {
                Picker("Target Kind", selection: $targetKind) {
                    Text("Browser").tag(SwitcherProfileTargetKind.browser)
                    Text("CLI").tag(SwitcherProfileTargetKind.cli)
                }
                .pickerStyle(.segmented)
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }

            // Name field
            Section {
                TextField("Display Name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)

                if let dupError = duplicateError {
                    Text(dupError)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            } header: {
                Text("Profile Name")
            }

            // Target-specific fields
            if targetKind == .browser {
                browserFields
            } else {
                cliFields
            }

            // Validation error
            if let error = validationError {
                Section {
                    Text(error)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
            }

            // Action buttons
            Section {
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        onSave()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Text("Save")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }
        }
        .formStyle(.grouped)
    }

    private var browserFields: some View {
        Group {
            Section {
                Picker("Browser", selection: $browserType) {
                    ForEach(SwitcherBrowserProfileType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }

            Section {
                TextField("Profile Identifier", text: $profileIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Profile Identifier")
            } footer: {
                Text("For Chrome: the profile folder name (e.g., 'Profile 1', 'Default'). For Safari: the WebKit profile container name.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

    private var cliFields: some View {
        Group {
            Section {
                Picker("CLI", selection: $cliType) {
                    ForEach(SwitcherCLIProfileType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .listRowBackground(DesignSystem.Colors.surfaceElevated)
            }

            Section {
                TextField("Working Directory (optional)", text: $workingDirectory)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Working Directory")
            }

            Section {
                TextField("Additional Args (optional)", text: $additionalArgs)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Additional Arguments")
            } footer: {
                Text("Space-separated list of arguments (e.g., '--verbose --no-color')")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Section {
                TextField("Environment Keys (optional)", text: $envKeys)
                    .textFieldStyle(.roundedBorder)
                    .listRowBackground(DesignSystem.Colors.surfaceElevated)
            } header: {
                Text("Environment Variables to Pass")
            } footer: {
                Text("Comma-separated list of environment variable names (e.g., 'HOME, PATH'). Values are NOT stored.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}
