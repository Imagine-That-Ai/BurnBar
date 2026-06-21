import SwiftUI

// MARK: - PetCompanionFeature

/// The additive integration surface for the pet companion. Everything the app
/// shell needs to wire the feature lives here, so the existing files
/// (`AgentLensApp.swift`, `MenuBarPopoverView.swift`, `SettingsManager.swift`)
/// stay untouched this wave. The build-notes agent documents the one-line
/// insertions.
///
/// The enable flag is self-contained via `@AppStorage` (`"pet.companionEnabled"`)
/// rather than editing `SettingsManager`, mirroring PLAN C7's
/// `@AppStorage("pet.activeAgent")`. When the integrator later folds it into
/// `SettingsManager`, the same UserDefaults key carries over.
@MainActor
enum PetCompanionFeature {
    /// UserDefaults keys the feature owns (kept in one place for the integrator).
    enum DefaultsKey {
        static let enabled = "pet.companionEnabled"
        static let activeAgent = "pet.activeAgent"
        static let activePetID = "pet.activePetID"
    }

    /// The bundled pet shown by default until the form/agent picker (C8) lands.
    static let defaultPetID = "claudecode"

    /// Read the persisted enable flag without a SwiftUI binding (for the launch
    /// hook below).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    static var activePetID: String {
        UserDefaults.standard.string(forKey: DefaultsKey.activePetID) ?? defaultPetID
    }

    /// Launch hook — call from the `.task` block where the app spins up its other
    /// lazy services (`MenuBarLabel` in `AgentLensApp.swift`). Registers the real
    /// SpriteKit 2D backend (C4), then, if the user left the companion enabled,
    /// loads its definition and shows it. Additive: no existing window flow is
    /// touched. Idempotent — safe to call once per launch.
    static func activateIfEnabled(chat: ChatSessionController? = nil) {
        // Register the renderer backends: SpriteKit as the 2D default, then
        // SceneKit layered on top to route `model3d` forms to 3D (atlas forms
        // stay on SpriteKit). Order matters — `SceneKitPetRenderer.register`
        // wraps the current (SpriteKit) factory for the atlas branch.
        SpriteKitPetRenderer.registerAsDefault()
        SceneKitPetRenderer.register()

        // Reuse the app's shared chat controller for the bubble's answering brain
        // (Ground Truth #2 — never duplicate the agent layer). Safe to pass nil
        // when the chat stack isn't built yet; the pet then runs ambient-only.
        if let chat {
            PetCompanionController.shared.attachChat(chat)
        }

        // Hardening + summon hotkey come up regardless of the enable flag so the
        // pet can be summoned the first time the user flips it on (C8/C9).
        PetHotkey.shared.enable()
        PetSystemObservers.shared.start()

        guard isEnabled else { return }
        showCompanion()
    }

    /// Whether the one-window onboarding should run on this launch (first launch
    /// with the companion never set up). The host presents ``PetFirstRunView``
    /// when this is `true` (build-notes documents the `WindowManager` mirror).
    static var shouldRunFirstRun: Bool {
        !PetFirstRunModel.hasCompleted
    }

    /// Load the active pet's definition and start + show the companion. Falls back
    /// silently if the definition resource is missing (no crash, no error toast).
    static func showCompanion() {
        guard let definition = loadActiveDefinition() else { return }
        PetCompanionController.shared.start(with: definition)
        PetCompanionController.shared.show()
    }

    static func hideCompanion() {
        PetCompanionController.shared.hide()
    }

    /// Toggle visibility and persist the new enabled state.
    static func toggleCompanion() {
        let controller = PetCompanionController.shared
        if controller.isVisible {
            controller.hide()
            UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
        } else {
            UserDefaults.standard.set(true, forKey: DefaultsKey.enabled)
            showCompanion()
        }
    }

    /// Resolve the active pet's ``PetDefinition`` from the app bundle.
    static func loadActiveDefinition() -> PetDefinition? {
        PetDefinition.loadBundled(id: activePetID)
    }
}

// MARK: - Menubar toggle control

/// Drop-in control for the menubar popover's footer `actionBar`
/// (`MenuBarPopoverView.swift`). The integrator adds a single line:
///
/// ```swift
/// PetCompanionToggleButton()
/// ```
///
/// next to the existing Dashboard / Settings / Quit buttons. It flips the
/// persisted enable flag and shows/hides the floating pet, leaving the existing
/// window flow alone. Styling uses the same `DesignSystem` tokens as the rest of
/// the popover so it reads as native chrome.
struct PetCompanionToggleButton: View {
    @AppStorage(PetCompanionFeature.DefaultsKey.enabled)
    private var enabled = false

    var body: some View {
        Button {
            PetCompanionFeature.toggleCompanion()
        } label: {
            Label(enabled ? "Hide Pet" : "Show Pet",
                  systemImage: enabled ? "pawprint.fill" : "pawprint")
                .font(DesignSystem.Typography.caption)
        }
        .help(enabled ? "Hide the desktop companion" : "Show the desktop companion")
        .accessibilityLabel("Desktop pet companion")
        .accessibilityValue(enabled ? "shown" : "hidden")
    }
}
