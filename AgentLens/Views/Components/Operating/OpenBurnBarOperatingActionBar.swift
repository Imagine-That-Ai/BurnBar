import SwiftUI
import OpenBurnBarCore

// MARK: - Mission Authoring Sheet

struct OpenBurnBarMissionAuthoringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var layer: OpenBurnBarOperatingLayer

    @State private var projectSlug: String = ""
    @State private var title: String = ""
    @State private var summary: String = ""
    @State private var recommendation: BurnBarMissionRecommendation = .review
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Create Mission")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Define a new mission for OpenBurnBar to plan, dispatch, and track execution.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Project")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                TextField("e.g., apollo, my-project", text: $projectSlug)
                    .textFieldStyle(.roundedBorder)
                if let projectName = layer.snapshot.projectName, !projectName.isEmpty, projectSlug.isEmpty {
                    Text("Tip: \(projectName) is your current project")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Title")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                TextField("What should this mission accomplish?", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Summary")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                TextEditor(text: $summary)
                    .frame(minHeight: 100)
                    .padding(6)
                    .background(DesignSystem.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Recommendation")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Picker("Recommendation", selection: $recommendation) {
                    Text("Proceed").tag(BurnBarMissionRecommendation.proceed)
                    Text("Review").tag(BurnBarMissionRecommendation.review)
                    Text("Pause").tag(BurnBarMissionRecommendation.pause)
                    Text("Escalate").tag(BurnBarMissionRecommendation.escalate)
                }
                .pickerStyle(.segmented)
                Text(recommendationHint)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            if let error = errorMessage {
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                Button {
                    createMission()
                } label: {
                    if isCreating {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Create Mission")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
                .disabled(isCreating || !isValid)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 480, idealWidth: 520)
        .onAppear {
            if let projectName = layer.snapshot.projectName, !projectName.isEmpty {
                projectSlug = projectName.lowercased().replacingOccurrences(of: " ", with: "-")
            }
        }
    }

    private var isValid: Bool {
        !projectSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recommendationHint: String {
        switch recommendation {
        case .proceed:
            return "OpenBurnBar will attempt autonomous execution without additional approval gates."
        case .review:
            return "OpenBurnBar will plan and present the plan for your review before dispatching."
        case .pause:
            return "OpenBurnBar will create the mission but defer planning until you explicitly resume."
        case .escalate:
            return "OpenBurnBar will escalate this mission to a human reviewer before any planning or execution."
        }
    }

    private func createMission() {
        guard isValid else { return }
        isCreating = true
        errorMessage = nil

        Task { @MainActor in
            do {
                _ = try await layer.createMission(
                    projectSlug: projectSlug,
                    title: title,
                    summary: summary,
                    recommendation: recommendation
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

// MARK: - Operating Action Bar

struct OpenBurnBarActionButton: View {
    let title: String
    let icon: String
    let compact: Bool
    let enabled: Bool
    let emphasized: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
                Text(title)
                    .font(compact ? DesignSystem.Typography.tiny : DesignSystem.Typography.caption)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, compact ? DesignSystem.Spacing.sm : DesignSystem.Spacing.md)
            .padding(.vertical, compact ? DesignSystem.Spacing.xs + 2 : DesignSystem.Spacing.sm)
            .background(backgroundShape)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var foregroundColor: Color {
        guard enabled else { return DesignSystem.Colors.textMuted }
        return emphasized ? DesignSystem.Colors.blaze : DesignSystem.Colors.textPrimary
    }

    @ViewBuilder
    private var backgroundShape: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill((enabled ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surface).opacity(emphasized ? 0.7 : 0.45))
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(enabled ? DesignSystem.Colors.blaze.opacity(0.25) : DesignSystem.Colors.border.opacity(0.25), lineWidth: 0.6)
        }
    }
}

struct OpenBurnBarDirectionOverrideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var layer: OpenBurnBarOperatingLayer

    @State private var mode: OpenBurnBarDirectionOverrideModeKind = .supersedeStatus
    @State private var forcedStatus: OpenBurnBarDirectionAssessment = .aligned
    @State private var summary: String = ""
    @State private var rationale: String = ""

    var body: some View {
        let snapshot = layer.snapshot

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text("Direction Override")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Record an operator call for \(snapshot.projectName ?? "this project"). OpenBurnBar will carry it across dashboard, popover, and Hermes.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Mode", selection: $mode) {
                ForEach(OpenBurnBarDirectionOverrideModeKind.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if mode == .supersedeStatus {
                Picker("Status", selection: $forcedStatus) {
                    ForEach(OpenBurnBarDirectionAssessment.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Summary")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                TextField("What should OpenBurnBar carry forward?", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Rationale")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                TextEditor(text: $rationale)
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(DesignSystem.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
                    )
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                Spacer()

                Button("Save Override") {
                    layer.saveDirectionOverride(
                        mode: mode,
                        forcedStatus: mode == .supersedeStatus ? forcedStatus : nil,
                        summary: summary,
                        rationale: rationale
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.blaze)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 420, idealWidth: 460)
        .onAppear {
            if let projectName = snapshot.projectName {
                summary = snapshot.direction.overrideSummary?.nonEmpty
                    ?? "OpenBurnBar should carry my latest call for \(projectName)."
            }
            rationale = snapshot.direction.sparseReason?.nonEmpty
                ?? snapshot.direction.summary
        }
    }
}

struct OpenBurnBarOperatingActionBar: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    var compact: Bool
    @State private var showingDirectionOverride = false
    @State private var showingMissionAuthoring = false

    var body: some View {
        let snapshot = layer.snapshot
        let missionAction = snapshot.availableActions.first(where: { $0.kind == .missionApproval })
        let directionAction = snapshot.availableActions.first(where: { $0.kind == .directionOverride })

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                OpenBurnBarActionButton(
                    title: missionAction?.title ?? OpenBurnBarActionKind.missionApproval.label,
                    icon: OpenBurnBarActionKind.missionApproval.icon,
                    compact: compact,
                    enabled: missionAction?.available == true,
                    emphasized: missionAction?.available == true
                ) {
                    layer.approveMission()
                }

                OpenBurnBarActionButton(
                    title: directionAction?.title ?? OpenBurnBarActionKind.directionOverride.label,
                    icon: OpenBurnBarActionKind.directionOverride.icon,
                    compact: compact,
                    enabled: directionAction?.available == true,
                    emphasized: directionAction?.available == true
                ) {
                    showingDirectionOverride = true
                }

                OpenBurnBarActionButton(
                    title: compact ? "Create" : "Create Mission",
                    icon: OpenBurnBarActionKind.missionCreation.icon,
                    compact: compact,
                    enabled: true,
                    emphasized: false
                ) {
                    showingMissionAuthoring = true
                }
            }

            if compact == false {
                if let missionReason = missionAction?.reason.nonEmpty {
                    Text(missionReason)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            } else if let pending = snapshot.pendingHighlight?.nonEmpty {
                Text(pending)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }

            if let feedback = layer.actionFeedback {
                Text(feedback.detail?.nonEmpty ?? feedback.message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(feedback.tone.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingDirectionOverride) {
            OpenBurnBarDirectionOverrideSheet(layer: layer)
                .presentationBackground(Material.ultraThinMaterial)
        }
        .sheet(isPresented: $showingMissionAuthoring) {
            OpenBurnBarMissionAuthoringSheet(layer: layer)
                .presentationBackground(Material.ultraThinMaterial)
        }
    }
}
