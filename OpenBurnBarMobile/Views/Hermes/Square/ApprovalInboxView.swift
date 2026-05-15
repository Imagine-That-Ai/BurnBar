import SwiftUI
import OpenBurnBarCore

// MARK: - Approval Inbox (Hermes Square §6.9)
//
// Sticky strip at the top of the Living Inbox when N approvals are
// pending, with a "yes always for this class" affordance.

struct ApprovalInboxStrip: View {
    let asks: [MissionConsoleApprovalAsk]
    let onApprove: (MissionConsoleApprovalAsk) -> Void
    let onDeny: (MissionConsoleApprovalAsk) -> Void
    let onApproveAlways: (MissionConsoleApprovalAsk) -> Void
    let onDenyAlways: (MissionConsoleApprovalAsk) -> Void

    var body: some View {
        if asks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(DesignSystemColors.warning)
                    Text("Approvals waiting")
                        .font(.caption.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    Spacer()
                    Text("\(asks.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                ForEach(asks) { ask in
                    row(for: ask)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignSystemColors.warning.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(DesignSystemColors.warning.opacity(0.45), lineWidth: 0.5)
                    )
            )
        }
    }

    private func row(for ask: MissionConsoleApprovalAsk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ask.title)
                    .font(.callout.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                Spacer()
                Text(ask.runtimeDisplayLabel)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(DesignSystemColors.surface))
                    .foregroundStyle(DesignSystemColors.textSecondary)
            }
            Text(ask.message)
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textSecondary)
                .lineLimit(3)
            HStack(spacing: 6) {
                Button { onApprove(ask) } label: {
                    Text("Approve")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(DesignSystemColors.success))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
                Button { onDeny(ask) } label: {
                    Text("Deny")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(DesignSystemColors.error.opacity(0.18)))
                        .foregroundStyle(DesignSystemColors.error)
                }.buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Always approve this class") { onApproveAlways(ask) }
                    Button("Always deny this class", role: .destructive) { onDenyAlways(ask) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "ellipsis.circle")
                        Text("Always…")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(DesignSystemColors.surface))
                    .foregroundStyle(DesignSystemColors.textPrimary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesignSystemColors.surface.opacity(0.6))
        )
    }
}
