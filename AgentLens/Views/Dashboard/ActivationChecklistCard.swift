import AppKit
import SwiftUI

// MARK: - Activation Checklist (T1.6)

/// A compact, self-retiring card that walks a fresh install through the five
/// switches the product ships with off — as earned, imperative steps, never a
/// wizard. Done-states are derived live by `ActivationChecklistModel`; the
/// card disappears forever once every switch is on (one quiet beat) or the
/// moment the user dismisses it.
struct ActivationChecklistSection: View {
    let context: DashboardContext
    let onOpenSettings: () -> Void

    @State private var model: ActivationChecklistModel
    @State private var showMemoryConsent = false

    init(context: DashboardContext, onOpenSettings: @escaping () -> Void) {
        self.context = context
        self.onOpenSettings = onOpenSettings
        // Built eagerly (not in `.task`) so a retired checklist renders
        // nothing at all — no placeholder view waiting for a model, and no
        // stray spacing slot in the overview stack. `State(initialValue:)`
        // keeps the first instance for the view's lifetime; the model's init
        // only captures references, so rebuilding the struct stays free.
        _model = State(initialValue: ActivationChecklistModel(
            settingsManager: context.settingsManager,
            dataStore: context.dataStore
        ))
    }

    var body: some View {
        if model.shouldShowCard {
            ActivationChecklistCard(
                model: model,
                onAction: { handle($0, model: model) },
                onDismiss: {
                    withAnimation(DesignSystem.Animation.gentle) { model.dismiss() }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .task { await model.refreshInboxEnabled() }
            // Four of the five switches are observed live through
            // SettingsManager. The inbox lever is daemon-owned config, so
            // re-read it whenever this window regains key — which is exactly
            // the moment the user comes back from the Settings sheet where
            // that switch lives. The probe is guarded and loopback-cheap, so
            // the broad trigger costs nothing in steady state.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                Task { await model.refreshInboxEnabled() }
            }
            .onChange(of: model.allStepsDone) { _, done in
                if done {
                    withAnimation(DesignSystem.Animation.gentle) { model.markCompletedIfNeeded() }
                }
            }
            .sheet(isPresented: $showMemoryConsent) {
                MemoryConsentSheet { grant in
                    model.recordMemoryConsent(granted: grant)
                    showMemoryConsent = false
                }
                .presentationBackground(Material.ultraThinMaterial)
            }
        }
    }

    private func handle(_ action: ActivationChecklistModel.StepAction, model: ActivationChecklistModel) {
        switch action {
        case .scanNow:
            Task { await context.aggregator?.refreshAll() }
        case .openSettingsItem(let itemID):
            // Same parked-item mechanism the menu-bar popover uses: works both
            // when the Settings sheet is already open (notification) and when
            // it is about to appear (pending key consumed on appear).
            SettingsDeepLinkRouting.route(to: itemID)
            onOpenSettings()
        case .presentMemoryConsent:
            showMemoryConsent = true
        }
    }
}

// MARK: - Card

private struct ActivationChecklistCard: View {
    let model: ActivationChecklistModel
    let onAction: (ActivationChecklistModel.StepAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if model.isShowingCompletionBeat {
                    completionBeat
                } else {
                    header
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        ForEach(model.steps) { step in
                            ActivationStepRow(step: step, onAction: onAction)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("Switch it on")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Spacer()

            Text("\(model.doneCount) of \(model.steps.count)")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Hide this checklist for good")
        }
    }

    private var completionBeat: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.success)

            Text("All five switches are on. This card retires itself.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Spacer()
        }
        // The beat times itself out from the view so the retirement animates;
        // the completion timestamp is already stamped, so even a mid-beat
        // window close retires the card for good.
        .task {
            try? await Task.sleep(nanoseconds: ActivationChecklistModel.completionBeatNanoseconds) // try?-ok(beat cancellation only)
            withAnimation(DesignSystem.Animation.gentle) { model.finishCompletionBeat() }
        }
    }
}

// MARK: - Step Row

private struct ActivationStepRow: View {
    let step: ActivationChecklistModel.Step
    let onAction: (ActivationChecklistModel.StepAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    step.isDone
                        ? DesignSystem.Colors.success
                        : (step.isCurrent ? DesignSystem.Colors.amber : DesignSystem.Colors.textMuted)
                )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(step.title)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(step.isCurrent ? .semibold : .regular)
                    .foregroundStyle(
                        step.isDone
                            ? DesignSystem.Colors.textMuted
                            : (step.isCurrent ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    )

                // Only the current step explains itself — later steps stay
                // quiet so the card reads as one move at a time, not a wizard.
                if step.isCurrent {
                    Text(step.detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            if !step.isDone {
                // One action verb per incomplete step: prominent on the
                // current step, quiet on the ones that come after it.
                if step.isCurrent {
                    Button(step.actionTitle) {
                        onAction(step.action)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(DesignSystem.Colors.blaze)
                } else {
                    Button(step.actionTitle) {
                        onAction(step.action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
