import SwiftUI
import OpenBurnBarInsights

// Insight mission launch domain types + mission-launchpad UI.
// Extracted from IntelligenceBriefView.swift (god-file decomposition) — same module, verbatim.

public enum InsightMissionRuntimeTarget: String, CaseIterable, Identifiable, Sendable {
    case auto
    case codex
    case claude
    case hermes
    case openclaw
    case piAgent
    case opencode
    case ollama

    public var id: String { rawValue }
    public var firestoreValue: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        case .piAgent: return "Pi"
        case .opencode: return "OpenCode"
        case .ollama: return "Ollama"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .auto: return "best available local agent"
        default: return label
        }
    }
}

enum InsightMissionDepth: String, CaseIterable, Identifiable, Sendable {
    case light
    case standard
    case deep
    case max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .standard: return "Standard"
        case .deep: return "Deep"
        case .max: return "Max"
        }
    }
}

enum InsightMissionApprovalMode: String, CaseIterable, Identifiable, Sendable {
    case existingPolicy = "existing_policy"
    case manualAll = "manual_all"
    case riskyOnly = "risky_only"
    case readOnly = "read_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .existingPolicy: return "Existing"
        case .manualAll: return "Manual"
        case .riskyOnly: return "Risky"
        case .readOnly: return "Read only"
        }
    }
}

public struct InsightMissionLaunchOptions: Equatable, Sendable {
    public let requestedRuntime: String
    public let targetProject: String?
    public let depth: String
    public let approvalMode: String
    public let commandsAllowed: Bool
    public let fileEditsAllowed: Bool

    public init(
        requestedRuntime: String,
        targetProject: String?,
        depth: String,
        approvalMode: String,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool
    ) {
        self.requestedRuntime = requestedRuntime
        self.targetProject = targetProject
        self.depth = depth
        self.approvalMode = approvalMode
        self.commandsAllowed = commandsAllowed
        self.fileEditsAllowed = fileEditsAllowed
    }
}

public struct InsightMissionLaunchAction: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case creative
        case diligence
        case debt
        case accretive
        case security
        case uiImprovement
        case modernization
        case providerRouting
        case costEfficiency
        case projectFocus
        case custom

        public var firestoreValue: String {
            switch self {
            case .uiImprovement: return "ui_improvement"
            case .providerRouting: return "provider_routing"
            case .costEfficiency: return "cost_efficiency"
            case .projectFocus: return "project_focus"
            default: return rawValue
            }
        }
    }

    public let kind: Kind
    public let title: String
    public let subtitle: String
    let symbolName: String

    public var id: String { title }

    public var followUpQuestion: InsightFollowUpQuestion {
        InsightFollowUpQuestion(
            question: prompt,
            rationale: "Turns the current brief into a local-agent mission."
        )
    }

    private var prompt: String {
        switch kind {
        case .creative:
            return """
            Create a creative/accretive mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, target project, user value, implementation surface, \
            acceptance criteria, evidence to inspect, likely risks, and how mobile should show the result. Also recommend adjacent missions for UI improvements, modernizations, and small features that compound product value.
            """
        case .diligence:
            return """
            Create a diligence mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, target project, launch-readiness/security/reliability questions, \
            exact evidence to collect, severity model, acceptance criteria, and the mobile result summary I should expect. Also recommend adjacent security, QA, and production-readiness missions when the data supports them.
            """
        case .debt:
            return """
            Create a technical debt mission from this Insights brief for my local agent fleet: Hermes, Pi, OpenClaw/OpenClaude, Claude, and Codex. Recommend the best agent, project/module focus, debt hypothesis, delivery drag, \
            validation commands, acceptance criteria, remediation sequence, and how mobile should summarize progress. Also recommend adjacent modernization, dependency, architecture, and UI cleanup missions when the evidence supports them.
            """
        case .accretive:
            return """
            Create an accretive product mission from this Insights brief. Identify the smallest compounding feature or workflow improvement, the target project, the best local agent/runtime, acceptance criteria, evidence to inspect, and how mobile should stream progress and final artifacts.
            """
        case .security:
            return """
            Create a security mission from this Insights brief. Identify trust boundaries, risky data paths, likely abuse cases, validation commands, approval requirements, and the exact evidence the local Mac agent should collect before proposing changes.
            """
        case .uiImprovement:
            return """
            Create a UI improvement mission from this Insights brief. Identify the most operator-visible screen or flow, the UX defect to fix, target files, visual acceptance criteria, accessibility checks, and the mobile timeline events I should expect while the Mac agent works.
            """
        case .modernization:
            return """
            Create a modernization mission from this Insights brief. Identify outdated architecture, dependencies, APIs, or code organization, the safest migration path, compatibility constraints, tests to run, and rollback risks.
            """
        case .providerRouting:
            return """
            Create a provider-routing mission from this Insights brief. Inspect routing policy, fallback behavior, quota state, model selection, and account-level failover, then recommend the highest-leverage routing fix with validation steps.
            """
        case .costEfficiency:
            return """
            Create a cost-efficiency mission from this Insights brief. Find the highest-confidence spend reduction, target providers or models, expected savings, quality risks, validation queries, and implementation steps.
            """
        case .projectFocus:
            return """
            Create a project-focus mission from this Insights brief. Identify the repo or surface consuming the most attention, the most valuable next outcome, distractions to avoid, evidence to collect, and a focused execution plan.
            """
        case .custom:
            return """
            Create a custom local-agent mission from this Insights brief. Preserve the brief context, choose the best runtime, name the target project, list acceptance criteria, and stream all reasoning, tool calls, tool results, changed files, and final answer back to mobile.
            """
        }
    }

    public static let defaultActions: [InsightMissionLaunchAction] = [
        .init(
            kind: .creative,
            title: "Creative Mission",
            subtitle: "Accretive features, UI improvements, modernizations.",
            symbolName: "sparkles"
        ),
        .init(
            kind: .diligence,
            title: "Diligence Mission",
            subtitle: "Security, reliability, launch-readiness evidence.",
            symbolName: "checkmark.seal"
        ),
        .init(
            kind: .debt,
            title: "Debt Mission",
            subtitle: "Compounding drag, rewrite risk, focused remediation.",
            symbolName: "wrench.and.screwdriver"
        ),
        .init(
            kind: .accretive,
            title: "Accretive Mission",
            subtitle: "Small compounding product or workflow wins.",
            symbolName: "plus.forwardslash.minus"
        ),
        .init(
            kind: .security,
            title: "Security Mission",
            subtitle: "Trust boundaries, abuse paths, hardening work.",
            symbolName: "lock.shield"
        ),
        .init(
            kind: .uiImprovement,
            title: "UI Mission",
            subtitle: "Operator surfaces, visual polish, accessibility.",
            symbolName: "rectangle.and.pencil.and.ellipsis"
        ),
        .init(
            kind: .modernization,
            title: "Modernization Mission",
            subtitle: "Migrations, stale APIs, compatibility cleanup.",
            symbolName: "arrow.triangle.2.circlepath"
        ),
        .init(
            kind: .providerRouting,
            title: "Routing Mission",
            subtitle: "Model selection, fallback, quota-aware routing.",
            symbolName: "point.3.connected.trianglepath.dotted"
        ),
        .init(
            kind: .costEfficiency,
            title: "Cost Mission",
            subtitle: "Spend reduction without quality loss.",
            symbolName: "dollarsign.arrow.circlepath"
        ),
        .init(
            kind: .projectFocus,
            title: "Focus Mission",
            subtitle: "Repo focus, priority, next best outcome.",
            symbolName: "scope"
        ),
        .init(
            kind: .custom,
            title: "Custom Mission",
            subtitle: "Dispatch the current brief as a flexible prompt.",
            symbolName: "text.bubble"
        )
    ]
}

struct MissionLaunchpad: View {
    let onSelect: (InsightMissionLaunchAction, InsightMissionLaunchOptions) -> Void

    private let actions = InsightMissionLaunchAction.defaultActions
    @State private var selectedRuntime: InsightMissionRuntimeTarget = .auto
    @State private var targetProject: String = ""
    @State private var selectedDepth: InsightMissionDepth = .standard
    @State private var selectedApprovalMode: InsightMissionApprovalMode = .existingPolicy
    @State private var commandsAllowed = false
    @State private var fileEditsAllowed = false

    private var options: InsightMissionLaunchOptions {
        let trimmedTargetProject = targetProject.trimmingCharacters(in: .whitespacesAndNewlines)
        return InsightMissionLaunchOptions(
            requestedRuntime: selectedRuntime.firestoreValue,
            targetProject: trimmedTargetProject.isEmpty ? nil : trimmedTargetProject,
            depth: selectedDepth.rawValue,
            approvalMode: selectedApprovalMode.rawValue,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            Text("MISSION CONTROL")
                .font(UnifiedDesignSystem.Typography.caption)
                .tracking(2.0)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Text("Create a dispatch-ready mission for your local Hermes, Pi, OpenClaw, Claude, and Codex agents.")
                .font(UnifiedDesignSystem.Typography.body)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            RuntimeTargetPicker(selection: $selectedRuntime)
            MissionOptionPanel(
                targetProject: $targetProject,
                selectedDepth: $selectedDepth,
                selectedApprovalMode: $selectedApprovalMode,
                commandsAllowed: $commandsAllowed,
                fileEditsAllowed: $fileEditsAllowed
            )
            AdaptiveMissionActionGrid(actions: actions, options: options, onSelect: onSelect)
        }
    }
}

struct AdaptiveMissionActionGrid: View {
    let actions: [InsightMissionLaunchAction]
    let options: InsightMissionLaunchOptions
    let onSelect: (InsightMissionLaunchAction, InsightMissionLaunchOptions) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.md) {
                ForEach(actions) { action in
                    MissionLaunchButton(action: action, options: options, onSelect: onSelect)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                ForEach(actions) { action in
                    MissionLaunchButton(action: action, options: options, onSelect: onSelect)
                }
            }
        }
    }
}

struct MissionLaunchButton: View {
    let action: InsightMissionLaunchAction
    let options: InsightMissionLaunchOptions
    let onSelect: (InsightMissionLaunchAction, InsightMissionLaunchOptions) -> Void

    private var runtimeLabel: String {
        InsightMissionRuntimeTarget(rawValue: options.requestedRuntime)?.label ?? options.requestedRuntime
    }

    var body: some View {
        Button {
            onSelect(action, options)
        } label: {
            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: action.symbolName)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(action.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                        .font(UnifiedDesignSystem.Typography.body.weight(.semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    Text("\(action.subtitle) Run on \(runtimeLabel).")
                        .font(UnifiedDesignSystem.Typography.caption)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.circle")
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
            .padding(UnifiedDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(action.color.opacity(0.32), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityHint("Create a dispatch-ready Insights mission prompt")
        .accessibilityIdentifier("insights.mission.\(action.kind.firestoreValue)")
    }
}

struct MissionOptionPanel: View {
    @Binding var targetProject: String
    @Binding var selectedDepth: InsightMissionDepth
    @Binding var selectedApprovalMode: InsightMissionApprovalMode
    @Binding var commandsAllowed: Bool
    @Binding var fileEditsAllowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            TextField("Target project path on Mac", text: $targetProject)
                .font(UnifiedDesignSystem.Typography.caption)
                .padding(Edge.Set.horizontal, UnifiedDesignSystem.Spacing.sm)
                .padding(Edge.Set.vertical, 9)
                .background(UnifiedDesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("insights.mission.targetProject")

            MissionSegmentedPicker(
                title: "Depth",
                selection: $selectedDepth,
                values: InsightMissionDepth.allCases,
                label: \.label
            )
            MissionSegmentedPicker(
                title: "Approval",
                selection: $selectedApprovalMode,
                values: InsightMissionApprovalMode.allCases,
                label: \.label
            )

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Toggle("Commands", isOn: $commandsAllowed)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("insights.mission.commandsAllowed")
                Toggle("File edits", isOn: $fileEditsAllowed)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("insights.mission.fileEditsAllowed")
            }
            .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
        }
        .padding(UnifiedDesignSystem.Spacing.sm)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(UnifiedDesignSystem.Colors.borderSubtle, lineWidth: 0.75)
        )
    }
}

struct MissionSegmentedPicker<Value: Identifiable & Equatable>: View {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let label: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    ForEach(values) { value in
                        Button {
                            selection = value
                        } label: {
                            Text(label(value))
                                .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                                .foregroundStyle(selection == value ? UnifiedDesignSystem.Colors.background : UnifiedDesignSystem.Colors.textSecondary)
                                .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(selection == value ? UnifiedDesignSystem.Colors.textPrimary : UnifiedDesignSystem.Colors.surface)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct RuntimeTargetPicker: View {
    @Binding var selection: InsightMissionRuntimeTarget

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(InsightMissionRuntimeTarget.allCases) { runtime in
                    Button {
                        selection = runtime
                    } label: {
                        Text(runtime.label)
                            .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(selection == runtime ? UnifiedDesignSystem.Colors.background : UnifiedDesignSystem.Colors.textSecondary)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(selection == runtime ? UnifiedDesignSystem.Colors.textPrimary : UnifiedDesignSystem.Colors.surfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Run mission on \(runtime.accessibilityLabel)")
                    .accessibilityIdentifier("insights.mission.runtime.\(runtime.firestoreValue)")
                }
            }
            .padding(.vertical, 1)
        }
    }
}

extension InsightMissionLaunchAction {
    var color: Color {
        switch kind {
        case .creative: return UnifiedDesignSystem.Colors.whimsy
        case .diligence: return UnifiedDesignSystem.Colors.warning
        case .debt: return UnifiedDesignSystem.Colors.ember
        case .accretive: return UnifiedDesignSystem.Colors.success
        case .security: return UnifiedDesignSystem.Colors.error
        case .uiImprovement: return UnifiedDesignSystem.Colors.hermesMercury
        case .modernization: return UnifiedDesignSystem.Colors.textSecondary
        case .providerRouting: return UnifiedDesignSystem.Colors.hermesAureate
        case .costEfficiency: return UnifiedDesignSystem.Colors.warning
        case .projectFocus: return UnifiedDesignSystem.Colors.textMuted
        case .custom: return UnifiedDesignSystem.Colors.textPrimary
        }
    }
}

struct MissionCandidateRow: View {
    let mission: InsightMissionCandidate
    let isExpanded: Bool
    let onToggle: () -> Void
    let onLaunch: () -> Void
    let onCitationTap: (InsightCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: UnifiedDesignSystem.Spacing.sm) {
                    Text(lensLabel.uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(lensColor)
                    Text(priorityLabel.uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .tracking(1.4)
                        .foregroundStyle(priorityColor)
                    Spacer(minLength: 0)
                    Text(mission.effort.rawValue.uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }

                Text(mission.title)
                    .font(UnifiedDesignSystem.Typography.headline)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(mission.summary)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if isExpanded {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                        ActionStripe(text: mission.expectedImpact)
                        ForEach(Array(mission.acceptanceCriteria.prefix(5).enumerated()), id: \.offset) { index, criterion in
                            HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
                                Text("\(index + 1).")
                                    .font(UnifiedDesignSystem.Typography.monoTiny)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                Text(criterion)
                                    .font(UnifiedDesignSystem.Typography.body)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !mission.evidence.isEmpty {
                            FootnoteChipFlow(citations: mission.evidence, onTap: onCitationTap)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mission. \(lensLabel). \(priorityLabel) priority. \(mission.title). \(mission.summary)")
            .accessibilityHint(isExpanded ? "Collapse mission details" : "Open mission details")

            Button(action: onLaunch) {
                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    Image(systemName: "play.circle.fill")
                    Text("Launch \(lensLabel) Mission")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                }
                .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(lensColor)
                .padding(.top, UnifiedDesignSystem.Spacing.xs)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insights.mission.candidate.\(mission.launchMissionKind)")
        }
        .padding(UnifiedDesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(lensColor.opacity(isExpanded ? 0.55 : 0.28), lineWidth: isExpanded ? 1 : 0.5)
        )
    }

    private var lensLabel: String {
        switch mission.lens {
        case .accretion: return "Accretion"
        case .diligence: return "Diligence"
        case .techDebt: return "Debt"
        case .routing: return "Routing"
        case .quota: return "Quota"
        case .focus: return "Focus"
        }
    }

    private var priorityLabel: String {
        switch mission.priority {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    private var lensColor: Color {
        switch mission.lens {
        case .accretion: return UnifiedDesignSystem.Colors.whimsy
        case .diligence: return UnifiedDesignSystem.Colors.hermesAureate
        case .techDebt: return UnifiedDesignSystem.Colors.ember
        case .routing: return UnifiedDesignSystem.Colors.hermesMercury
        case .quota: return UnifiedDesignSystem.Colors.warning
        case .focus: return UnifiedDesignSystem.Colors.textSecondary
        }
    }

    private var priorityColor: Color {
        switch mission.priority {
        case .low: return UnifiedDesignSystem.Colors.textMuted
        case .medium: return UnifiedDesignSystem.Colors.warning
        case .high: return UnifiedDesignSystem.Colors.ember
        case .critical: return UnifiedDesignSystem.Colors.error
        }
    }
}
