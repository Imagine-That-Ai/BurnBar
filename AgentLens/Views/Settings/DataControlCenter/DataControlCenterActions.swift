import SwiftUI
import OpenBurnBarCore

// MARK: - Recovery setup sheet (setupRecovery / confirmRecovery / listRecovery)
//
// Forced before zero-knowledge mode. Supports a raw recovery key AND
// split-knowledge recovery contacts (Apple ADP pattern). Confirmation is a
// delayed re-entry step: the user must re-confirm after a method is registered.

struct RecoverySetupSheet: View {
    @Bindable var viewModel: DataControlCenterViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var method: DataControlCenterViewModel.RecoveryKind = .recoveryKey
    @State private var recoveryKey = ""
    @State private var confirmationKey = ""
    @State private var confirmingRecoveryID: String?
    @State private var contactEmail = ""
    @State private var contactLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Picker("Method", selection: $method) {
                Text("Recovery key").tag(DataControlCenterViewModel.RecoveryKind.recoveryKey)
                Text("Recovery contact").tag(DataControlCenterViewModel.RecoveryKind.recoveryContact)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if method == .recoveryKey {
                recoveryKeyForm
            } else {
                recoveryContactForm
            }

            existingMethods

            if let error = viewModel.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 460)
        .background(EmberSurfaceBackground().ignoresSafeArea())
        .task { await viewModel.refreshRecovery() }
        .sheet(item: Binding(
            get: { confirmingRecoveryID.map(RecoveryConfirmationID.init) },
            set: { confirmingRecoveryID = $0?.rawValue }
        )) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("Confirm recovery key")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                SecureField("Recovery key", text: $confirmationKey)
                    .textFieldStyle(.roundedBorder)
                Text("This device derives the verification hash locally. The raw recovery key is never sent.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                HStack {
                    Button("Cancel") {
                        confirmationKey = ""
                        confirmingRecoveryID = nil
                    }
                    Spacer()
                    Button("Confirm") {
                        Task {
                            _ = await viewModel.confirmRecoveryKey(recoveryId: item.rawValue, recoveryKey: confirmationKey)
                            confirmationKey = ""
                            confirmingRecoveryID = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(confirmationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("RECOVERY", systemImage: "key.horizontal.fill")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2.0)
                .foregroundStyle(PensieveTheme.brassCore)
            Text("Set up recovery")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Required before zero-knowledge mode. If you lose every trusted device, this is the only way back to your sealed data — BurnBar cannot recover it for you.")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryKeyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECOVERY KEY")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("recovery key", text: $recoveryKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
            Text("Write this down and store it somewhere only you can reach. We never see it.")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    private var recoveryContactForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECOVERY CONTACT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("Contact label (e.g. \"Mom's iPhone\")", text: $contactLabel)
                .textFieldStyle(.roundedBorder)
            TextField("Contact email", text: $contactEmail)
                .textFieldStyle(.roundedBorder)
            Text("A split-knowledge contact holds one half of your recovery secret. They can help you recover, but cannot read your data alone.")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private var existingMethods: some View {
        if viewModel.recoveryMethods.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR RECOVERY METHODS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                ForEach(viewModel.recoveryMethods) { recoveryMethod in
                    HStack(spacing: 10) {
                        Image(systemName: recoveryMethod.kind == "recovery_contact" ? "person.crop.circle" : "key.fill")
                            .foregroundStyle(PensieveTheme.brassCore)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(recoveryMethod.kind == "recovery_contact" ? "Recovery contact" : "Recovery key")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            if let createdAt = recoveryMethod.createdAt {
                                Text(createdAt.relativeLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                        Spacer()
                        if recoveryMethod.confirmed {
                            Label("Confirmed", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.success)
                        } else {
                            Button("Confirm") {
                                if recoveryMethod.kind == "recovery_key" {
                                    confirmingRecoveryID = recoveryMethod.recoveryId
                                } else {
                                    Task { await viewModel.confirmRecovery(recoveryId: recoveryMethod.recoveryId) }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(viewModel.isMutating)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                Task {
                    let payload: [String: Any]
                    if method == .recoveryKey {
                        if await viewModel.setupRecoveryKey(recoveryKey) != nil {
                            recoveryKey = ""
                        }
                        return
                    } else {
                        payload = ["contactEmail": contactEmail, "contactLabel": contactLabel]
                    }
                    if await viewModel.setupRecovery(method: method, payload: payload) != nil {
                        recoveryKey = ""
                        contactEmail = ""
                        contactLabel = ""
                    }
                }
            } label: {
                if viewModel.isMutating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Register method", systemImage: "plus.shield.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(PensieveTheme.brassCore)
            .disabled(viewModel.isMutating || isFormIncomplete)
        }
    }

    private var isFormIncomplete: Bool {
        method == .recoveryKey
            ? recoveryKey.trimmingCharacters(in: .whitespaces).isEmpty
            : contactEmail.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Panic sheet (revokeAllAccess)
//
// The PANIC control. Aggregates every revoke callable behind one action. Wax-
// crimson, double-confirm (the user must type the scope word) so it can never
// fire by accident.

struct PanicRevokeSheet: View {
    @Bindable var viewModel: DataControlCenterViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var scope: DataControlCenterViewModel.RevokeScope = .sync
    @State private var confirmText = ""
    @State private var outcome: DataControlCenterViewModel.RevokeResult?

    private var confirmWord: String { scope == .all ? "REVOKE ALL" : "REVOKE SYNC" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Picker("Scope", selection: $scope) {
                Text("Sync only").tag(DataControlCenterViewModel.RevokeScope.sync)
                Text("Everything").tag(DataControlCenterViewModel.RevokeScope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: scope) { _, _ in confirmText = "" }

            scopeExplanation

            if let outcome {
                resultSummary(outcome)
            } else {
                confirmField
            }

            if let error = viewModel.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(PensieveTheme.waxCrimson)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 460)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("PANIC", systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2.0)
                .foregroundStyle(PensieveTheme.waxCrimson)
            Text("Revoke all access")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }

    private var scopeExplanation: some View {
        Text(scope == .all
             ? "Immediately revokes every MCP client, paired device, escrow device, and provider connection. Your sealed data stays sealed, but nothing can reach it until you re-pair."
             : "Immediately stops cloud sync and revokes paired devices and MCP clients. Provider credentials and escrow stay intact.")
            .font(.system(size: 12))
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type \(confirmWord) to confirm")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField(confirmWord, text: $confirmText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }

    private func resultSummary(_ result: DataControlCenterViewModel.RevokeResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Access revoked", systemImage: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.success)
            Text("\(result.mcpClients) MCP clients · \(result.devices) devices · \(result.escrowDevices) escrow devices · \(result.providers) providers")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(outcome == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if outcome == nil {
                Button(role: .destructive) {
                    Task { outcome = await viewModel.revokeAllAccess(scope: scope) }
                } label: {
                    if viewModel.isMutating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Revoke now", systemImage: "bolt.shield.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(PensieveTheme.waxCrimson)
                .disabled(viewModel.isMutating || confirmText != confirmWord)
            }
        }
    }
}

// MARK: - Delete domain confirmation (deleteDomainData)

struct DeleteDomainSheet: View {
    @Bindable var viewModel: DataControlCenterViewModel
    let domain: DataDomain
    @Environment(\.dismiss) private var dismiss

    @State private var confirmText = ""
    @State private var outcome: DataControlCenterViewModel.DeleteResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("DELETE", systemImage: "trash.fill")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2.0)
                    .foregroundStyle(PensieveTheme.waxCrimson)
                Text("Delete \(domain.title)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Text(domain.encryptionTier == .endToEnd
                 ? "This permanently deletes the ciphertext for \(domain.title). Because it's sealed end-to-end, this is genuine, irreversible deletion."
                 : "This permanently deletes everything in \(domain.title). This cannot be undone.")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            FlowChips(items: domain.firestorePaths.prefix(8).map { $0 }, icon: "doc.fill", tint: PensieveTheme.waxCrimson)

            if let outcome {
                Label("Deleted \(outcome.firestoreDocs) records and \(outcome.storageObjects) files.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type DELETE to confirm")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    TextField("DELETE", text: $confirmText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
            }

            if let error = viewModel.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(PensieveTheme.waxCrimson)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Button(outcome == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if outcome == nil {
                    Button(role: .destructive) {
                        Task { outcome = await viewModel.deleteDomain(domain.id) }
                    } label: {
                        if viewModel.isMutating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Delete permanently", systemImage: "trash.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PensieveTheme.waxCrimson)
                    .disabled(viewModel.isMutating || confirmText != "DELETE")
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(EmberSurfaceBackground().ignoresSafeArea())
    }
}

private struct RecoveryConfirmationID: Identifiable {
    let rawValue: String
    var id: String { rawValue }
}
