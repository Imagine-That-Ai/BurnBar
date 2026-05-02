import SwiftUI

struct ChatInlineContextRibbon: View {
    @Bindable var controller: ChatSessionController
    var brief: InsightBriefSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if let statusLine = brief.rollupStatusLine {
                Text(statusLine)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let w = brief.whereLeftOff {
                Button {
                    controller.inputText = "Tell me more about my work on \(brief.whereLeftOffProject ?? "this project")"
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Where you left off").font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(w).font(DesignSystem.Typography.caption).foregroundStyle(DesignSystem.Colors.textSecondary).multilineTextAlignment(.leading).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }
            if let title = brief.heaviestTaskTitle, let cost = brief.heaviestTaskCost, let proj = brief.heaviestTaskProject {
                Button {
                    controller.inputText = "What did I spend on \(title) this week?"
                } label: {
                    Text("Heaviest this week: \(cost.formatAsCost()) on \(proj) — \(title)")
                        .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted).multilineTextAlignment(.leading).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if let m = brief.modelShiftHeadline {
                Button {
                    controller.inputText = "Tell me more about my new model usage"
                } label: {
                    Text(m).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted).multilineTextAlignment(.leading).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if let inc = brief.incompleteHint {
                Button {
                    controller.inputText = "Help me continue where I left off"
                } label: {
                    Text(inc).font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textMuted).multilineTextAlignment(.leading).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }
}
