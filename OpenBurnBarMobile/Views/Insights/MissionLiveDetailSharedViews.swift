import SwiftUI
import OpenBurnBarCore

struct MissionLiveDetailView: View {
    let mission: CLIAgentMissionSnapshot
    let onApprovalResponse: (Bool) -> Void
    @State private var activeFilters: Set<MissionEventFilter> = Set(MissionEventFilter.allCases)

    private var visibleEvents: [CLIAgentMissionEvent] {
        mission.events.filter { event in
            activeFilters.contains(MissionEventFilter(event: event))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text(mission.title)
                            .font(UnifiedDesignSystem.Typography.title)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text(mission.displayLiveSummary?.nilIfEmpty ?? mission.displayStatus.capitalized)
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                            MissionDetailChip(label: mission.displayStatus.uppercased(), systemImage: mission.isTerminal ? "checkmark.circle" : "dot.radiowaves.left.and.right")
                            MissionDetailChip(label: mission.runtimeLabel, systemImage: "desktopcomputer")
                            MissionDetailChip(label: mission.currentStepLabel, systemImage: "arrow.triangle.2.circlepath")
                            if let tool = mission.activeToolName {
                                MissionDetailChip(label: tool, systemImage: "hammer")
                            }
                            if let artifact = mission.latestArtifactLabel {
                                MissionDetailChip(label: artifact, systemImage: "doc.text")
                            }
                        }
                    }

                    if mission.isWaitingForApproval {
                        MissionDetailSection(title: mission.approvalTitle?.nilIfEmpty ?? "Approval Required") {
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                Text(mission.approvalMessage?.nilIfEmpty ?? "The Mac is waiting for approval before continuing this mission.")
                                    .font(UnifiedDesignSystem.Typography.caption)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Button {
                                        onApprovalResponse(true)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(UnifiedDesignSystem.Colors.success)

                                    Button(role: .destructive) {
                                        onApprovalResponse(false)
                                    } label: {
                                        Label("Reject", systemImage: "xmark.octagon")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    if let sessionID = mission.sessionID?.nilIfEmpty {
                        MissionDetailSection(title: "Session") {
                            Text(sessionID)
                                .font(UnifiedDesignSystem.Typography.monoTiny)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                .textSelection(.enabled)
                        }
                    }

                    MissionDetailSection(title: "Live Timeline") {
                        if mission.events.isEmpty {
                            Text("Waiting for the Mac agent to report progress.")
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        } else {
                            MissionEventFilterBar(activeFilters: $activeFilters)
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                ForEach(visibleEvents) { event in
                                    MissionTimelineRow(event: event)
                                }
                            }
                        }
                    }

                    if let result = mission.resultPreview?.nilIfEmpty {
                        MissionDetailSection(title: "Result") {
                            Text(result)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                .textSelection(.enabled)
                        }
                    }

                    if let error = mission.errorMessage?.nilIfEmpty {
                        MissionDetailSection(title: "Failure") {
                            Text(error)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.lg)
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle("Mission Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum MissionEventFilter: String, CaseIterable, Identifiable {
    case llm
    case tools
    case errors
    case approvals
    case artifacts
    case status

    var id: String { rawValue }

    init(event: CLIAgentMissionEvent) {
        if event.isError || event.kind == "error" || event.phase == "failed" {
            self = .errors
        } else if event.kind == "tool_call" || event.kind == "tool_result" || event.phase == "tool_use" {
            self = .tools
        } else if event.kind == "approval_request" || event.phase.contains("approval") {
            self = .approvals
        } else if event.kind == "artifact" || event.kind == "changed_file" || event.artifactPath != nil || event.changedFilePath != nil {
            self = .artifacts
        } else if event.kind == "llm_response" || event.kind == "assistant_message" || event.kind == "final_answer" || event.phase == "assistant_response" {
            self = .llm
        } else {
            self = .status
        }
    }

    var label: String {
        switch self {
        case .llm: return "LLM"
        case .tools: return "Tools"
        case .errors: return "Errors"
        case .approvals: return "Approvals"
        case .artifacts: return "Artifacts"
        case .status: return "Status"
        }
    }
}

struct MissionEventFilterBar: View {
    @Binding var activeFilters: Set<MissionEventFilter>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(MissionEventFilter.allCases) { filter in
                    Button {
                        if activeFilters.contains(filter), activeFilters.count > 1 {
                            activeFilters.remove(filter)
                        } else {
                            activeFilters.insert(filter)
                        }
                    } label: {
                        Text(filter.label)
                            .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                            .foregroundStyle(activeFilters.contains(filter) ? Color.white : UnifiedDesignSystem.Colors.textSecondary)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                            .padding(.vertical, 6)
                            .background(activeFilters.contains(filter) ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct MissionQueuedDetailView: View {
    let title: String
    let runtime: String
    let detail: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                Text(title)
                    .font(UnifiedDesignSystem.Typography.title)
                MissionDetailChip(label: runtime, systemImage: "desktopcomputer")
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer()
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle("Mission Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct MissionDetailChip: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(UnifiedDesignSystem.Typography.tiny.weight(.semibold))
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(UnifiedDesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm))
    }
}

struct MissionDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text(title)
                .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            content
        }
    }
}

struct MissionTimelineRow: View {
    let event: CLIAgentMissionEvent

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    Text((event.title?.nilIfEmpty ?? event.phase.replacingOccurrences(of: "_", with: " ")).uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    if let runtime = event.runtime?.nilIfEmpty {
                        Text(runtime)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                }
                Text(event.displayMessage)
                    .font(event.prefersMonospace ? UnifiedDesignSystem.Typography.monoTiny : UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(event.prefersMonospace ? 10 : 0)
                    .background {
                        if event.prefersMonospace {
                            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm)
                                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.72))
                        }
                    }
                if event.messageTruncated {
                    Text("Showing redacted mobile payload capped at \(event.messageLength ?? event.displayMessage.count) chars.")
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                }
                if event.toolName?.nilIfEmpty != nil || event.artifactPath?.nilIfEmpty != nil || event.changedFilePath?.nilIfEmpty != nil {
                    HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                        if let toolName = event.toolName?.nilIfEmpty {
                            MissionDetailChip(label: toolName, systemImage: "hammer")
                        }
                        if let artifactPath = event.artifactPath?.nilIfEmpty {
                            MissionDetailChip(label: artifactPath, systemImage: "doc.text")
                        }
                        if let changedFilePath = event.changedFilePath?.nilIfEmpty {
                            MissionDetailChip(label: changedFilePath, systemImage: "pencil.and.list.clipboard")
                        }
                    }
                }
                Text(event.timestamp)
                    .font(UnifiedDesignSystem.Typography.monoTiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }

    private var iconName: String {
        switch event.phase {
        case "agent_launch_failed": return "xmark.octagon.fill"
        case "tool_use", "tool_result": return "hammer"
        case "assistant_response": return "text.bubble"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "circle.dotted"
        }
    }

    private var iconColor: Color {
        if event.isError { return UnifiedDesignSystem.Colors.warning }
        switch event.phase {
        case "completed": return UnifiedDesignSystem.Colors.success
        case "failed": return UnifiedDesignSystem.Colors.warning
        case "tool_use", "tool_result": return UnifiedDesignSystem.Colors.ember
        default: return UnifiedDesignSystem.Colors.whimsy
        }
    }
}

extension CLIAgentMissionEvent {
    var displayMessage: String {
        fullMessage?.nilIfEmpty ?? message
    }

    var prefersMonospace: Bool {
        kind == "tool_call"
            || kind == "tool_result"
            || kind == "llm_response"
            || kind == "assistant_message"
            || kind == "final_answer"
            || displayMessage.contains("\n")
    }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
