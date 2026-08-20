import Foundation
import XCTest
import OpenBurnBarKernel
import OpenBurnBarLogParsers

/// Live fleet-panel watch policy derived from the ingestion catalog.
///
/// The panel's "wrote Ns ago" line is only honest when the file that changed
/// belongs to that provider. These tests pin the two failure modes Alberto
/// hit: MiMo inheriting Codex's `~/.codex` mtimes, and MiniMax / Z.ai
/// inheriting Factory's session jsonl.
final class AgentProviderLogDiscoveryLiveWatchTests: XCTestCase {

    private let home: [String: String] = ["HOME": "/tmp/obb-live-watch-home"]

    // MARK: - Candidates

    func test_apiBackedProvidersAreNotLiveWatchCandidates() {
        for provider: AgentProvider in [.mimo, .openAI, .deepSeek, .openBurnBar] {
            XCTAssertFalse(
                AgentProviderLogDiscovery.isLiveWatchCandidate(provider),
                "\(provider.rawValue) has no local session files of its own"
            )
            XCTAssertFalse(
                AgentProviderLogDiscovery.shouldArmLiveWatch(for: provider, environment: home)
            )
        }
    }

    func test_modelFilterPiggybacksAreNotLiveWatchCandidates() {
        XCTAssertFalse(AgentProviderLogDiscovery.isLiveWatchCandidate(.minimax))
        XCTAssertFalse(AgentProviderLogDiscovery.isLiveWatchCandidate(.zai))
        XCTAssertFalse(AgentProviderLogDiscovery.shouldArmLiveWatch(for: .minimax, environment: home))
        XCTAssertFalse(AgentProviderLogDiscovery.shouldArmLiveWatch(for: .zai, environment: home))
    }

    func test_nativeSessionOwnersAreLiveWatchCandidates() {
        for provider: AgentProvider in [.factory, .claudeCode, .codex, .openCode] {
            XCTAssertTrue(
                AgentProviderLogDiscovery.isLiveWatchCandidate(provider),
                "\(provider.rawValue) owns a local session tree"
            )
            XCTAssertTrue(
                AgentProviderLogDiscovery.shouldArmLiveWatch(for: provider, environment: home)
            )
        }
    }

    // MARK: - Shared trees

    func test_factoryOwnsTheSharedSessionTree() {
        XCTAssertTrue(AgentProviderLogDiscovery.shouldArmLiveWatch(for: .factory, environment: home))

        let session = "/tmp/obb-live-watch-home/.factory/sessions/abc.jsonl"
        XCTAssertTrue(
            AgentProviderLogDiscovery.admitsLiveWrite(
                provider: .factory,
                path: session,
                environment: home
            )
        )
        XCTAssertFalse(
            AgentProviderLogDiscovery.admitsLiveWrite(
                provider: .minimax,
                path: session,
                environment: home
            ),
            "A Factory jsonl write is not MiniMax activity"
        )
        XCTAssertFalse(
            AgentProviderLogDiscovery.admitsLiveWrite(
                provider: .zai,
                path: session,
                environment: home
            ),
            "A Factory jsonl write is not Z.ai activity"
        )
    }

    func test_mimoDoesNotInheritCodexWrites() {
        let session = "/tmp/obb-live-watch-home/.codex/sessions/rollout.jsonl"
        let auth = "/tmp/obb-live-watch-home/.codex/auth.json"

        XCTAssertTrue(
            AgentProviderLogDiscovery.admitsLiveWrite(
                provider: .codex,
                path: session,
                environment: home
            )
        )
        XCTAssertFalse(
            AgentProviderLogDiscovery.admitsLiveWrite(
                provider: .codex,
                path: auth,
                environment: home
            ),
            "Codex auth.json is not a session write"
        )
        for provider: AgentProvider in [.mimo, .openAI, .deepSeek, .openBurnBar] {
            XCTAssertFalse(
                AgentProviderLogDiscovery.admitsLiveWrite(
                    provider: provider,
                    path: session,
                    environment: home
                ),
                "\(provider.rawValue) must not inherit Codex session mtimes"
            )
            XCTAssertFalse(
                AgentProviderLogDiscovery.admitsLiveWrite(
                    provider: provider,
                    path: auth,
                    environment: home
                )
            )
        }
    }

    // MARK: - Globs

    func test_filePatternMatchesCatalogGlobsAndRejectsSentinels() {
        XCTAssertTrue(AgentProviderLogDiscovery.filePatternMatches("a/b/session.jsonl", pattern: "*.jsonl"))
        XCTAssertFalse(AgentProviderLogDiscovery.filePatternMatches("a/b/session.lock", pattern: "*.jsonl"))
        XCTAssertTrue(AgentProviderLogDiscovery.filePatternMatches("/x/opencode.db", pattern: "opencode.db"))
        XCTAssertFalse(AgentProviderLogDiscovery.filePatternMatches("/x/cache.db", pattern: "opencode.db"))
        XCTAssertTrue(AgentProviderLogDiscovery.filePatternMatches("warp_network-1.log", pattern: "warp_network*.log"))
        XCTAssertFalse(
            AgentProviderLogDiscovery.filePatternMatches("anything.jsonl", pattern: "mimo-no-local-logs")
        )
        XCTAssertFalse(
            AgentProviderLogDiscovery.filePatternMatches("openai-no-local-logs", pattern: "openai-no-local-logs")
        )
    }

    func test_directoryEventsAreNeverWrites() {
        XCTAssertFalse(
            AgentProviderLogDiscovery.admitsLiveWrite(
                provider: .factory,
                path: "/tmp/obb-live-watch-home/.factory/sessions",
                isDirectory: true,
                environment: home
            )
        )
    }

    func test_sentinelPatternsAreDocumentedOnEveryApiBackedProvider() {
        for provider: AgentProvider in [.mimo, .openAI, .deepSeek, .openBurnBar] {
            let pattern = AgentProviderLogDiscovery.filePattern(for: provider)
            XCTAssertTrue(
                pattern.contains("no-local-logs"),
                "\(provider.rawValue) must keep a non-matching sentinel pattern, got \(pattern)"
            )
            XCTAssertFalse(
                AgentProviderLogDiscovery.filePatternMatches("session.jsonl", pattern: pattern)
            )
        }
    }
}
