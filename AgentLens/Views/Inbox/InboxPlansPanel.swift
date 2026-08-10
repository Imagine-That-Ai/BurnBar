import SwiftUI
import OpenBurnBarKernel

/// The Founder Plan ledger surface: every active plan, its steps, and the
/// explicit action controls that drive the documented loop — Promote to
/// mission, Create follow-up, Remember, and Grade. This is the reachable UI
/// for `InboxPlanPromoteService` / `approvePlanStep` / `inboxPlanGrade`;
/// without it the ledger would accept proposals and then strand them.
///
/// Every action is human-confirmed by construction (it IS the button), reads
/// back the daemon's truth after each mutation, and renders failures inline —
/// the same refusal-as-answer discipline as the reply thread.
@MainActor
final class InboxPlansModel: ObservableObject {
    @Published private(set) var plans: [BurnBarInboxPlan] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyStepIDs: Set<String> = []

    /// Project slug used for mission/follow-up creation. Nil when the item has
    /// no project attribution — the promote buttons disable with a hint rather
    /// than inventing a slug Mission Control has never seen.
    let projectSlug: String?
    private let memoryApproval: InboxMemoryApprovalHandler?

    init(projectSlug: String?, memoryApproval: InboxMemoryApprovalHandler?) {
        self.projectSlug = projectSlug
        self.memoryApproval = memoryApproval
    }

    private var socketURL: URL { OpenBurnBarDaemonRuntimePaths.live().socketURL }

    func refresh() async {
        let socketURL = self.socketURL
        do {
            plans = try await Task.detached(priority: .userInitiated) {
                try OpenBurnBarDaemonSocketClient.inboxPlans(at: socketURL)
            }.value
            errorMessage = nil
        } catch {
            // A daemon that is down is a state, not a crash: keep whatever we
            // last showed and say why it may be stale.
            errorMessage = error.localizedDescription
        }
    }

    private func withBusy(_ step: BurnBarInboxPlanStep, _ work: @escaping () async throws -> Void) async {
        guard busyStepIDs.contains(step.id) == false else { return }
        busyStepIDs.insert(step.id)
        defer { busyStepIDs.remove(step.id) }
        do {
            try await work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func promoteToMission(step: BurnBarInboxPlanStep, plan: BurnBarInboxPlan) async {
        guard let projectSlug else { return }
        await withBusy(step) {
            _ = try await InboxPlanPromoteService().promoteToMission(
                step: step,
                plan: plan,
                projectSlug: projectSlug
            )
        }
    }

    func createFollowup(step: BurnBarInboxPlanStep, plan: BurnBarInboxPlan) async {
        guard let projectSlug else { return }
        await withBusy(step) {
            _ = try await InboxPlanPromoteService().createFollowup(
                step: step,
                plan: plan,
                projectSlug: projectSlug
            )
        }
    }

    func remember(step: BurnBarInboxPlanStep, plan: BurnBarInboxPlan) async {
        guard let memoryApproval else { return }
        await withBusy(step) {
            _ = try await memoryApproval.approvePlanStep(plan: plan, step: step)
        }
    }

    func grade(step: BurnBarInboxPlanStep, grade: Int) async {
        let socketURL = self.socketURL
        await withBusy(step) {
            _ = try await Task.detached(priority: .userInitiated) {
                try OpenBurnBarDaemonSocketClient.inboxPlanGrade(
                    stepID: step.id,
                    grade: grade,
                    at: socketURL
                )
            }.value
        }
    }

    func markLanded(step: BurnBarInboxPlanStep) async {
        let socketURL = self.socketURL
        await withBusy(step) {
            _ = try await Task.detached(priority: .userInitiated) {
                try OpenBurnBarDaemonSocketClient.inboxPlanUpdateStep(
                    stepID: step.id,
                    status: .landed,
                    at: socketURL
                )
            }.value
        }
    }
}

struct InboxPlansPanel: View {
    @StateObject private var model: InboxPlansModel

    init(projectSlug: String?, memoryApproval: InboxMemoryApprovalHandler?) {
        _model = StateObject(
            wrappedValue: InboxPlansModel(projectSlug: projectSlug, memoryApproval: memoryApproval)
        )
    }

    var body: some View {
        // Render nothing until a plan exists — the ledger earns its pixels.
        if model.plans.isEmpty && model.errorMessage == nil {
            Color.clear
                .frame(height: 0)
                .task { await model.refresh() }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("FOUNDER PLANS")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.1)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            if let message = model.errorMessage {
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.plans) { plan in
                planCard(plan)
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private func planCard(_ plan: BurnBarInboxPlan) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(plan.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                OpenBurnBarStatusBadge(
                    title: plan.status.rawValue.capitalized,
                    color: plan.status == .active
                        ? DesignSystem.Colors.success
                        : DesignSystem.Colors.textMuted
                )
                if let average = plan.gradeAverage {
                    Text("grade \(Int(average.rounded()))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer(minLength: 0)
            }

            ForEach(plan.steps) { step in
                stepRow(step, in: plan)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stepRow(_ step: BurnBarInboxPlanStep, in plan: BurnBarInboxPlan) -> some View {
        let isBusy = model.busyStepIDs.contains(step.id)
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(step.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("· \(step.status.rawValue)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                if let grade = step.grade {
                    Text("· grade \(grade)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                if step.missionID != nil {
                    Image(systemName: "target")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .help("Promoted to mission")
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.mini) }
            }

            ElderWandFlowLayout(
                horizontalSpacing: DesignSystem.Spacing.xs,
                verticalSpacing: DesignSystem.Spacing.xs
            ) {
                if step.missionID == nil, step.status == .accepted || step.status == .inProgress {
                    actionButton("Promote to mission", systemImage: "target", disabled: isBusy || model.projectSlug == nil) {
                        Task { await model.promoteToMission(step: step, plan: plan) }
                    }
                    .help(model.projectSlug == nil ? "This item has no project attribution" : "Create a Mission Control mission from this step")
                }
                if step.followupID == nil, step.status != .killed {
                    actionButton("Follow up", systemImage: "bell", disabled: isBusy || model.projectSlug == nil) {
                        Task { await model.createFollowup(step: step, plan: plan) }
                    }
                }
                actionButton("Remember", systemImage: "brain.head.profile", disabled: isBusy) {
                    Task { await model.remember(step: step, plan: plan) }
                }
                if step.status == .accepted || step.status == .inProgress {
                    actionButton("Mark landed", systemImage: "checkmark.seal", disabled: isBusy) {
                        Task { await model.markLanded(step: step) }
                    }
                }
                Menu {
                    ForEach([95, 75, 50, 25], id: \.self) { grade in
                        Button("Grade \(grade)") {
                            Task { await model.grade(step: step, grade: grade) }
                        }
                    }
                } label: {
                    Label("Grade", systemImage: "chart.bar")
                        .font(DesignSystem.Typography.tiny)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isBusy)
            }
        }
        .padding(.leading, DesignSystem.Spacing.sm)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DesignSystem.Typography.tiny)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                        .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
