import SwiftUI
import OpenBurnBarKernel

// MARK: - Controller Workbench

struct OpenBurnBarControllerWorkbenchPanel: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    var condensed: Bool

    var body: some View {
        let runtime = layer.snapshot.controllerRuntime

        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        OperatingViewHelpers.sectionHeader(title: condensed ? "Controller" : "Controller Inbox")
                        Text(runtime.summary.headline)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text(runtime.summary.detail)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        OpenBurnBarStatusBadge(title: runtime.source.label, color: DesignSystem.Colors.blaze)
                        Text(runtime.updatedAt == .distantPast ? "Awaiting runtime" : runtime.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                OpenBurnBarControllerCompactSummary(runtime: runtime)

                if runtime.pendingQuestions.isEmpty == false {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Pending Questions")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)
                        ForEach(runtime.pendingQuestions.prefix(condensed ? 1 : 3)) { question in
                            OpenBurnBarQuestionRow(layer: layer, question: question, condensed: condensed)
                        }
                    }
                }

                if runtime.openFollowups.isEmpty == false {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Followups")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)
                        ForEach(runtime.openFollowups.prefix(condensed ? 1 : 3)) { followup in
                            OpenBurnBarFollowupRow(layer: layer, followup: followup)
                        }
                    }
                }

                if let mission = runtime.missions.first {
                    Divider().background(DesignSystem.Colors.border)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Mission Runtime")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mission.title)
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text(mission.packetSummary?.nonEmpty ?? mission.summary)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 6) {
                                    OpenBurnBarStatusBadge(title: mission.state.label, color: mission.state.color)
                                    OpenBurnBarStatusBadge(title: mission.approval.label, color: mission.approval.color)
                                }
                            }

                            HStack(spacing: DesignSystem.Spacing.xs) {
                                missionChip(title: "Burn", value: mission.burnCostUSD.formatAsCost(), color: DesignSystem.Colors.hermesAureate)
                                if mission.packetRunCount > 0 {
                                    missionChip(title: "Runs", value: "\(mission.packetRunCount)", color: DesignSystem.Colors.blaze)
                                }
                                if mission.takeoverCount > 0 {
                                    missionChip(
                                        title: "Takeovers",
                                        value: "\(mission.takeoverCount)",
                                        color: mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze
                                    )
                                }
                            }

                            if let activeWorkerName = mission.activeWorkerName?.nonEmpty
                                ?? mission.packetSummary?.nonEmpty {
                                missionFactRow(
                                    icon: "bolt.horizontal.circle.fill",
                                    title: "Active packet",
                                    value: activeWorkerName
                                )
                            }
                            if let activeRunID = mission.activeRunID?.nonEmpty {
                                missionFactRow(
                                    icon: "point.3.filled.connected.trianglepath.dotted",
                                    title: "Run provenance",
                                    value: activeRunID
                                )
                            }
                            if let latestResult = mission.latestResultSummary?.nonEmpty {
                                missionFactRow(
                                    icon: "checklist.checked",
                                    title: "Latest result",
                                    value: latestResult
                                )
                            }
                            if let takeoverState = mission.latestTakeoverState,
                               let takeoverReason = mission.latestTakeoverReason?.nonEmpty {
                                missionFactRow(
                                    icon: "arrow.triangle.branch",
                                    title: takeoverState.label,
                                    value: takeoverReason,
                                    accent: takeoverState.color
                                )
                            }
                            if let takeoverRunID = mission.latestTakeoverRunID?.nonEmpty {
                                missionFactRow(
                                    icon: "figure.run",
                                    title: "Takeover run",
                                    value: takeoverRunID
                                )
                            }
                        }
                    }
                }

                if runtime.recentEvents.isEmpty == false {
                    Divider().background(DesignSystem.Colors.border)
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Recent Controller Events")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)
                        ForEach(runtime.recentEvents.prefix(condensed ? 2 : 4)) { event in
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                                Image(systemName: event.category.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(event.category.color)
                                    .frame(width: 16, alignment: .top)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    Text(event.summary)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let detail = event.detail?.nonEmpty {
                                        Text(detail)
                                            .font(DesignSystem.Typography.tiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                Text(OperatingViewHelpers.relativeTime(from: event.createdAt))
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                        }
                    }
                }

                if let feedback = layer.controllerFeedback {
                    Text(feedback.message)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(feedback.tone.color)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    @ViewBuilder
    private func missionChip(title: String, value: String, color: Color) -> some View {
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
    }

    @ViewBuilder
    private func missionFactRow(
        icon: String,
        title: String,
        value: String,
        accent: Color = DesignSystem.Colors.textPrimary
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Text(value)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

struct OpenBurnBarQuestionRow: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    let question: OpenBurnBarControllerQuestion
    let condensed: Bool

    init(layer: OpenBurnBarOperatingLayer, question: OpenBurnBarControllerQuestion, condensed: Bool = false) {
        self._layer = Bindable(layer)
        self.question = question
        self.condensed = condensed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if question.isUnread {
                            Circle()
                                .fill(DesignSystem.Colors.ember)
                                .frame(width: 7, height: 7)
                        }
                        Text(question.title)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if let stageLabel = question.stageLabel?.nonEmpty {
                            Text(stageLabel)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.blaze)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(DesignSystem.Colors.blaze.opacity(0.12))
                                )
                        }
                    }
                    if let deepLink = question.deepLink {
                        HStack(spacing: 4) {
                            Image(systemName: icon(for: deepLink.kind))
                                .font(.system(size: 9, weight: .semibold))
                            Text(deepLink.title)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    OpenBurnBarStatusBadge(title: question.priority.rawValue.capitalized, color: question.priority.color)
                    if question.notificationCount > 0 {
                        Text("Nudged \(question.notificationCount)x")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
            }
            Text(question.prompt)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let evidenceHint = question.evidenceHint?.nonEmpty {
                Text(evidenceHint)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            if condensed == false, question.suggestedOptions.isEmpty == false {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(question.suggestedOptions.prefix(2)) { option in
                        Button {
                            Task {
                                await layer.answerPendingQuestion(
                                    id: question.id,
                                    answer: option.answer,
                                    selectedOptionID: option.id
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                if let detail = option.detail?.nonEmpty {
                                    Text(detail)
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.9))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, DesignSystem.Spacing.xxs)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            LinearGradient(
                colors: [
                    DesignSystem.Colors.surface.opacity(0.82),
                    question.isUnread ? DesignSystem.Colors.ember.opacity(0.08) : DesignSystem.Colors.surfaceElevated.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private func icon(for kind: OpenBurnBarControllerQuestionDeepLinkKind) -> String {
        switch kind {
        case .sessionLog: return "doc.text.magnifyingglass"
        case .dashboard: return "square.grid.2x2"
        case .project: return "folder"
        case .settings: return "gearshape"
        }
    }
}

struct OpenBurnBarFollowupRow: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    let followup: OpenBurnBarControllerFollowup

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                Text(followup.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                if let dueAt = followup.dueAt {
                    Text(dueAt.formatted(date: .omitted, time: .shortened))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(followup.summary)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Done") {
                    Task { await layer.completeFollowup(id: followup.id) }
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.success)

                Button("Snooze") {
                    let until = Date().addingTimeInterval(Double(layer.settingsManager.controllerDefaultSnoozeMinutes) * 60)
                    Task { await layer.snoozeFollowup(id: followup.id, until: until) }
                }
                .buttonStyle(.plain)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.amber)

                if layer.settingsManager.controllerCalendarIntegrationEnabled {
                    Button("Calendar") {
                        Task { await layer.scheduleFollowupCalendar(id: followup.id, title: followup.title) }
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.teal)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }
}
