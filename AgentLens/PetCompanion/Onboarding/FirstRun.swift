import AppKit
import SwiftUI

// MARK: - PetFirstRunModel

/// State for the one-window first-run flow (PLAN C8): pick a pet, choose the
/// default agent, grant the global-hotkey + accessibility permission, see live
/// `checkAuth()` per provider, and land the pet on screen.
///
/// `@MainActor @Observable`: it probes the agent layer (off-main work `await`ed
/// back here) and mutates AppKit registration via the shell coordinators.
@MainActor
@Observable
final class PetFirstRunModel {

    /// The onboarding step the window is showing.
    enum Step: Int, CaseIterable {
        case pickPet, pickAgent, permissions, land

        var title: String {
            switch self {
            case .pickPet: return "Choose your companion"
            case .pickAgent: return "Pick the answering agent"
            case .permissions: return "Grant the summon hotkey"
            case .land: return "You're all set"
            }
        }
    }

    var step: Step = .pickPet
    var selectedPetID: String
    var authStates: [ChatBackendID: PetAuthStatus] = [:]
    /// Whether the global hotkey successfully registered.
    private(set) var hotkeyRegistered = false
    private(set) var isProbing = false

    /// The provider façades used purely for the live auth probe (reuses the shared
    /// ``CLIBridge`` — never a parallel transport, Ground Truth #2).
    private let providers: [AgentChatProvider]

    init(bridge: CLIBridge, selectedPetID: String = PetCompanionFeature.activePetID) {
        self.selectedPetID = selectedPetID
        self.providers = PetChatProviders.all(bridge: bridge)
        for backend in ChatBackendID.allCases { authStates[backend] = .unknown }
    }

    // MARK: Live auth (PLAN C8 "Auth state for each provider is shown live")

    /// Probe every provider's `checkAuth()` and publish the result per backend.
    func refreshAuth() async {
        isProbing = true
        defer { isProbing = false }
        for provider in providers {
            let status = await provider.checkAuth()
            authStates[provider.id] = status
        }
    }

    // MARK: Permissions

    /// Register the global hotkey (the only permission the pet strictly needs;
    /// Carbon hotkeys don't require Accessibility, but we still surface the
    /// Accessibility prompt for users who want richer cursor-aware behavior).
    func grantHotkey() {
        hotkeyRegistered = PetHotkey.shared.enable()
    }

    /// Open System Settings → Privacy → Accessibility so the user can grant the
    /// (optional) accessibility permission for cursor-proximity behaviors.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Completion

    /// Persist the choices, start + show the companion, and mark first-run done.
    func finish() {
        UserDefaults.standard.set(selectedPetID, forKey: PetCompanionFeature.DefaultsKey.activePetID)
        UserDefaults.standard.set(true, forKey: PetCompanionFeature.DefaultsKey.enabled)
        PetCompanionFeature.showCompanion()
        PetSystemObservers.shared.start()
        Self.markCompleted()
    }

    // MARK: First-run gate

    private static let completedKey = "pet.firstRunCompleted"

    /// Whether onboarding has already been completed (the launch hook checks this).
    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}

// MARK: - PetFirstRunView

/// The single onboarding window (PLAN C8). Reachable from the menubar; the host
/// presents it in an `NSWindow`/`NSHostingView` (the build-notes agent documents
/// the one-line `WindowManager.openPetOnboarding()` mirror).
struct PetFirstRunView: View {
    @Bindable var model: PetFirstRunModel
    /// Called when onboarding completes or is dismissed, so the host can close the
    /// window.
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            Divider().opacity(0.4)
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(width: 460, height: 520)
        .background(DesignSystem.Colors.background)
        .task { await model.refreshAuth() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            Text(model.step.title)
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Step \(model.step.rawValue + 1) of \(PetFirstRunModel.Step.allCases.count)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .pickPet:
            PetFormPickerView(selectedPetID: $model.selectedPetID) { id, form in
                model.selectedPetID = id
                // Live skin swap if the pet is already on screen (PLAN C8 accept).
                if PetCompanionController.shared.isVisible {
                    PetCompanionController.shared.setForm(form)
                }
            }
        case .pickAgent:
            PetAgentSwitcher(authStates: model.authStates) { backend in
                PetCompanionController.shared.chat?.switchBackend(to: backend)
            }
            if model.isProbing {
                Label("Checking agents…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        case .permissions:
            permissionsStep
        case .land:
            landStep
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            permissionRow(
                title: "Summon hotkey (\(PetHotkey.shared.combo.displayString))",
                detail: "Press it from anywhere to summon or dismiss the chat bubble.",
                granted: model.hotkeyRegistered,
                action: { model.grantHotkey() },
                actionLabel: model.hotkeyRegistered ? "Enabled" : "Enable"
            )
            permissionRow(
                title: "Accessibility (optional)",
                detail: "Lets the pet react to your cursor. You can skip this.",
                granted: false,
                action: { model.openAccessibilitySettings() },
                actionLabel: "Open Settings"
            )
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void,
        actionLabel: String
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? AnyShapeStyle(DesignSystem.Colors.success)
                                         : AnyShapeStyle(DesignSystem.Colors.textMuted))
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 0)
            Button(actionLabel, action: action)
                .disabled(granted)
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    private var landStep: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 44))
                .foregroundStyle(DesignSystem.Colors.primaryGradient)
            Text("Your companion will land in the corner. Click it to chat, or press \(PetHotkey.shared.combo.displayString) to summon the bubble.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignSystem.Spacing.xl)
    }

    private var footer: some View {
        HStack {
            if model.step != .pickPet {
                Button("Back") { stepBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
            Button(model.step == .land ? "Let it land" : "Continue") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func stepBack() {
        if let prev = PetFirstRunModel.Step(rawValue: model.step.rawValue - 1) {
            model.step = prev
        }
    }

    private func advance() {
        switch model.step {
        case .pickPet, .pickAgent, .permissions:
            if let next = PetFirstRunModel.Step(rawValue: model.step.rawValue + 1) {
                model.step = next
            }
        case .land:
            model.finish()
            onDone()
        }
    }
}
