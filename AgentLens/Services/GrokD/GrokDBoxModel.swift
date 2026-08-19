import Foundation
import Observation

/// Settings-facing Local D box state. Network I/O only runs when the feature flag is on.
@MainActor
@Observable
final class GrokDBoxModel {
    private let defaults: UserDefaults
    private let makeClient: () throws -> GrokDHostClient
    private let startBox: () async -> Bool

    var health: GrokDBoxHealth = .cannotList
    var agents: [GrokDAgentRecord] = []
    var selectedAgentID: String?
    var promptText: String = ""
    var lastMessage: String = ""
    var statusTone: GrokDStatusTone = .info
    var guiWarning: String?
    var isRefreshing: Bool = false
    var isSending: Bool = false
    var followMaxPolls: Int = 30
    var followPollNanoseconds: UInt64 = 1_000_000_000

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

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var busyPollTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        makeClient: @escaping () throws -> GrokDHostClient = {
            GrokDHostClient(config: try GrokDHostConfig.load())
        },
        startBox: @escaping () async -> Bool = {
            await GrokDFeature.startLocalBoxIfNeeded()
        }
    ) {
        self.defaults = defaults
        self.makeClient = makeClient
        self.startBox = startBox
        self.enabled = defaults.bool(forKey: GrokDFeature.DefaultsKey.enabled)
        self.autoStart = defaults.bool(forKey: GrokDFeature.DefaultsKey.autoStart)
    }

    func refresh(preservingStatus: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let preservedMessage = lastMessage
        let preservedTone = statusTone
        guard enabled else {
            busyPollTask?.cancel()
            agents = []
            health = .cannotList
            lastMessage = "Local D box is off."
            statusTone = .info
            return
        }
        if autoStart {
            _ = await startBox()
            guard generation == refreshGeneration else { return }
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let client = try makeClient()
            guiWarning = client.config.guiIsLocalProfile
                ? nil
                : "D’s GUI is not on a local profile. This pane is the Local D box, not the Cursor seat."
            health = await client.health()
            guard generation == refreshGeneration else { return }
            if health == .cannotList && !client.portProbe.isListening(host: client.config.loopbackHost, port: client.config.shimPort) {
                agents = []
                if !preservingStatus {
                    lastMessage = health.userMessage
                    statusTone = .error
                }
                return
            }
            agents = try await client.listAgents()
            guard generation == refreshGeneration else { return }
            if selectedAgentID == nil || !agents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = agents.first(where: { !$0.isBusy })?.id ?? agents.first?.id
            }
            if preservingStatus {
                lastMessage = preservedMessage
                statusTone = preservedTone
            } else {
                lastMessage = health.userMessage
                statusTone = health.allowsSend ? .success : .warning
            }
        } catch {
            guard generation == refreshGeneration else { return }
            health = .cannotList
            agents = []
            lastMessage = (error as? GrokDHostError)?.userMessage ?? "Local D box refresh failed."
            statusTone = .error
        }
    }

    func send() async {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agentID = selectedAgentID, canSend else { return }
        isSending = true
        defer { isSending = false }
        do {
            let client = try makeClient()
            let baseline = selectedAgent?.lastMessagePreview
            _ = try await client.sendPrompt(agentID: agentID, prompt: text)
            promptText = ""
            lastMessage = "Sent. Waiting for the box to run the turn…"
            statusTone = .info
            let result = await client.followTurn(
                agentID: agentID,
                prompt: text,
                baselinePreview: baseline,
                maxPolls: followMaxPolls,
                pollNanoseconds: followPollNanoseconds
            )
            lastMessage = result.userMessage
            statusTone = result.tone
            await refresh(preservingStatus: true)
            if selectedAgent?.isBusy == true {
                startBusyPoll()
            }
        } catch {
            lastMessage = (error as? GrokDHostError)?.userMessage ?? "Send failed."
            statusTone = .error
        }
    }

    private func startBusyPoll() {
        busyPollTask?.cancel()
        busyPollTask = Task { [weak self] in
            for _ in 0..<30 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.refresh(preservingStatus: true)
                if self.selectedAgent?.isBusy != true { return }
            }
        }
    }
}
