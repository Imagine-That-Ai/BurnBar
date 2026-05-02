import SwiftUI
import OpenBurnBarCore

struct AddProviderConnectionView: View {
    let provider: AgentProvider

    @State private var credential = ""
    @State private var selectedKind: CredentialKind = .token
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var validationState: ValidationState = .empty
    @Environment(\.dismiss) private var dismiss

    private let connectionStore = ProviderConnectionStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        ProviderBadge(provider: provider, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(MobileTheme.Typography.headline)
                            Text("Connect to enable quota refresh")
                                .font(MobileTheme.Typography.footnote)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                    }
                }

                Section("Credential") {
                    Picker("Kind", selection: $selectedKind) {
                        Text("Token").tag(CredentialKind.token)
                        Text("Bearer").tag(CredentialKind.bearer)
                        Text("Session").tag(CredentialKind.session)
                        Text("Cookie").tag(CredentialKind.cookie)
                        Text("Plan").tag(CredentialKind.plan)
                    }
                    .pickerStyle(.menu)

                    ZStack(alignment: .topLeading) {
                        if credential.isEmpty {
                            Text("Paste your credential here…")
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        SecureField("", text: $credential, prompt: Text(""))
                            .font(MobileTheme.Typography.body)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .frame(minHeight: 44)

                    if #available(iOS 16.0, *) {
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first {
                                credential = first
                                validate()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }

                if selectedKind == .session || selectedKind == .cookie {
                    Section {
                        Label(
                            "Session and cookie credentials may expire. Reconnect if quota refresh stops working.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.warning)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(MobileTheme.Typography.footnote)
                            .foregroundStyle(MobileTheme.Colors.error)
                    }
                }
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") {
                        Task { await connect() }
                    }
                    .disabled(!canConnect)
                }
            }
        }
    }

    private var canConnect: Bool {
        !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isConnecting
    }

    private func validate() {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            validationState = .empty
        } else if trimmed.count < 8 {
            validationState = .tooShort
        } else {
            validationState = .valid
        }
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        await connectionStore.connect(
            provider: provider.persistedToken,
            credential: credential.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: selectedKind
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

#Preview {
    AddProviderConnectionView(provider: .minimax)
}
