#if canImport(UIKit)
import Foundation
import OpenBurnBarCore

@MainActor
final class AgentFocusFollowPreferenceStore: ObservableObject {
    static let shared = AgentFocusFollowPreferenceStore()

    static let userDefaultsKey = "agentFocusFollowMode"

    @Published var mode: AgentFocusFollowMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.userDefaultsKey)
        self.mode = raw.flatMap(AgentFocusFollowMode.init(rawValue:)) ?? .smart
    }

    var wireValue: String { mode.rawValue }
}

extension AgentFocusFollowMode {
    var label: String {
        switch self {
        case .smart: return "Smart"
        case .debounced: return "Settle"
        case .immediate: return "Immediate"
        }
    }

    var settingsDescription: String {
        switch self {
        case .smart:
            return "Tracks the agent's main app and waits through quick app-switching bursts."
        case .debounced:
            return "Switches after a short 500 ms settle period."
        case .immediate:
            return "Switches the mirror as soon as the Mac focus changes."
        }
    }
}
#endif
