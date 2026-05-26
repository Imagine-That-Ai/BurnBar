#if canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

struct AgentPermissionGrantSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runtimeID: AssistantRuntimeID
    let threadID: String
    var controller: MobileAgentPermissionGrantController = .shared

    @State private var selectedPreset: AgentPermissionPreset = .desktop
    @State private var isSubmitting = false
    @State private var receipt: AgentCapabilityGrantReceipt?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    presetGrid
                    capabilitySummary
                    statusView
                }
                .padding(20)
            }
            .navigationTitle("Agent Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: loadActiveReceipt)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(runtimeID.displayName)
                .font(.title2.bold())
            Text("Choose what this one thread can do on your Mac. Grants expire automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 10)], spacing: 10) {
            ForEach(AgentPermissionPreset.allCases) { preset in
                Button {
                    selectedPreset = preset
                    errorMessage = nil
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: preset.symbolName)
                            Spacer()
                            if selectedPreset == preset {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(preset.title)
                            .font(.headline)
                        Text(preset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                    .padding(12)
                    .background(selectedPreset == preset ? Color.accentColor.opacity(0.14) : Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedPreset == preset ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityValue(selectedPreset == preset ? "Selected" : preset.subtitle)
            }
        }
    }

    private var capabilitySummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What changes", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusView: some View {
        if isSubmitting {
            Label("Sending permission request...", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let receipt {
            Label(receipt.message ?? "Permission request sent.", systemImage: "checkmark.shield")
                .font(.footnote)
                .foregroundStyle(.green)
        } else if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var actionTitle: String {
        selectedPreset == .off ? "Turn Off" : "Grant"
    }

    private var summaryText: String {
        switch selectedPreset {
        case .off:
            return "No desktop tools. The agent can still chat normally."
        case .low:
            return "Read-only workspace access. Useful for quick inspection."
        case .workspace:
            return "Workspace file tools and sandboxed shell. It can create files in the OpenBurnBar chat workspace."
        case .desktop:
            return "Workspace tools, managed browser, screenshots, accessibility inspection, and Desktop export into OpenBurnBar Agent Drops."
        case .all:
            return "All bounded tools in Manual mode. Risky actions still ask through OpenBurnBar."
        case .yolo:
            return "Everything in Trusted mode, including unrestricted shell. Use only when you want the agent to move with maximum power."
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            receipt = try await controller.grant(
                runtimeID: runtimeID,
                threadID: threadID,
                preset: selectedPreset
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }

    private func loadActiveReceipt() {
        guard let active = controller.optimisticGrant(runtimeID: runtimeID, threadID: threadID) else { return }
        receipt = active
        if let preset = AgentPermissionPreset.allCases.first(where: {
            $0.matches(capabilities: active.capabilities, trustMode: active.trustMode)
        }) {
            selectedPreset = preset
        }
    }
}
#endif
