import SwiftUI
import OpenBurnBarHermes
import OpenBurnBarKernel

// MARK: - AI Inbox presentation vocabulary
//
// The iOS half of `InboxPresentation` (AgentLens/Views/Inbox/InboxView.swift).
// Same switch shape, same labels, MobileTheme tokens instead of DesignSystem —
// so a new detector kind gets a coherent glyph on both platforms by adding one
// case to each, and the two lists never disagree about what "CI waste" is
// called.

enum AIInboxPresentation {
    static func icon(for kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "flame"
        case .promisedNotLanded: return "questionmark.circle"
        case .uncommittedWork: return "tray.and.arrow.down"
        case .costAnomaly: return "chart.line.uptrend.xyaxis"
        case .stuckPR: return "arrow.triangle.pull"
        case .indexHealth: return "waveform.path.ecg"
        case .brief: return "text.alignleft"
        case .budget: return "gauge.with.dots.needle.67percent"
        case .system: return "info.circle"
        }
    }

    static func tint(for kind: BurnBarInboxItemKind) -> Color {
        switch kind {
        case .ciWaste, .costAnomaly, .budget: return MobileTheme.amber
        case .promisedNotLanded, .stuckPR: return MobileTheme.ember
        case .uncommittedWork: return MobileTheme.whimsy
        case .indexHealth, .system: return MobileTheme.Colors.textMuted
        case .brief: return MobileTheme.blaze
        }
    }

    static func kindLabel(_ kind: BurnBarInboxItemKind) -> String {
        switch kind {
        case .ciWaste: return "CI waste"
        case .promisedNotLanded: return "Possibly unfinished"
        case .uncommittedWork: return "Uncommitted work"
        case .costAnomaly: return "Spend anomaly"
        case .stuckPR: return "Stalled PR"
        case .indexHealth: return "Index"
        case .brief: return "Brief"
        case .budget: return "Budget"
        case .system: return "Notice"
        }
    }

    static func priorityLabel(_ priority: BurnBarInboxPriority) -> String {
        switch priority {
        case .p1: return "Urgent"
        case .p2: return "Today"
        case .p3: return "Worth knowing"
        case .p4: return "Background"
        }
    }

    static func priorityColor(_ priority: BurnBarInboxPriority) -> Color {
        switch priority {
        case .p1: return MobileTheme.error
        case .p2: return MobileTheme.amber
        case .p3: return MobileTheme.whimsy
        case .p4: return MobileTheme.Colors.textMuted
        }
    }

    static func evidenceIcon(for kind: BurnBarInboxEvidence.Kind) -> String {
        switch kind {
        case .conversation: return "text.bubble"
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "exclamationmark.circle"
        case .workflowRun: return "gearshape.2"
        case .commit: return "checkmark.seal"
        case .file: return "folder"
        case .usage: return "dollarsign.circle"
        case .metric: return "chart.bar"
        }
    }

    static func actionIcon(for kind: BurnBarInboxAction.Kind) -> String {
        switch kind {
        case .openURL: return "arrow.up.forward.square"
        case .resumeConversation: return "arrow.clockwise"
        case .openSessionLog: return "text.bubble"
        case .openProject: return "folder"
        case .openSettings: return "gearshape"
        case .runCommand: return "terminal"
        }
    }

    /// Strips markdown so a two-line preview never shows raw `**` or backticks.
    /// The Hermes parser already owns this vocabulary, so the preview and the
    /// rendered body agree about what is markup and what is prose.
    static func plainPreview(_ markdown: String) -> String {
        HermesAtomParser.plainText(markdown)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Humanizes a raw metric key/value pair (`waste_rate` → "Waste rate",
    /// `0.95` → "95%"). Detector keys are free-form strings by contract, so the
    /// suffix conventions are the only thing worth special-casing.
    static func metricDisplay(key: String, value: String) -> (label: String, value: String) {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        let label = spaced.prefix(1).uppercased() + spaced.dropFirst()
        var display = value
        if key.hasSuffix("_rate"), let number = Double(value) {
            display = "\(Int((number * 100).rounded()))%"
        } else if key.hasSuffix("_usd"), let number = Double(value) {
            display = String(format: "$%.3f", number)
        } else if key.hasSuffix("_minutes"), let number = Double(value) {
            display = "\(Int(number.rounded()))m"
        }
        return (String(label), display)
    }

    /// `deepseek:deepseek-v4-flash+openai:gpt-5.6-luna` → "deepseek-v4-flash and
    /// gpt-5.6-luna". Provider prefixes are noise in a provenance sentence.
    static func friendlyModelNames(_ provenance: String) -> String {
        provenance
            .split(separator: "+")
            .map { component -> String in
                let parts = component.split(separator: ":", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : String(component)
            }
            .joined(separator: " and ")
    }
}

// MARK: - Row

/// One inbox item in the list.
///
/// Pure presentation: the triage gestures live on the List row in `AIInboxView`
/// rather than here, because `swipeActions` only binds when it is applied to the
/// row itself — inside a `NavigationLink` label it silently does nothing.
///
/// Unread is expressed three ways — an ember dot, a faint ember wash, and a
/// heavier title — because on a phone held at arm's length any one of them alone
/// is missable, and none of them may be the only carrier of the status.
struct AIInboxRow: View {
    let item: AIInboxStore.Item
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            topLine
            titleLine
            if item.record.summaryMarkdown.isEmpty == false {
                Text(AIInboxPresentation.plainPreview(item.record.summaryMarkdown))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            bottomLine
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                        .fill(rowWash)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                        .stroke(strokeColor, lineWidth: isSelected ? 1.5 : 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("inbox.row.\(item.id)")
    }

    private var topLine: some View {
        HStack(spacing: MobileTheme.Spacing.xs) {
            if item.isUnread {
                Circle()
                    .fill(MobileTheme.ember)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }

            Image(systemName: AIInboxPresentation.icon(for: item.record.kind))
                .font(MobileScaledFont.system(size: 11, weight: .medium))
                .foregroundStyle(AIInboxPresentation.tint(for: item.record.kind))

            Text(AIInboxPresentation.kindLabel(item.record.kind))
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Spacer(minLength: 0)

            if item.record.priority <= .p2 {
                AIInboxPriorityBadge(priority: item.record.priority)
            }
        }
    }

    private var titleLine: some View {
        Text(item.record.title)
            .font(MobileTheme.Typography.body)
            .fontWeight(item.isUnread ? .semibold : .regular)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bottomLine: some View {
        HStack(spacing: MobileTheme.Spacing.xs) {
            if let project = item.record.projectName, project.isEmpty == false {
                Text(project)
                    .lineLimit(1)
                Text("·")
            }

            Text(MissionConsoleFormatting.relativeTime(item.record.lastSeenAt))

            if item.record.occurrenceCount > 1 {
                Text("· seen \(item.record.occurrenceCount)×")
            }

            Spacer(minLength: 0)

            if item.record.hasMemoryCandidates {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(MobileTheme.whimsy)
            }

            if item.record.state == .resolved {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(MobileTheme.success)
            }
        }
        .font(MobileTheme.Typography.tiny)
        .foregroundStyle(MobileTheme.Colors.textMuted)
    }

    private var rowWash: Color {
        if isSelected { return MobileTheme.ember.opacity(0.10) }
        if item.isUnread { return MobileTheme.ember.opacity(0.05) }
        return .clear
    }

    private var strokeColor: Color {
        isSelected ? MobileTheme.ember.opacity(0.55) : MobileTheme.Colors.borderSubtle
    }

    private var accessibilityLabel: String {
        MobileAccessibilityLabelPolicy.inboxRow(
            unread: item.isUnread,
            kindLabel: AIInboxPresentation.kindLabel(item.record.kind),
            priorityLabel: item.record.priority <= .p2
                ? AIInboxPresentation.priorityLabel(item.record.priority)
                : nil,
            title: item.record.title
        )
    }
}

// MARK: - Priority badge

struct AIInboxPriorityBadge: View {
    let priority: BurnBarInboxPriority

    var body: some View {
        let color = AIInboxPresentation.priorityColor(priority)
        Text(AIInboxPresentation.priorityLabel(priority).uppercased())
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, MobileTheme.Spacing.sm)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.16))
                    .overlay(Capsule(style: .continuous).stroke(color.opacity(0.40), lineWidth: 0.5))
            )
    }
}
