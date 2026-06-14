import OpenBurnBarCore
import SwiftUI

// remediation(ProjectsView-decomposition): Relocated the self-contained "Wiki
// Primitives" cluster out of the 4,388-line ProjectsView.swift to shrink that
// file. Behavior-preserving move only — no logic changes. These types were
// already module-visible (internal). They depend on HFlowLayout (relocated to
// ProjectMemoryEditorialPrimitives.swift) and DesignSystem, both in the same
// module.

// MARK: - Wiki Primitives
// Editorial-Observatory + Wikipedia hybrid: breadcrumbs, anchor TOCs, pivot
// pills with curated Hermes queries, see-also rails. Used by every Project
// Memory detail sheet so the sheets form a clickable, navigable spiderweb
// instead of dead-end cards.

struct WikiQuery: Identifiable, Equatable {
    let id: UUID
    let label: String
    let prompt: String

    init(label: String, prompt: String) {
        self.id = UUID()
        self.label = label
        self.prompt = prompt
    }

    static func == (lhs: WikiQuery, rhs: WikiQuery) -> Bool { lhs.id == rhs.id }
}

extension WikiQuery {
    static func curated(forSectionTitle title: String, projectName: String) -> [WikiQuery] {
        let lower = title.lowercased()
        if lower.contains("executive") {
            return [
                .init(label: "Why now?", prompt: "Why does this executive brief describe \(projectName) the way it does — what changed this week vs last?"),
                .init(label: "What's at stake?", prompt: "What is the single highest-leverage decision facing \(projectName) right now? Be specific and name files or sessions."),
                .init(label: "Show evidence", prompt: "Surface the three strongest pieces of evidence behind this executive brief for \(projectName) with verbatim quotes.")
            ]
        }
        if lower.contains("recent") && lower.contains("agent") {
            return [
                .init(label: "Open latest session", prompt: "Open the most recent agent session in \(projectName) and summarize what the agent did, what it spent, and what's still open."),
                .init(label: "Who spent the most?", prompt: "Which model or provider drove the highest spend in \(projectName) over the last week, and what was it doing?"),
                .init(label: "What blocked?", prompt: "What errors, retries, or blocked tool calls hit recent agent runs in \(projectName)?")
            ]
        }
        if lower.contains("decision") {
            return [
                .init(label: "Show the receipt", prompt: "For every decision listed for \(projectName) here, cite the verbatim conversation excerpt that locked it in."),
                .init(label: "What dissented?", prompt: "Were there rejected alternatives behind these \(projectName) decisions? Surface them with quotes."),
                .init(label: "What's next?", prompt: "Given these decisions in \(projectName), what is the natural next call the operator should make?")
            ]
        }
        if lower.contains("architecture") || lower.contains("map") {
            return [
                .init(label: "Where are the seams?", prompt: "Where are the architecture seams and coupling points in \(projectName)? Name files."),
                .init(label: "Recent changes", prompt: "What architectural changes have happened recently in \(projectName) based on the indexed sessions?"),
                .init(label: "What's at risk?", prompt: "Which parts of the \(projectName) architecture look risky right now and why?")
            ]
        }
        if lower.contains("command") || lower.contains("runbook") {
            return [
                .init(label: "Walk me through", prompt: "Walk me through running the most important command in \(projectName) end-to-end, with the prerequisites."),
                .init(label: "What can break?", prompt: "What are the failure modes for the listed commands in \(projectName)?"),
                .init(label: "Add to runbook", prompt: "Suggest one command we should add to the \(projectName) runbook based on recent agent work.")
            ]
        }
        if lower.contains("risk") || lower.contains("question") || lower.contains("open") {
            return [
                .init(label: "Triage all", prompt: "Triage the open risks and questions for \(projectName) by severity and what they block."),
                .init(label: "Who can answer?", prompt: "For each open question in \(projectName), name the file, session, or person likely to have the answer."),
                .init(label: "What blocks progress?", prompt: "Of the open items in \(projectName), which one is currently blocking the next forward move?")
            ]
        }
        return [
            .init(label: "Why?", prompt: "Explain why this section matters for \(projectName) right now and what it implies."),
            .init(label: "Show evidence", prompt: "Surface the strongest evidence behind the claims in this section for \(projectName) with verbatim quotes."),
            .init(label: "What's next?", prompt: "Given this section about \(projectName), what concrete next move makes sense in the next 30 minutes?")
        ]
    }

    static func curatedForVisual(_ visual: ProjectMemoryVisual, projectName: String) -> [WikiQuery] {
        [
            .init(label: "Why this shape?", prompt: "Why does the \(visual.title.lowercased()) for \(projectName) look the way it does? Name 2–3 drivers."),
            .init(label: "What's the outlier?", prompt: "Which point on the \(visual.title) for \(projectName) is the outlier, and what made it happen?"),
            .init(label: "What changed?", prompt: "What changed in \(projectName) recently that would shift this \(visual.title.lowercased()) next week?")
        ]
    }

    static func curatedForCitations(_ citations: [ProjectMemoryCitation]) -> [WikiQuery] {
        let firstTitle = citations.first?.title.prefix(80) ?? "this evidence"
        return [
            .init(label: "Connect the dots", prompt: "Across these \(citations.count) citation\(citations.count == 1 ? "" : "s"), connect them and tell me the single story they tell. Start with: \(firstTitle)"),
            .init(label: "What did I miss?", prompt: "Read these citations more aggressively than Hermes already did and surface a non-obvious risk, contradiction, or opportunity."),
            .init(label: "Open in chat", prompt: "Let's keep pulling on this thread. Citations: \(citations.prefix(3).map(\.title).joined(separator: ", ")). Ask me the right next question.")
        ]
    }
}

struct WikiBreadcrumbItem: Identifiable {
    let id = UUID()
    let label: String
    let action: (() -> Void)?
}

struct WikiBreadcrumb: View {
    let crumbs: [WikiBreadcrumbItem]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { idx, crumb in
                if idx > 0 {
                    Text("›")
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                if let action = crumb.action, idx < crumbs.count - 1 {
                    Button(action: action) {
                        Text(crumb.label)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .underline()
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(crumb.label)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(idx == crumbs.count - 1
                                         ? DesignSystem.Colors.textPrimary
                                         : DesignSystem.Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(crumbs.map(\.label).joined(separator: ", "))
    }
}

struct WikiPivotPillRow: View {
    let queries: [WikiQuery]
    let onTap: (WikiQuery) -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text("PIVOT")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            ForEach(queries) { q in
                Button {
                    onTap(q)
                } label: {
                    Text(q.label)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DesignSystem.Colors.hermesAureate.opacity(0.08))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(DesignSystem.Colors.hermesAureate.opacity(0.45), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pivot: \(q.label)")
            }
            Spacer(minLength: 0)
        }
    }
}

struct WikiTOCItem: Identifiable {
    let id: String
    let ordinal: Int
    let title: String
    let citationCount: Int
    let body: String
}

struct WikiTableOfContents: View {
    let items: [WikiTOCItem]
    let onJump: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "list.number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text("CONTENTS")
                    .font(DesignSystem.Typography.caption)
                    .tracking(2.0)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text("\(items.count) section\(items.count == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        onJump(item.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
                            Text(String(format: "%02d", item.ordinal))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    .lineLimit(1)
                                if !item.body.isEmpty {
                                    Text(item.body)
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if item.citationCount > 0 {
                                Text("\(item.citationCount) cite\(item.citationCount == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.monoTiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            Image(systemName: "arrow.down.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate.opacity(0.7))
                        }
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to section \(item.ordinal), \(item.title)")
                    if item.id != items.last?.id {
                        Rectangle()
                            .fill(DesignSystem.Colors.borderSubtle)
                            .frame(height: 0.5)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
        }
    }
}

struct WikiSeeAlsoItem: Identifiable {
    let id = UUID()
    let label: String
    let detail: String?
    let symbol: String
    let action: () -> Void
}

struct WikiSeeAlsoRail: View {
    let title: String
    let items: [WikiSeeAlsoItem]
    var symbol: String = "link"

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text(title.uppercased())
                    .font(DesignSystem.Typography.caption)
                    .tracking(2.0)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            HFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(items) { item in
                    Button(action: item.action) {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.label)
                                    .font(DesignSystem.Typography.monoSmall)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    .lineLimit(1)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(DesignSystem.Typography.monoTiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.hermesAureate.opacity(0.7))
                        }
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DesignSystem.Colors.surface.opacity(0.45))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(DesignSystem.Colors.hermesAureate.opacity(0.35), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title), \(item.label)")
                }
            }
        }
    }
}
