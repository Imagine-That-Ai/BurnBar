import SwiftUI
import OpenBurnBarCore

struct AddProviderConnectionView: View {
    let provider: AgentProvider

    @State private var accountLabel = ""
    @State private var credential = ""
    @State private var selectedKind: CredentialKind = .token
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var labelFocused: Bool
    @FocusState private var credentialFocused: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var connectionStore = ProviderConnectionStore()

    private var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLabel: String {
        accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationState: ValidationState {
        if trimmedCredential.isEmpty { return .empty }
        if trimmedCredential.count < 8 { return .tooShort }
        return .valid
    }

    private var canConnect: Bool {
        validationState == .valid && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                providerHeaderSection
                accountLabelSection
                credentialSection
                expirationWarningSection
                errorSection
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isConnecting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await connect() }
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canConnect)
                    .accessibilityLabel(isConnecting ? "Connecting" : "Connect account")
                }
            }
            .onAppear {
                // Focus the label field first so multi-account naming feels
                // intentional. Users who already have a default account
                // typically want to differentiate the new one.
                if accountLabel.isEmpty { labelFocused = true }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var providerHeaderSection: some View {
        Section {
            HStack(spacing: MobileTheme.Spacing.md) {
                ProviderBadge(provider: provider, size: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Add an account to refresh quota and attribute usage.")
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var accountLabelSection: some View {
        Section {
            TextField("Label", text: $accountLabel, prompt: Text("e.g. Work, Personal, Client"))
                .textContentType(.nickname)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .focused($labelFocused)
                .submitLabel(.next)
                .onSubmit { credentialFocused = true }
        } header: {
            Text("Account label")
        } footer: {
            Text("Helps you tell multiple \(provider.displayName) accounts apart.")
                .font(MobileTheme.Typography.caption)
        }
    }

    @ViewBuilder
    private var credentialSection: some View {
        Section {
            Picker("Credential type", selection: $selectedKind) {
                Text("Token").tag(CredentialKind.token)
                Text("Bearer").tag(CredentialKind.bearer)
                Text("Session").tag(CredentialKind.session)
                Text("Cookie").tag(CredentialKind.cookie)
                Text("Plan").tag(CredentialKind.plan)
            }
            .pickerStyle(.menu)

            SecureField("Paste your credential", text: $credential)
                .font(MobileTheme.Typography.body)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($credentialFocused)
                .submitLabel(.go)
                .onSubmit {
                    if canConnect {
                        Task { await connect() }
                    }
                }

            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first {
                    credential = first
                }
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel("Paste credential")
        } header: {
            Text("Credential")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if validationState == .tooShort {
                    Text("That looks too short. Make sure you copied the full credential.")
                        .foregroundStyle(MobileTheme.Colors.warning)
                } else {
                    Text("OpenBurnBar stores credentials in your iCloud-backed secret store. They're never displayed back to you.")
                }
            }
            .font(MobileTheme.Typography.caption)
        }
    }

    @ViewBuilder
    private var expirationWarningSection: some View {
        if selectedKind == .session || selectedKind == .cookie {
            Section {
                Label {
                    Text("Session and cookie credentials may expire. Reconnect if quota refresh stops working.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.warning)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section {
                Label {
                    Text(errorMessage)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.error)
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(MobileTheme.Colors.error)
                }
            }
        }
    }

    private func connect() async {
        guard canConnect else { return }
        isConnecting = true
        errorMessage = nil
        await connectionStore.connect(
            providerID: provider.providerID,
            credential: trimmedCredential,
            kind: selectedKind,
            label: trimmedLabel.emptyToNil
        )
        isConnecting = false
        if connectionStore.error == nil {
            dismiss()
        } else {
            errorMessage = connectionStore.error
        }
    }
}

// MARK: - Validation State

private enum ValidationState {
    case empty
    case tooShort
    case valid
}

private extension String {
    var emptyToNil: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    AddProviderConnectionView(provider: .minimax)
}
