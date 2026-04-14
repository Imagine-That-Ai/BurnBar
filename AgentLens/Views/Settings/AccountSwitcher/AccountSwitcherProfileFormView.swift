import SwiftUI
import OpenBurnBarCore

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

