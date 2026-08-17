import OpenBurnBarKernel
import SwiftUI

/// Slim chat-side mirror of the Fleet queue. Does not persist cards as
/// chat messages.
struct FleetQueueAccessory: View {
    let directives: [BurnBarFleetDirective]
    let onOpenFleet: () -> Void

    var body: some View {
        if !directives.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack {
                    Text("Fleet queue")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                    Button("Open Fleet", action: onOpenFleet)
                        .buttonStyle(.borderless)
                        .font(DesignSystem.Typography.tiny)
                }
                ForEach(directives.prefix(4), id: \.id) { directive in
                    Text(line(for: directive))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fleet queue, \(directives.count) item\(directives.count == 1 ? "" : "s")")
        }
    }

    private func line(for directive: BurnBarFleetDirective) -> String {
        let state: String
        switch directive.state {
        case .proposed: state = "Proposed"
        case .approved: state = "Approved"
        case .submitted: state = "Submitted"
        case .delivered: state = "Delivered"
        case .dismissed: state = "Dismissed"
        case .failed: state = "Failed"
        case .unsupported: state = "Unsupported"
        }
        let agent = directive.targetAgent?.wireValue ?? "fleet"
        let thread = directive.sessionRef ?? "inbox"
        return "\(state) · \(agent) / \(thread)"
    }
}
