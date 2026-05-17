#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarComputerUseCore

struct PhoneControlOptionSheet: View {
    let snapshot: AgentWatchSessionSnapshot
    let onTrustMode: (ComputerUseTrustMode) -> Void
    let onPanic: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
