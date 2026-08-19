import Foundation
import Observation

/// Settings-facing Local D box state. Network I/O only runs when the feature flag is on.
@MainActor
@Observable
final class GrokDBoxModel {
    private let defaults: UserDefaults
    private let makeClient: () throws -> GrokDHostClient

    var health: GrokDBoxHealth = .cannotList
    var agents: [GrokDAgentRecord] = []
    var selectedAgentID: String?
    var promptText: String = ""
    var lastMessage: String = ""
    var guiWarning: String?
    var isRefreshing: Bool = false
    var isSending: Bool = false

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: GrokDFeature.DefaultsKey.enabled) }
    }

    var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: GrokDFeature.DefaultsKey.autoStart) }
    }

    var title: String { GrokDFeature.boxTitle(liveCount: agents.count) }

    var canSend: Bool {
        enabled
            && health.allowsSend
            && GrokDHostClient.isAgentUUID(selectedAgentID ?? "")
            && !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSending
            && !(selectedAgent?.isBusy ?? false)
    }

    var selectedAgent: GrokDAgentRecord? {
        agents.first { $0.id == selectedAgentID }
    }

    init(
        defaults: UserDefaults = .standard,
        makeClient: @escaping () throws -> GrokDHostClient = {
            GrokDHostClient(config: try GrokDHostConfig.load())
        }
    ) {
        self.defaults = defaults
        self.makeClient = makeClient
        self.enabled = defaults.bool(forKey: GrokDFeature.DefaultsKey.enabled)
        self.autoStart = defaults.bool(forKey: GrokDFeature.DefaultsKey.autoStart)
    }

    func refresh() async {
        guard enabled else {
            agents = []
            health = .cannotList
            lastMessage = "Local D box is off."
            return
        }
        if autoStart {
            _ = GrokDFeature.startLocalBoxIfNeeded(defaults: defaults)
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let client = try makeClient()
            guiWarning = client.config.guiIsLocalProfile
                ? nil
                : "D’s GUI is not on a local profile. This pane is the Local D box, not the Cursor seat."
            health = await client.health()
            if health == .cannotList && !client.portProbe.isListening(host: client.config.loopbackHost, port: client.config.shimPort) {
                agents = []
                lastMessage = health.userMessage
                return
            }
            agents = try await client.listAgents()
            if selectedAgentID == nil || !agents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = agents.first(where: { !$0.isBusy })?.id ?? agents.first?.id
            }
            lastMessage = health.userMessage
        } catch {
            health = .cannotList
            agents = []
            lastMessage = (error as? GrokDHostError)?.userMessage ?? "Local D box refresh failed."
        }
    }

    func send() async {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agentID = selectedAgentID, canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            let client = try makeClient()
            _ = try await client.sendPrompt(agentID: agentID, prompt: text)
            promptText = ""
            lastMessage = "Sent to \(agentID). Waiting for the box to run the turn."
            await refresh()
        } catch {
            lastMessage = (error as? GrokDHostError)?.userMessage ?? "Send failed."
        }
    }
}
