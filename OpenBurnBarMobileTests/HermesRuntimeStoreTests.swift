import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Covers the `HermesRuntimeStore` split (shared runtime catalog,
/// per-surface conversation state) and the cross-surface coalescing of
/// `refreshRuntime`'s 6-op fan-out: with the in-flight task living on the
/// shared store, concurrent refreshes from any surface collapse to one.
@MainActor
final class HermesRuntimeStoreTests: XCTestCase {

    // MARK: - Fakes

    /// Connection repository whose `list` suspends until the test releases
    /// it, so a second service's `refreshRuntime` deterministically lands
    /// while the first refresh is still in flight.
    @MainActor
    private final class GatedConnectionRepository: HermesConnectionListing {
        private(set) var listCallCount = 0
        private var gates: [CheckedContinuation<Void, Never>] = []
        var gated = true

        func listHermesConnections() async throws -> [HermesConnectionRecord] {
            listCallCount += 1
            if gated {
                await withCheckedContinuation { gates.append($0) }
            }
            return []
        }

        func release() {
            let pending = gates
            gates = []
            pending.forEach { $0.resume() }
        }
    }

    private final class StubSecretStore: HermesConnectionSecretStoring {
        func save(_ value: String, connectionID: String) throws {}
        func load(connectionID: String) throws -> String? { nil }
        func delete(connectionID: String) throws {}
    }

    private final class StubRelayTransport: HermesRelayTransporting {
        func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
            Data(#"{"data":[]}"#.utf8)
        }

        func sendStreaming(
            _ payload: HermesRelayPayload,
            timeout: TimeInterval,
            onSSEEvent: @escaping @MainActor (String) -> Void
        ) async throws {}
    }

    private final class StubURLProtocol: URLProtocol {
        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://127.0.0.1:8642")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":[]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    // MARK: - Harness

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "HermesRuntimeStoreTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeService(
        repository: GatedConnectionRepository,
        runtimeStore: HermesRuntimeStore?,
        defaults: UserDefaults
    ) -> HermesService {
        HermesService(
            urlSession: makeSession(),
            connectionRepository: repository,
            secretStore: StubSecretStore(),
            relayTransport: StubRelayTransport(),
            defaults: defaults,
            runtimeStore: runtimeStore
        )
    }

    // MARK: - Tests

    func testSharedRuntimeStore_catalogIsVisibleAcrossServices() {
        let defaults = makeDefaults()
        let store = HermesRuntimeStore(defaults: defaults)
        let repository = GatedConnectionRepository()
        let serviceA = makeService(repository: repository, runtimeStore: store, defaults: defaults)
        let serviceB = makeService(repository: repository, runtimeStore: store, defaults: defaults)

        serviceA.selectGatewayModelID("hermes-test-model")

        XCTAssertEqual(serviceB.selectedModelID, "hermes-test-model")
        XCTAssertEqual(store.selectedModelID, "hermes-test-model")
        XCTAssertEqual(
            defaults.string(forKey: HermesRuntimeStore.selectedModelDefaultsKey),
            "hermes-test-model"
        )
    }

    func testConversationStateStaysPerSurface() {
        let defaults = makeDefaults()
        let store = HermesRuntimeStore(defaults: defaults)
        let repository = GatedConnectionRepository()
        let serviceA = makeService(repository: repository, runtimeStore: store, defaults: defaults)
        let serviceB = makeService(repository: repository, runtimeStore: store, defaults: defaults)

        serviceA.messages = [HermesChatMessage(role: .user, text: "quick ask")]
        serviceA.selectedSessionID = "pulse-session"

        // Sharing the runtime catalog must NOT merge transcripts: the Pulse
        // quick-ask and the Hermes tab keep separate conversations.
        XCTAssertTrue(serviceB.messages.isEmpty)
        XCTAssertNil(serviceB.selectedSessionID)
    }

    func testDefaultInit_keepsIsolatedCatalogs() {
        let defaults = makeDefaults()
        let repository = GatedConnectionRepository()
        let serviceA = makeService(repository: repository, runtimeStore: nil, defaults: defaults)
        let serviceB = makeService(repository: repository, runtimeStore: nil, defaults: defaults)

        serviceA.isReachable = true

        // No injected store → historical per-instance behavior (tests,
        // previews) is preserved.
        XCTAssertFalse(serviceB.isReachable)
    }

    func testRefreshRuntime_coalescesAcrossServicesSharingOneStore() async {
        let defaults = makeDefaults()
        let store = HermesRuntimeStore(defaults: defaults)
        let repository = GatedConnectionRepository()
        let serviceA = makeService(repository: repository, runtimeStore: store, defaults: defaults)
        let serviceB = makeService(repository: repository, runtimeStore: store, defaults: defaults)

        let first = Task { await serviceA.refreshRuntime() }
        // Wait until the first refresh is provably in flight (suspended in
        // the gated repository).
        while repository.listCallCount == 0 {
            await Task.yield()
        }
        let second = Task { await serviceB.refreshRuntime() }
        // Give the second refresh time to reach the coalescing check.
        for _ in 0..<100 { await Task.yield() }

        repository.release()
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(
            repository.listCallCount, 1,
            "Concurrent refreshes across services sharing one runtime store must coalesce into one fan-out"
        )
    }

    func testRefreshRuntimeIfStale_skipsWhileCatalogIsFresh() async {
        let defaults = makeDefaults()
        let store = HermesRuntimeStore(defaults: defaults)
        let repository = GatedConnectionRepository()
        repository.gated = false
        let service = makeService(repository: repository, runtimeStore: store, defaults: defaults)

        await service.refreshRuntime()
        XCTAssertEqual(repository.listCallCount, 1)

        await service.refreshRuntimeIfStale()
        XCTAssertEqual(repository.listCallCount, 1, "Fresh catalog must skip the fan-out")

        // A second surface sharing the store is also warm.
        let other = makeService(repository: repository, runtimeStore: store, defaults: defaults)
        await other.refreshRuntimeIfStale()
        XCTAssertEqual(repository.listCallCount, 1)

        // An explicit full refresh still goes through.
        await service.refreshRuntime()
        XCTAssertEqual(repository.listCallCount, 2)
    }
}
