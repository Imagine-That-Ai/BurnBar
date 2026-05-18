#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore

struct PhoneControlOptionSheet: View {
    let snapshot: AgentWatchSessionSnapshot
    let onTrustMode: (ComputerUseTrustMode) -> Void
    let onType: (String) -> Void
    let onShortcut: (String, [String]) -> Void
    let onPanic: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var textToType = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Take over") {
                    TextField("Text to type", text: $textToType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let trimmed = textToType.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { return }
                        onType(trimmed)
                        textToType = ""
                        dismiss()
                    } label: {
                        Label("Type text", systemImage: "keyboard")
                    }
                    .disabled(textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        onShortcut("Return", [])
                        dismiss()
                    } label: {
                        Label("Return", systemImage: "return")
                    }

                    Button {
                        onShortcut("Escape", [])
                        dismiss()
                    } label: {
                        Label("Escape", systemImage: "escape")
                    }

                    Button {
                        onShortcut("L", ["command"])
                        dismiss()
                    } label: {
                        Label("Command-L", systemImage: "link")
                    }
                }

                Section("Trust mode") {
                    ForEach(ComputerUseTrustMode.allCases, id: \.self) { mode in
                        Button {
                            onTrustMode(mode)
                            dismiss()
                        } label: {
                            HStack {
                                ComputerUseTrustModeBadge(mode: mode)
                                Spacer()
                                if snapshot.trustMode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                Section("Session") {
                    LabeledContent("Actions", value: "\(snapshot.actionsExecuted)")
                    LabeledContent("Spend", value: String(format: "$%.2f", snapshot.dailySpentUSD))
                    if let startedAt = snapshot.startedAt {
                        LabeledContent("Started", value: startedAt.formatted(date: .omitted, time: .shortened))
                    }
                    if let reason = snapshot.lastDeniedReason {
                        LabeledContent("Last denial", value: reason.rawValue)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onPanic()
                        dismiss()
                    } label: {
                        Label("Panic halt", systemImage: "exclamationmark.octagon.fill")
                    }
                }
            }
            .navigationTitle("Phone control")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
