import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Thread Inbox Store (Hermes Square §6.2)
//
// Aggregator that merges every thread + mission + subscription post into
// a single sorted feed for the Living Inbox. Reads from existing
// authoritative stores; does not own conversation state.
//
// Sources:
//   • `MobileChatHistoryStore` (native mobile chat threads, including
//     Hermes, Pi, Codex, Claude, and OpenClaw)
//   • `CLIAgentChatReader` (Mac-mirrored CLI sessions from Firestore)
//   • `MobileMissionConsoleHost` (active missions awaiting attention)
//   • `SubscriptionInboxPost` (planned for Phase B/C)
//
// `refresh()` is idempotent. The view rebinds whenever `items` changes.

@MainActor
@Observable
final class ThreadInboxStore {
    private(set) var items: [ThreadInboxItem] = []
    private(set) var lastRefreshedAt: Date?
    private(set) var refreshError: String?
    private(set) var isLoading: Bool = false

    private weak var historyStore: MobileChatHistoryStore?
    private weak var cliReader: CLIAgentChatReader?
    private weak var missionHost: MobileMissionConsoleHost?

    init(
        historyStore: MobileChatHistoryStore? = nil,
        cliReader: CLIAgentChatReader? = .shared,
        missionHost: MobileMissionConsoleHost? = nil
    ) {
        self.historyStore = historyStore
        self.cliReader = cliReader
        self.missionHost = missionHost
    }

    func bind(historyStore: MobileChatHistoryStore? = nil, missionHost: MobileMissionConsoleHost? = nil) {
        if let historyStore { self.historyStore = historyStore }
        if let missionHost  { self.missionHost = missionHost }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        refreshError = nil
        defer { isLoading = false }

        var merged: [ThreadInboxItem] = []

        var mobileCLIThreadIDs = Set<String>()
        if let history = historyStore {
            merged.append(contentsOf: itemsFromHistory(history))
            mobileCLIThreadIDs = Set(history.threads.compactMap { thread in
                guard Self.cliRuntime(from: thread.runtime) != nil else { return nil }
                return thread.id
            })
        }
        if let cli = cliReader {
            // Make sure we have a recent snapshot — refresh is cheap and
            // idempotent. Cooperative with the Firestore listener already
            // running inside the reader.
            await cli.refresh()
            merged.append(contentsOf: itemsFromCLIReader(cli, excludingThreadIDs: mobileCLIThreadIDs))
        }
        if let host = missionHost {
            merged.append(contentsOf: itemsFromMissionHost(host))
        }

        items = merged.sortedForInbox()
        lastRefreshedAt = Date()
    }

    // MARK: - Builders

    private func itemsFromHistory(_ history: MobileChatHistoryStore) -> [ThreadInboxItem] {
        // `MobileChatHistoryStore.threads` is the source of truth for native
        // mobile assistant sessions. We project each into a thread inbox item
        // using the same shape regardless of whether execution is on-device or
        // Mac-backed.
        history.threads.compactMap { thread -> ThreadInboxItem? in
            let agentURI: String
            let source: ThreadInboxItem.Source
            switch thread.runtime.lowercased() {
            case "hermes":
                agentURI = AgentIdentity.builtInURI(.hermes)
                source = .hermes
            case "pi":
                agentURI = AgentIdentity.builtInURI(.pi)
                source = .pi
            case "codex", "claude", "openclaw":
                guard let runtime = Self.cliRuntime(from: thread.runtime) else { return nil }
                agentURI = AgentIdentity.builtInURI(runtime)
                source = .cliMirror
            default:
                return nil
            }
            return ThreadInboxItem(
                id: "\(source.rawValue):\(thread.id)",
                agentURI: agentURI,
                title: thread.title.isEmpty ? "(untitled)" : thread.title,
                preview: thread.preview,
                lastActivityAt: thread.updatedAt,
                unreadCount: 0,
                needsAttention: false,
                source: source,
                liveMissionID: nil,
                attachments: thread.recentAttachmentPreviews
            )
        }
    }

    private func itemsFromCLIReader(_ reader: CLIAgentChatReader, excludingThreadIDs excludedIDs: Set<String> = []) -> [ThreadInboxItem] {
        reader.sessions.compactMap { record -> ThreadInboxItem? in
            guard !excludedIDs.contains(record.id) else { return nil }
            let runtime: AssistantRuntimeID
            switch record.agent {
            case .claude:   runtime = .claude
            case .codex:    runtime = .codex
            case .openClaw: runtime = .openClaw
            }
            return ThreadInboxItem(
                id: "cli:\(record.id)",
                agentURI: AgentIdentity.builtInURI(runtime),
                title: record.title.isEmpty ? "(no title)" : record.title,
                preview: record.preview,
                lastActivityAt: record.updatedAt,
                unreadCount: 0,
                needsAttention: false,
                source: .cliMirror,
                liveMissionID: nil,
                searchText: [
                    record.title,
                    record.preview,
                    record.agent.displayName,
                    record.modelName ?? "",
                    record.workspaceLabel ?? "",
                    record.messages.map { message in
                        [
                            message.role.rawValue,
                            message.text,
                            message.toolUses.map { "\($0.name) \($0.status) \($0.detail ?? "")" }
                                .joined(separator: " ")
                        ].joined(separator: " ")
                    }.joined(separator: " ")
                ].joined(separator: " ")
            )
        }
    }

    private static func cliRuntime(from rawRuntime: String) -> AssistantRuntimeID? {
        switch rawRuntime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex": return .codex
        case "claude": return .claude
        case "openclaw": return .openClaw
        default: return nil
        }
    }

    private func itemsFromMissionHost(_ host: MobileMissionConsoleHost) -> [ThreadInboxItem] {
        host.snapshot.activeTiles.map { tile -> ThreadInboxItem in
            let runtimeID = tile.runtimeID
                .flatMap(AssistantRuntimeID.init(rawValue:))
            let agentURI = runtimeID.map(AgentIdentity.builtInURI) ?? "agent://burnbar/auto"
            return ThreadInboxItem(
                id: "mission:\(tile.id)",
                agentURI: agentURI,
                title: tile.title,
                preview: tile.phaseDetail ?? tile.phase.displayLabel,
                lastActivityAt: tile.startedAt ?? Date(),
                unreadCount: tile.approvalPending ? 1 : 0,
                needsAttention: tile.approvalPending || tile.phase.isProblem,
                source: .missionGroup,
                liveMissionID: tile.id
            )
        }
    }
}
