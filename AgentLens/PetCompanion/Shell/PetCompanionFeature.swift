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
final class PetCompanionRuntime {
    let controller: PetCompanionController
    let hotkey: PetHotkey
    let systemObservers: PetSystemObservers
    let keychain = PetKeychainStore()

    init() {
        let controller = PetCompanionController()
        self.controller = controller
        self.hotkey = PetHotkey { [weak controller] in
            guard let controller else { return }
            if controller.isVisible {
                controller.handlePetClick()
            } else if UserDefaults.standard.bool(forKey: PetCompanionFeature.DefaultsKey.enabled) {
                PetCompanionFeature.showCompanion()
                controller.openBubble()
            }
        }
        self.systemObservers = PetSystemObservers()
    }
}

@MainActor
enum PetCompanionFeature {
    static let runtime = PetCompanionRuntime()

    /// UserDefaults keys the feature owns (kept in one place for the integrator).
    enum DefaultsKey {
        static let enabled = "pet.companionEnabled"
        static let activeAgent = "pet.activeAgent"
        static let activePetID = "pet.activePetID"
        /// Whether the active pet's `agent.persona` drives chat voice (cloud +
        /// local fallback). Default ON; per-app UserDefaults so it survives
        /// relaunch and is independent of the host app's own settings.
        static let personaVoiceEnabled = "pet.personaVoiceEnabled"
    }

    /// Whether the pet persona voice override is on. Default ON when never set
    /// (per-app UserDefaults), so a freshly-selected pet speaks in character
    /// until the user turns it off via the right-click menu.
    static var personaVoiceEnabled: Bool {
        if UserDefaults.standard.object(forKey: DefaultsKey.personaVoiceEnabled) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: DefaultsKey.personaVoiceEnabled)
    }

    static func setPersonaVoiceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.personaVoiceEnabled)
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
        SpriteKitPetRenderer.registerAsDefault(on: runtime.controller)
        SceneKitPetRenderer.register(on: runtime.controller)

        // Reuse the app's shared chat controller for the bubble's answering brain
        // (Ground Truth #2 — never duplicate the agent layer). Safe to pass nil
        // when the chat stack isn't built yet; the pet then runs ambient-only.
        if let chat {
            runtime.controller.attachChat(chat)
        }

        // Hardening + summon hotkey come up regardless of the enable flag so the
        // pet can be summoned the first time the user flips it on (C8/C9).
        runtime.hotkey.enable()
        runtime.systemObservers.start(controller: runtime.controller)

        guard isEnabled else { return }
        showCompanion()
    }

    /// Whether the one-window onboarding should run on this launch: only for a
    /// user who has ENABLED the companion and never finished setting it up.
    /// A fresh install must never meet the pet before their first number — the
    /// ungated version force-activated a setup window over every new user's
    /// first launch. The host presents ``PetFirstRunView`` when this is `true`
    /// (build-notes documents the `WindowManager` mirror).
    static var shouldRunFirstRun: Bool {
        isEnabled && !PetFirstRunModel.hasCompleted
    }

    /// Load the active pet's definition and start + show the companion. Falls back
    /// silently if the definition resource is missing (no crash, no error toast).
    static func showCompanion() {
        guard let definition = loadActiveDefinition() else { return }
        runtime.controller.start(with: definition)
        runtime.controller.show()
    }

    static func hideCompanion() {
        runtime.controller.hide()
    }

    /// Toggle visibility and persist the new enabled state.
    static func toggleCompanion() {
        let controller = runtime.controller
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
        if let active = PetDefinition.loadBundled(id: activePetID) {
            return active
        }
        return PetDefinition.loadBundled(id: defaultPetID)
    }

    /// Persist a picker selection and hot-swap the live companion when visible.
    static func selectPet(id: String, form: PetForm? = nil) {
        UserDefaults.standard.set(id, forKey: DefaultsKey.activePetID)
        guard let definition = PetDefinition.loadBundled(id: id) else { return }
        let controller = runtime.controller
        if controller.isRunning || controller.isVisible {
            controller.setPet(definition, form: form)
        }
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
