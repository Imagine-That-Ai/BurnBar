import SwiftUI
import OpenBurnBarCore

// MARK: - Recovery setup
//
// Forced before zero-knowledge mode (Apple ADP pattern): set up a raw recovery
// key OR a split-knowledge recovery contact, then confirm after a delay. Binds
// to setupRecovery / listRecovery / confirmRecovery.

struct DataVaultRecoveryView: View {
    @Bindable var store: DataVaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var generatedKey = ""
    @State private var confirmationKey = ""
    @State private var confirmingRecoveryID: String?
    @State private var contactName = ""
    @State private var contactShare = ""
    @State private var isWorking = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    introCard
                    if !store.recoveryMethods.isEmpty { existingMethodsCard }
                    recoveryKeyCard
                    recoveryContactCard
                    if let error = store.error { DataVaultInlineError(message: error) }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.vertical, MobileTheme.Spacing.md)
            }
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        // T-IOS-03 — recovery keys are among the most sensitive screens; mask
        // them from the app-switcher snapshot and screen recording.
        .sensitiveContentPrivacyGuard()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .task { await store.loadRecovery() }
        .sheet(item: Binding(
            get: { confirmingRecoveryID.map(RecoveryConfirmationID.init) },
            set: { confirmingRecoveryID = $0?.rawValue }
        )) { item in
            NavigationStack {
                Form {
                    SecureField("Recovery key", text: $confirmationKey)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Text("BurnBar derives a verification hash on this device. The key itself is never sent.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .navigationTitle("Confirm recovery")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            confirmationKey = ""
                            confirmingRecoveryID = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm") {
                            Task {
                                await store.confirmRecoveryKey(item.rawValue, recoveryKey: confirmationKey)
                                confirmationKey = ""
                                confirmingRecoveryID = nil
                            }
                        }
                        .disabled(confirmationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var introCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Why this matters", systemImage: "lifepreserver.fill")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Your vault key never leaves your devices, so BurnBar can't reset it for you. A recovery key or a trusted contact is your only way back in if you lose every device.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var existingMethodsCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text("Your recovery methods")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                ForEach(store.recoveryMethods) { method in
                    HStack(spacing: 10) {
                        Image(systemName: method.kind == "recovery_key" ? "key.fill" : "person.2.fill")
                            .foregroundStyle(EncryptionTier.endToEnd.tierColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(method.kind == "recovery_key" ? "Recovery key" : "Recovery contact")
                                .font(MobileTheme.Typography.body)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text(method.confirmed ? "Confirmed" : "Pending confirmation")
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(method.confirmed ? MobileTheme.success : MobileTheme.warning)
                        }
                        Spacer()
                        if !method.confirmed {
                            Button("Confirm") {
                                if method.kind == "recovery_key" {
                                    confirmingRecoveryID = method.recoveryId
                                } else {
                                    Task { await store.confirmRecovery(method.recoveryId) }
                                }
                            }
                            .buttonStyle(.aurora(.secondary))
                        }
                    }
                }
            }
        }
    }

    private var recoveryKeyCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text("Recovery key")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("A high-entropy recovery key only you hold. Write it down and store it somewhere safe.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                if !generatedKey.isEmpty {
                    Text(generatedKey)
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(EncryptionTier.endToEnd.tierColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(MobileTheme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(EncryptionTier.endToEnd.tierColor.opacity(0.10))
                        )
                }

                HStack {
                    Button(generatedKey.isEmpty ? "Generate key" : "Regenerate") {
                        generatedKey = (try? CloudVaultCrypto.generateRecoveryKey()) ?? ""
                    }
                    .buttonStyle(.aurora(.secondary))

                    Spacer()

                    Button {
                        Task {
                            isWorking = true
                            if await store.setupRecoveryKey(generatedKey) { generatedKey = "" }
                            isWorking = false
                        }
                    } label: {
                        Text(isWorking ? "Saving…" : "Save recovery key")
                    }
                    .buttonStyle(.aurora(.primary))
                    .disabled(generatedKey.isEmpty || isWorking)
                }
            }
        }
    }

    private var recoveryContactCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text("Recovery contact")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("Split-knowledge: a trusted person holds one share. Neither of you alone can open your vault.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                TextField("Contact name", text: $contactName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("Their key share", text: $contactShare)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Button {
                    Task {
                        isWorking = true
                        if await store.setupRecoveryContact(name: contactName, share: contactShare) {
                            contactName = ""
                            contactShare = ""
                        }
                        isWorking = false
                    }
                } label: {
                    Text(isWorking ? "Saving…" : "Add recovery contact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.secondary, fullWidth: true))
                .disabled(contactName.isEmpty || contactShare.isEmpty || isWorking)
            }
        }
    }

}

private struct RecoveryConfirmationID: Identifiable {
    let rawValue: String
    var id: String { rawValue }
}
