import SwiftUI

// MARK: - Usage-memory consent (first-run, U2)

/// U3 mount point: posted by the "Set up local model…" affordance so the local
/// curation-model setup wizard (U3) can present itself once it exists. Until U3
/// lands, posting this is intentionally a no-op — nothing observes it yet.
// TODO(U3): observe this notification from the local-model setup wizard and
// present the download/verify flow (Ollama model pull + capability probe).
extension Notification.Name {
    static let usageMemoryLocalModelSetupRequested =
        Notification.Name("UsageMemoryLocalModelSetupRequested")
}

/// Lets `.sheet(item:)` present the cloud-consent upgrade step for a chosen
/// placement (Settings → Privacy path).
extension UsageMemoryModelPlacement: Identifiable {
    var id: String { rawValue }
}

// MARK: - Honest-copy table (single source for sheet + settings)

/// The user-facing copy for each curation placement. Kept in one place so the
/// consent sheet and the Settings → Privacy picker can never drift apart on
/// what each option claims about egress.
enum UsageMemoryPlacementCopy {
    static func title(_ placement: UsageMemoryModelPlacement) -> String {
        switch placement {
        case .local: "Fully local"
        case .cloudText: "BurnBar Cloud — text"
        case .burnbarCloud: "BurnBar Cloud — text + images"
        }
    }

    /// The honest egress claim for each placement. Local states its system
    /// requirements upfront (product decision); cloud options state exactly
    /// what is sent, where it is pinned, and the retention posture.
    static func detail(_ placement: UsageMemoryModelPlacement) -> String {
        switch placement {
        case .local:
            "Candidate text never leaves this Mac. Uses your local model (Ollama). "
                + "Requires ~6 GB download / 8 GB+ unified memory; image understanding "
                + "needs ~9 GB (Apple silicon recommended)."
        case .cloudText:
            "Candidate text (never page content, never screenshots) is sent to "
                + "BurnBar's curation service, pinned to a US provider (CoreWeave via "
                + "OpenRouter) with zero data retention. Included with Pro."
        case .burnbarCloud:
            "Candidate text (never page content, never screenshots) is sent to "
                + "BurnBar's curation service, pinned to a US provider (CoreWeave via "
                + "OpenRouter) with zero data retention. Screenshots and attachments "
                + "in candidates may be included. Requires Pro Max."
        }
    }

    /// Static capability badge for cloud placements ("Pro" / "Pro Max").
    /// Deliberately not wired to live entitlement state — U2 ships no new
    /// entitlement plumbing; the badge names the required plan, nothing more.
    static func badge(_ placement: UsageMemoryModelPlacement) -> String? {
        switch placement {
        case .local: nil
        case .cloudText: "Pro"
        case .burnbarCloud: "Pro Max"
        }
    }
}

// MARK: - Flow model

/// Drives the multi-step usage-memory consent flow. Kept as a plain observable
/// model (no view introspection needed) so the step machine, the cloud-consent
/// fallback, and the write set are unit-testable.
///
/// Write responsibilities are split exactly like chat's `MemoryConsentSheet`:
/// the model persists the *choices made inside the flow* (placement, the
/// separate cloud-curation consent), while the top-level grant/decline is only
/// REPORTED via `onCompletion` — the integrator persists
/// `usageMemoryConsentGranted` / `usageMemoryConsentShown` (mirroring
/// `DashboardConsentCoordinator.confirmMemoryConsent(grant:)`).
@Observable
@MainActor
final class UsageMemoryConsentFlowModel {
    enum Mode: Equatable {
        /// Full first-run flow: what it does → where curation runs → (cloud consent).
        case firstRun
        /// Just the affirmative cloud-consent step, entered from Settings when
        /// the user picks a cloud placement without prior cloud consent. The
        /// associated placement is applied only on accept.
        case cloudUpgrade(UsageMemoryModelPlacement)
    }

    enum Step: Equatable {
        case whatItDoes
        case placement
        case cloudConsent
    }

    let mode: Mode
    private let settingsManager: SettingsManager
    /// Reports the top-level consent decision exactly once. Always `true` in
    /// `.cloudUpgrade` mode (usage-memory consent was already granted there;
    /// only the cloud step was in question).
    private let onCompletion: (Bool) -> Void
    private var didComplete = false

    private(set) var step: Step
    var selectedPlacement: UsageMemoryModelPlacement

    init(
        mode: Mode = .firstRun,
        settingsManager: SettingsManager,
        onCompletion: @escaping (Bool) -> Void
    ) {
        self.mode = mode
        self.settingsManager = settingsManager
        self.onCompletion = onCompletion
        switch mode {
        case .firstRun:
            self.step = .whatItDoes
            self.selectedPlacement = settingsManager.usageMemoryModelPlacement
        case .cloudUpgrade(let placement):
            self.step = .cloudConsent
            self.selectedPlacement = placement
        }
    }

    func advanceToPlacement() {
        step = .placement
    }

    func goBack() {
        switch step {
        case .placement:
            step = .whatItDoes
        case .cloudConsent where mode == .firstRun:
            step = .placement
        case .whatItDoes, .cloudConsent:
            break
        }
    }

    /// "Enable" on the placement step. A cloud placement without prior cloud
    /// consent routes through the separate affirmative cloud step; anything
    /// else grants directly.
    func confirmPlacementSelection() {
        if selectedPlacement.isCloud && !settingsManager.usageMemoryCloudCurationConsentGranted {
            step = .cloudConsent
        } else {
            completeGranting()
        }
    }

    /// Affirmative "Allow cloud curation": records the separate cloud consent,
    /// then applies the chosen placement and grants.
    func acceptCloudCuration() {
        settingsManager.usageMemoryCloudCurationConsentGranted = true
        completeGranting()
    }

    /// Declining the cloud step never cancels the flow: first-run falls back to
    /// the fully-local placement and still grants; the Settings upgrade path
    /// simply leaves the existing placement untouched.
    func declineCloudCuration() {
        switch mode {
        case .firstRun:
            selectedPlacement = .local
            completeGranting()
        case .cloudUpgrade:
            complete(granted: true)
        }
    }

    /// "Not now" on the first-run flow: no writes here — the integrator marks
    /// the prompt shown without granting.
    func decline() {
        complete(granted: false)
    }

    /// Stub affordance for U3's local-model setup wizard (see the
    /// `usageMemoryLocalModelSetupRequested` mount point above).
    func requestLocalModelSetup() {
        NotificationCenter.default.post(name: .usageMemoryLocalModelSetupRequested, object: nil)
    }

    private func completeGranting() {
        settingsManager.usageMemoryModelPlacement = selectedPlacement
        complete(granted: true)
    }

    private func complete(granted: Bool) {
        guard !didComplete else { return }
        didComplete = true
        onCompletion(granted)
    }
}

// MARK: - Sheet

/// First-run consent before OpenBurnBar derives memories from what the user
/// actually does (Safari asks + recorded agent sessions). Mirrors
/// `MemoryConsentSheet`'s structure, sizing, and glass surface so the two
/// memory permission moments feel like one app. Step logic lives in
/// `UsageMemoryConsentFlowModel`; the integrator persists the top-level
/// grant/decline via `onDecision`.
struct UsageMemoryConsentSheet: View {
    @Bindable var settingsManager: SettingsManager
    @State private var model: UsageMemoryConsentFlowModel

    init(
        settingsManager: SettingsManager,
        mode: UsageMemoryConsentFlowModel.Mode = .firstRun,
        onDecision: @escaping (Bool) -> Void
    ) {
        self.settingsManager = settingsManager
        self._model = State(initialValue: UsageMemoryConsentFlowModel(
            mode: mode,
            settingsManager: settingsManager,
            onCompletion: onDecision
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            switch model.step {
            case .whatItDoes: whatItDoesStep
            case .placement: placementStep
            case .cloudConsent: cloudConsentStep
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 480)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .liquidGlassSurface(
            in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous),
            fallback: .ultraThinMaterial
        )
    }

    // MARK: Step 1 — What usage memory does

    private var whatItDoesStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header(
                icon: "clock.arrow.circlepath",
                title: "Remember what you actually do?",
                intro: "OpenBurnBar can propose durable memories from what you actually do: "
                    + "questions you ask in Safari and your recorded agent sessions."
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                bullet(
                    icon: "tray.full",
                    tint: DesignSystem.Colors.ember.opacity(0.9),
                    text: "Everything lands quarantined. Nothing is used in chat until you approve it in the review inbox."
                )
                bullet(
                    icon: "trash.slash",
                    tint: DesignSystem.Colors.amber.opacity(0.9),
                    text: "Forget is permanent. Reject or delete a proposed memory and it's gone for good."
                )
                bullet(
                    icon: "slider.horizontal.3",
                    tint: DesignSystem.Colors.textMuted,
                    text: "Pick the sources below — change them anytime in Settings → Privacy."
                )
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                SettingsToggle(
                    title: "Safari asks",
                    subtitle: "Questions you ask from Safari.",
                    isOn: $settingsManager.usageMemorySourceSafariAsksEnabled
                )
                SettingsToggle(
                    title: "Agent sessions",
                    subtitle: "Your recorded agent session logs.",
                    isOn: $settingsManager.usageMemorySourceAgentSessionsEnabled
                )
            }
            .padding(.leading, DesignSystem.Spacing.lg)

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Not now") {
                    model.decline()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Continue") {
                    model.advanceToPlacement()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Step 2 — Where curation runs

    private var placementStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header(
                icon: "cpu",
                title: "Where curation runs",
                intro: "Choose where the model that curates usage-memory candidates runs. "
                    + "You can change this anytime in Settings → Privacy."
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(UsageMemoryModelPlacement.allCases) { placement in
                    placementOptionRow(placement)
                }
            }

            if model.selectedPlacement == .local {
                Button {
                    model.requestLocalModelSetup()
                } label: {
                    Label("Set up local model…", systemImage: "arrow.down.circle")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Back") {
                    model.goBack()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Enable usage memory") {
                    model.confirmPlacementSelection()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Step 3 — Allow cloud curation (affirmative, separate)

    private var cloudConsentStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header(
                icon: "cloud",
                title: "Allow cloud curation?",
                intro: "You picked \(UsageMemoryPlacementCopy.title(model.selectedPlacement)). "
                    + "Nothing is sent until you allow this."
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                bullet(
                    icon: "arrow.up.circle",
                    tint: DesignSystem.Colors.ember.opacity(0.9),
                    text: UsageMemoryPlacementCopy.detail(model.selectedPlacement)
                )
                bullet(
                    icon: "checkmark.shield",
                    tint: DesignSystem.Colors.success.opacity(0.9),
                    text: "Approval still happens on this Mac: cloud curation only proposes candidates for your review inbox."
                )
            }

            HStack(spacing: DesignSystem.Spacing.md) {
                if model.mode == .firstRun {
                    Button("Back") {
                        model.goBack()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Keep it fully local") {
                    model.declineCloudCuration()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Allow cloud curation") {
                    model.acceptCloudCuration()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Pieces

    private func header(icon: String, title: String, intro: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.35),
                                DesignSystem.Colors.amber.opacity(0.25)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(intro)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func placementOptionRow(_ placement: UsageMemoryModelPlacement) -> some View {
        let isSelected = model.selectedPlacement == placement
        return Button {
            model.selectedPlacement = placement
        } label: {
            UsageMemoryPlacementRowLabel(placement: placement, isSelected: isSelected)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func bullet(icon: String, tint: Color, text: String) -> some View {
        Label {
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
    }
}

/// Shared label for one placement option row (radio indicator + title +
/// capability badge + the honest egress claim). Used by both the consent
/// sheet's chooser and the Settings → Privacy picker so the two surfaces
/// render the copy identically.
struct UsageMemoryPlacementRowLabel: View {
    let placement: UsageMemoryModelPlacement
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(UsageMemoryPlacementCopy.title(placement))
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    if let badge = UsageMemoryPlacementCopy.badge(placement) {
                        UsageMemoryCapabilityBadge(label: badge)
                    }
                }
                Text(UsageMemoryPlacementCopy.detail(placement))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

/// Small static capability badge ("Pro" / "Pro Max") for cloud placement rows.
struct UsageMemoryCapabilityBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.amber)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(DesignSystem.Colors.amber.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(DesignSystem.Colors.amber.opacity(0.35), lineWidth: 0.5)
            )
    }
}
