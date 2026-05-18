import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant Model Lens
//
// Read-only view over the *current* model each harness is using, unified
// across the two live-discovery harnesses (Hermes / Pi) and the three CLI
// harnesses with a static preference catalog (Codex / Claude Code /
// OpenClaw). Callers ask "what is harness X running right now?" and get a
// `ModelSnapshot` back — display name, provider for icon lookup, and an
// origin tag for honest UI copy.

@MainActor
struct AssistantModelLens {
    let hermesService: HermesService
    let piService: PiService
    let cliReader: CLIAgentChatReader

    init(hermesService: HermesService,
         piService: PiService,
         cliReader: CLIAgentChatReader = .shared) {
        self.hermesService = hermesService
        self.piService = piService
        self.cliReader = cliReader
    }

    struct ModelSnapshot {
        enum Origin {
            /// Hermes/Pi advertise the model live over the relay.
            case live
            /// Stored user preference for a CLI harness — applies on the
            /// next chat the Mac runs.
            case preference
            /// Last value the Mac actually ran on for this harness. Used
            /// as a "currently using" hint when no preference is set.
            case lastSession
            /// Default catalog entry — no signal from any source.
            case fallback
        }

        let displayName: String
        let provider: AgentProvider
        let origin: Origin
        /// When non-nil this is the actual `modelID` the user has stored as
        /// their preference (for CLI harnesses) or has selected live (for
        /// Hermes/Pi). Drives the picker's "currently selected" highlight.
        let activeModelID: String?
    }

    func snapshot(for runtime: AssistantRuntimeID) -> ModelSnapshot {
        switch runtime {
        case .hermes:
            return hermesSnapshot()
        case .pi:
            return piSnapshot()
        case .codex, .claude, .openClaw:
            return cliSnapshot(for: runtime)
        }
    }

    // MARK: Hermes

    private func hermesSnapshot() -> ModelSnapshot {
        if let option = hermesService.selectedModelOption {
            return ModelSnapshot(
                displayName: option.displayName,
                provider: option.agentProvider,
                origin: .live,
                activeModelID: option.modelID
            )
        }
        let raw = hermesService.selectedModelID
            ?? hermesService.selectedConnection.advertisedModel
            ?? "hermes"
        return ModelSnapshot(
            displayName: hermesService.selectedModelID
                ?? hermesService.selectedConnection.advertisedModel
                ?? "Automatic",
            provider: hermesAgentProvider(for: raw),
            origin: hermesService.selectedModelID == nil ? .fallback : .live,
            activeModelID: hermesService.selectedModelID
        )
    }

    // MARK: Pi

    private func piSnapshot() -> ModelSnapshot {
        if let option = piService.selectedModelOption {
            return ModelSnapshot(
                displayName: option.displayName,
                provider: option.agentProvider,
                origin: .live,
                activeModelID: option.modelID
            )
        }
        let raw = piService.selectedModelID
            ?? piService.selectedConnection.advertisedModel
            ?? "pi"
        return ModelSnapshot(
            displayName: piService.selectedModelID
                ?? piService.selectedConnection.advertisedModel
                ?? "Automatic",
            provider: hermesAgentProvider(for: raw),
            origin: piService.selectedModelID == nil ? .fallback : .live,
            activeModelID: piService.selectedModelID
        )
    }

    // MARK: CLI runtimes

    private func cliSnapshot(for runtime: AssistantRuntimeID) -> ModelSnapshot {
        // OpenClaw has its own discovery service now — prefer the live
        // relay when it's reported a selected model.
        if runtime == .openClaw,
           let option = OpenClawService.shared.selectedModelOption {
            return ModelSnapshot(
                displayName: option.displayName,
                provider: option.agentProvider,
                origin: .live,
                activeModelID: option.modelID
            )
        }
        if let preferred = CLIAgentModelPreferences.preferredOption(for: runtime),
           CLIAgentModelPreferences.preferredModelID(for: runtime) != nil {
            return ModelSnapshot(
                displayName: preferred.displayName,
                provider: hermesAgentProvider(for: preferred.providerID + " " + preferred.modelID),
                origin: .preference,
                activeModelID: preferred.modelID
            )
        }
        if let cliRuntime = CLIAgentRuntime(assistant: runtime),
           let recent = cliReader.sessions(for: cliRuntime).first,
           let modelName = recent.modelName, !modelName.isEmpty {
            return ModelSnapshot(
                displayName: modelName,
                provider: hermesAgentProvider(for: modelName),
                origin: .lastSession,
                activeModelID: nil
            )
        }
        if let fallback = AssistantModelCatalog.defaultOption(for: runtime) {
            return ModelSnapshot(
                displayName: fallback.displayName,
                provider: hermesAgentProvider(for: fallback.providerID + " " + fallback.modelID),
                origin: .fallback,
                activeModelID: nil
            )
        }
        return ModelSnapshot(
            displayName: "—",
            provider: hermesAgentProvider(for: runtime.rawValue),
            origin: .fallback,
            activeModelID: nil
        )
    }
}

// MARK: - Pi parity helper

extension PiService {
    /// Resolved `HermesRuntimeModelOption` matching `selectedModelID`, or
    /// nil if no advertised option matches. Mirrors `HermesService`.
    var selectedModelOption: HermesRuntimeModelOption? {
        guard let selectedModelID else { return nil }
        let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(
            selectedModelID,
            in: modelOptions
        ) ?? selectedModelID
        return modelOptions.first { $0.modelID == resolved }
    }
}

// MARK: - AssistantModelOption ↔ HermesRuntimeModelOption bridge

extension AssistantModelOption {
    /// Adapter so the static catalog can flow through code paths that
    /// already accept `HermesRuntimeModelOption`.
    var asHermesRuntimeModelOption: HermesRuntimeModelOption {
        HermesRuntimeModelOption(
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            displayName: displayName
        )
    }
}

extension HermesRuntimeModelOption {
    var asAssistantModelOption: AssistantModelOption {
        AssistantModelOption(
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            displayName: displayName
        )
    }
}
