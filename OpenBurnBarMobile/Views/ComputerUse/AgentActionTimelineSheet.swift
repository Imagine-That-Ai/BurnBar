#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import OpenBurnBarCore

struct AgentActionTimelineSheet: View {
    let entries: [HermesRealtimeRelayActionLogEntry]

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No actions yet",
                        systemImage: "clock.badge.questionmark",
                        description: Text("Approved and rejected Computer Use actions will appear here.")
                    )
                } else {
                    ForEach(entries.reversed(), id: \.entryIndex) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: glyph(for: entry.status))
                                .foregroundStyle(color(for: entry.status))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.summary)
                                    .font(.headline)
                                    .lineLimit(3)
                                Text("\(entry.actionKind) · \(entry.status.rawValue)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Agent timeline")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func glyph(for status: HermesRealtimeRelayActionLogEntry.Status) -> String {
        switch status {
        case .planned: return "circle"
        case .awaitingApproval: return "questionmark.circle"
        case .executing: return "bolt.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .rejected: return "hand.raised.circle.fill"
        case .panicHalted: return "exclamationmark.octagon.fill"
        }
    }

    private func color(for status: HermesRealtimeRelayActionLogEntry.Status) -> Color {
        switch status {
        case .planned, .awaitingApproval: return .secondary
        case .executing: return .yellow
        case .completed: return .green
        case .failed, .rejected, .panicHalted: return .red
        }
    }
}
#endif
