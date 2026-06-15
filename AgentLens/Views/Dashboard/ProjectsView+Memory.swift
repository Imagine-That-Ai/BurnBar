import Charts
import OpenBurnBarCore
import SwiftUI

// Project-memory cards, editor, citation wrapper, insight controller.
// Extracted from ProjectsView.swift (god-file decomposition) — same module, verbatim.

extension ProjectMemoryFreshness {
    var color: Color {
        switch self {
        case .fresh:
            return DesignSystem.Colors.success
        case .needsRefresh:
            return DesignSystem.Colors.hermesAureate
        case .evidenceThin:
            return DesignSystem.Colors.amber
        case .stale:
            return DesignSystem.Colors.warning
        }
    }
}

struct ProjectMemoryHeroCard: View {
    let snapshot: ProjectMemorySnapshot
    var onTap: (() -> Void)?
    @State private var isHovered = false

    private var coverVisual: ProjectMemoryVisual? {
        snapshot.visuals.first { $0.kind == .cover }
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.hermesMercury.opacity(0.22),
                                DesignSystem.Colors.hermesAureate.opacity(0.22),
                                DesignSystem.Colors.surfaceElevated.opacity(0.7)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                            .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: 1)
                    )

                Circle()
                    .fill(DesignSystem.Colors.hermesAureate.opacity(0.18))
                    .frame(width: 120, height: 120)
                    .offset(x: 180, y: -30)
                    .blur(radius: 1.2)

                Circle()
                    .fill(DesignSystem.Colors.whimsy.opacity(0.12))
                    .frame(width: 80, height: 80)
                    .offset(x: 235, y: 42)
                    .blur(radius: 1)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text(snapshot.projectDisplayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(snapshot.usageSummary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let coverVisual {
                        HStack(spacing: DesignSystem.Spacing.md) {
                            ForEach(Array(coverVisual.points.prefix(3).enumerated()), id: \.offset) { _, point in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.label.uppercased())
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                    Text(metric(point))
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                                }
                            }
                        }
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.lg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func metric(_ point: ProjectMemoryVisualPoint) -> String {
        if point.label.lowercased().contains("spend") {
            return point.value.formatAsCost()
        }
        if point.label.lowercased().contains("token") {
            return Int(point.value).formatAsTokenVolume()
        }
        return String(Int(point.value))
    }
}

struct ProjectMemoryPageCard: View {
    let page: ProjectMemoryPage
    var onTap: (() -> Void)?
    var onCitationTap: (([ProjectMemoryCitation]) -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(page.title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(page.summary)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(page.sections.prefix(2)) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(section.body)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(3)
                        if section.citations.isEmpty == false {
                            Button {
                                onCitationTap?(section.citations)
                            } label: {
                                Text("\(section.citations.count) citation\(section.citations.count == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.25), lineWidth: 0.75)
                    )
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct ProjectMemoryVisualCard: View {
    let visual: ProjectMemoryVisual
    var onTap: (() -> Void)?
    @State private var isHovered = false

    private var maxValue: Double {
        max(visual.points.map(\.value).max() ?? 1, 1)
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(visual.title)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                if let subtitle = visual.subtitle {
                    Text(subtitle)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                ForEach(Array(visual.points.prefix(5).enumerated()), id: \.offset) { _, point in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(point.label)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            Text(pointValueLabel(point))
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        }
                        Capsule()
                            .fill(DesignSystem.Colors.hermesAureate.opacity(0.8))
                            .frame(width: CGFloat(max(0.12, point.value / maxValue)) * 140, height: 4)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(width: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func pointValueLabel(_ point: ProjectMemoryVisualPoint) -> String {
        if let subtitle = point.subtitle, subtitle.isEmpty == false {
            return subtitle
        }
        if visual.kind == .providerMix {
            return point.value.formatAsCost()
        }
        if visual.kind == .timeline {
            return Int(point.value).formatAsTokenVolume()
        }
        return String(Int(point.value))
    }
}

func statusPill(title: String, color: Color) -> some View {
    Text(title)
        .font(DesignSystem.Typography.tiny)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
}

func sectionHeader(_ title: String) -> some View {
    Text(title)
        .font(DesignSystem.Typography.caption)
        .fontWeight(.semibold)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .textCase(.uppercase)
}

func factRow(icon: String, title: String, value: String, accent: Color? = nil) -> some View {
    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent ?? DesignSystem.Colors.textSecondary)
            .frame(width: 16, alignment: .center)
        Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(width: 80, alignment: .leading)
        Text(value)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(accent ?? DesignSystem.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func metricChip(title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
        Text(value)
            .font(DesignSystem.Typography.monoSmall)
            .foregroundStyle(color)
    }
    .padding(.horizontal, DesignSystem.Spacing.sm)
    .padding(.vertical, 6)
    .background(
        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
    )
    .overlay(
        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
            .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
    )
}

struct ControllerProjectDraft: Identifiable {
    let id: String
    let existingProjectID: String?
    var projectSlug: String
    var displayName: String
    var summary: String
    var aliasesText: String
    var preferredCadence: BurnBarControllerReviewCadence
    var automationMode: BurnBarControllerProjectAutomationMode
    var scheduleHourLocal: Int
    var scheduleWeekdayLocal: Int
    var reviewModelID: String
    var isPaused: Bool
    var existingMetadata: BurnBarMetadata
    var existingLatestDailyReviewAt: Date?
    var existingLatestWeeklyReviewAt: Date?
    var existingNextScheduledReviewAt: Date?
    var existingActiveMissionID: BurnBarMissionID?
    var existingPendingQuestionCount: Int
    var existingOpenFollowupCount: Int
    var existingActiveMissionCount: Int

    init(project: BurnBarReviewProjectSnapshot? = nil) {
        self.id = project?.id ?? UUID().uuidString
        self.existingProjectID = project?.id
        self.projectSlug = project?.projectSlug ?? ""
        self.displayName = project?.displayName ?? ""
        self.summary = project?.summary ?? ""
        self.aliasesText = project?.aliases.joined(separator: ", ") ?? ""
        self.preferredCadence = project?.preferredCadence ?? .weekly
        self.automationMode = project?.automationMode ?? .manual
        self.scheduleHourLocal = project?.scheduleHourLocal ?? 9
        self.scheduleWeekdayLocal = project?.scheduleWeekdayLocal ?? 2
        self.reviewModelID = project?.reviewModelID ?? "glm-5"
        self.isPaused = project?.status == .paused
        self.existingMetadata = project?.metadata ?? [:]
        self.existingLatestDailyReviewAt = project?.latestDailyReviewAt
        self.existingLatestWeeklyReviewAt = project?.latestWeeklyReviewAt
        self.existingNextScheduledReviewAt = project?.nextScheduledReviewAt
        self.existingActiveMissionID = project?.activeMissionID
        self.existingPendingQuestionCount = project?.pendingQuestionCount ?? 0
        self.existingOpenFollowupCount = project?.openFollowupCount ?? 0
        self.existingActiveMissionCount = project?.activeMissionCount ?? 0
    }

    var aliases: [String] {
        aliasesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func snapshot() -> BurnBarReviewProjectSnapshot {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSlug = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? normalizedDisplayName.lowercased().replacingOccurrences(of: " ", with: "-")
            : projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return BurnBarReviewProjectSnapshot(
            id: existingProjectID ?? "project-\(normalizedSlug)",
            projectSlug: normalizedSlug,
            displayName: normalizedDisplayName.isEmpty ? normalizedSlug : normalizedDisplayName,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Native OpenBurnBar controller registry project." : summary.trimmingCharacters(in: .whitespacesAndNewlines),
            status: isPaused ? .paused : .healthy,
            preferredCadence: preferredCadence,
            aliases: aliases,
            automationMode: automationMode,
            reviewModelID: reviewModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reviewModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            scheduleHourLocal: scheduleHourLocal,
            scheduleWeekdayLocal: scheduleWeekdayLocal,
            freshness: .provisional,
            latestDailyReviewAt: existingLatestDailyReviewAt,
            latestWeeklyReviewAt: existingLatestWeeklyReviewAt,
            nextScheduledReviewAt: existingNextScheduledReviewAt,
            pendingQuestionCount: existingPendingQuestionCount,
            openFollowupCount: existingOpenFollowupCount,
            activeMissionCount: existingActiveMissionCount,
            activeMissionID: existingActiveMissionID,
            needsOperatorAttention: existingPendingQuestionCount > 0 || existingOpenFollowupCount > 0 || existingActiveMissionCount > 0,
            ingestionSource: .manual,
            metadata: existingMetadata
        )
    }
}

struct ControllerProjectEditorSheet: View {
    @State var draft: ControllerProjectDraft
    let onCancel: () -> Void
    let onSave: (ControllerProjectDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text(draft.existingProjectID == nil ? "Add Review Project" : "Edit Review Project")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("This saves OpenBurnBar's default review style and optional automatic schedule for a project.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Display name", text: $draft.displayName).textFieldStyle(.roundedBorder)
            TextField("Project slug", text: $draft.projectSlug).textFieldStyle(.roundedBorder)
            TextField("Summary", text: $draft.summary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3, reservesSpace: true)
            TextField("Aliases (comma separated)", text: $draft.aliasesText).textFieldStyle(.roundedBorder)
            TextField("Review model ID", text: $draft.reviewModelID).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Cadence", selection: $draft.preferredCadence) {
                    Text("Daily").tag(BurnBarControllerReviewCadence.daily)
                    Text("Weekly").tag(BurnBarControllerReviewCadence.weekly)
                    Text("Ad hoc").tag(BurnBarControllerReviewCadence.adHoc)
                }
                Picker("Automation", selection: $draft.automationMode) {
                    Text("Manual").tag(BurnBarControllerProjectAutomationMode.manual)
                    Text("Suggested").tag(BurnBarControllerProjectAutomationMode.suggested)
                    Text("Scheduled").tag(BurnBarControllerProjectAutomationMode.scheduled)
                }
            }
            HStack {
                Picker("Hour", selection: $draft.scheduleHourLocal) {
                    ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
                }
                Picker("Weekday", selection: $draft.scheduleWeekdayLocal) {
                    Text("Sunday").tag(1); Text("Monday").tag(2); Text("Tuesday").tag(3)
                    Text("Wednesday").tag(4); Text("Thursday").tag(5); Text("Friday").tag(6); Text("Saturday").tag(7)
                }
            }
            Toggle("Pause this project", isOn: $draft.isPaused)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.projectSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 520)
        .background(DesignSystem.Colors.background)
    }
}

/// Identifiable bridge so multiple citations OR a single citation can drive
/// `.sheet(item:)`. Each invocation gets a fresh `id` so re-tapping the
/// same chip presents a new sheet (intentional — the sheet's own controller
/// re-runs Hermes on every present).
struct CitationWrapper: Identifiable {
    let id: UUID
    let citations: [ProjectMemoryCitation]

    init(citations: [ProjectMemoryCitation]) {
        self.id = UUID()
        self.citations = citations
    }

    static func single(_ citation: ProjectMemoryCitation) -> CitationWrapper {
        CitationWrapper(citations: [citation])
    }
}

@MainActor
@Observable
final class ProjectMemoryInsightController {
    enum State: Equatable {
        case idle
        case streaming
        case complete
        case failed(String)
    }

    private(set) var streamingContent: String = ""
    private(set) var state: State = .idle

    private let chat: ChatSessionController
    private var trackedAssistantID: String?
    private var trackedAfterMessageCount: Int = 0
    private var streamTask: Task<Void, Never>?

    init(chatController: ChatSessionController) {
        self.chat = chatController
    }

    func generate(prompt: String) {
        cancel()
        streamingContent = ""
        state = .streaming
        trackedAfterMessageCount = chat.messages.count
        chat.inputText = prompt
        streamTask = Task { @MainActor in
            await chat.send()
        }
    }

    func observeStreamingTick(messages: [ChatMessageRecord], activeID: String?, isStreaming: Bool) {
        guard state == .streaming else { return }

        if trackedAssistantID == nil, let id = activeID {
            trackedAssistantID = id
        }

        let candidateID = trackedAssistantID ?? activeID
        let candidate: ChatMessageRecord? = {
            if let id = candidateID, let m = messages.first(where: { $0.id == id }) {
                return m
            }
            return messages.dropFirst(trackedAfterMessageCount).first(where: { $0.role == .assistant })
        }()

        if let msg = candidate {
            streamingContent = msg.content
        }

        if !isStreaming, activeID == nil {
            let trimmed = streamingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                state = .failed("Hermes returned no content. Open the chat panel to retry.")
            } else {
                state = .complete
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        trackedAssistantID = nil
    }
}
