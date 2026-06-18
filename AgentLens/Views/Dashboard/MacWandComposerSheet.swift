import SwiftUI
import OpenBurnBarCore

struct MacWandComposerSheet: View {
    let accountManager: AccountManager
    var onDispatched: ((MacWandDispatchResult) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @State private var title = ""
    @State private var prompt = ""
    @State private var targetProject = ""
    @State private var workerCount = 1
    @State private var commandsAllowed = false
    @State private var fileEditsAllowed = false
    @State private var requireApproval = true
    @State private var isDispatching = false
    @State private var inlineError: String?
    @State private var unlockFeature: GatedFeature?

    private var tier: CloudTier { entitlement.cloudTier }
    private var cap: Int { WandFanOut.maxParallel(for: tier) }
    private var hardCap: Int { WandFanOut.maxParallel(for: .ultra) }
    private var canDispatch: Bool {
        !isDispatching && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workerCount >= 1 && workerCount <= cap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            fields
            controls
            footer
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            entitlement.start()
            clampWorkerCount()
        }
        .onChange(of: tier) { _, _ in clampWorkerCount() }
        .sheet(item: $unlockFeature) { feature in
            FeatureUnlockSheet(feature: feature)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cast The Wand")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Quota-aware Mac fan-out")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Text("\(workerCount)/\(cap)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.9)))
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Target project", text: $targetProject)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 132)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.76))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(DesignSystem.Colors.borderSubtle.opacity(0.8), lineWidth: 1)
                        )
                )
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Stepper(value: workerBinding, in: 1...hardCap) {
                    Label("\(workerCount) worker\(workerCount == 1 ? "" : "s")", systemImage: "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Picker("Merge", selection: .constant("pick_one")) {
                    Text("Pick One").tag("pick_one")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            HStack(spacing: 16) {
                Toggle(isOn: $commandsAllowed) {
                    Label("Commands", systemImage: "terminal")
                }
                Toggle(isOn: $fileEditsAllowed) {
                    Label("File Edits", systemImage: "doc.badge.gearshape")
                }
                Toggle(isOn: $requireApproval) {
                    Label("Approval", systemImage: "checkmark.shield")
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12, weight: .semibold))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inlineError {
                Text(inlineError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await dispatch() }
                } label: {
                    if isDispatching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Cast", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDispatch)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var workerBinding: Binding<Int> {
        Binding(
            get: { workerCount },
            set: { proposed in
                if proposed <= cap {
                    workerCount = max(1, proposed)
                    return
                }
                workerCount = cap
                unlockFeature = featureForWidth(proposed)
            }
        )
    }

    private func clampWorkerCount() {
        workerCount = max(1, min(workerCount, cap))
    }

    private func featureForWidth(_ width: Int) -> GatedFeature {
        let requiredTier = WandFanOut.minimumTier(forParallel: width)
        let base = GatedFeature.gatedFeature(.theWand)
        return GatedFeature(
            id: base.id,
            publicName: base.publicName,
            requiredTier: requiredTier,
            oneLineBenefit: base.oneLineBenefit,
            benefitBullets: base.benefitBullets,
            iconSystemName: base.iconSystemName,
            crestAssetName: requiredTier.crestAssetName
        )
    }

    private func dispatch() async {
        guard canDispatch else { return }
        inlineError = nil
        isDispatching = true
        defer { isDispatching = false }
        do {
            let result = try await MacWandMissionDispatcher(accountManager: accountManager).dispatch(
                title: title,
                prompt: prompt,
                workerCount: workerCount,
                targetProject: targetProject.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                approvalMode: requireApproval ? "manual_all" : "existing_policy",
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed
            )
            onDispatched?(result)
            dismiss()
        } catch {
            inlineError = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
