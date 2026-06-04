import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarProxyRouteLogStoreTests: XCTestCase {
    func testRecentReturnsNewestFirstAndHonorsLimit() async throws {
        let fileURL = try temporaryLogURL()
        let store = BurnBarProxyRouteLogStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "proxy-route-log-tests")
        )

        await store.append(makeEntry(id: "old", occurredAt: Date(timeIntervalSince1970: 100), model: "claude-3-opus"))
        await store.append(makeEntry(id: "new", occurredAt: Date(timeIntervalSince1970: 200), model: "glm-5-turbo"))

        let entries = try await store.recent(limit: 1)

        XCTAssertEqual(entries.map(\.id), ["new"])
        XCTAssertEqual(entries.first?.clientModelSlug, "glm-5-turbo")
        XCTAssertEqual(entries.first?.providerLogoKey, "ZAILogo")
    }

    func testClearRemovesPersistedRouteLog() async throws {
        let fileURL = try temporaryLogURL()
        let store = BurnBarProxyRouteLogStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "proxy-route-log-tests")
        )

        await store.append(makeEntry(id: "route", occurredAt: Date(), model: "deepseek-chat"))
        let beforeClear = try await store.recent(limit: 10)
        XCTAssertFalse(beforeClear.isEmpty)

        try await store.clear()

        let afterClear = try await store.recent(limit: 10)
        XCTAssertTrue(afterClear.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testMalformedLinesAreSkippedWhenLoadingPersistedLog() async throws {
        let fileURL = try temporaryLogURL()
        let encoder = JSONEncoder()
        let validEntry = makeEntry(id: "valid", occurredAt: Date(timeIntervalSince1970: 300), model: "deepseek-chat")
        let data = try encoder.encode(validEntry) + Data([0x0A]) + Data("not json\n".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)

        let store = BurnBarProxyRouteLogStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "proxy-route-log-tests")
        )

        let entries = try await store.recent(limit: 10)

        XCTAssertEqual(entries.map(\.id), ["valid"])
    }

    func testPersistedFileUsesPrivatePermissions() async throws {
        let fileURL = try temporaryLogURL()
        let store = BurnBarProxyRouteLogStore(
            fileURL: fileURL,
            logger: BurnBarDaemonLogger(category: "proxy-route-log-tests")
        )

        await store.append(makeEntry(id: "route", occurredAt: Date(), model: "glm-5-turbo"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    private func temporaryLogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-route-log-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("proxy-route-events.jsonl")
    }

    private func makeEntry(id: String, occurredAt: Date, model: String) -> BurnBarProxyRouteLogEntry {
        BurnBarProxyRouteLogEntry(
            id: id,
            occurredAt: occurredAt,
            completedAt: occurredAt.addingTimeInterval(0.1),
            durationMilliseconds: 100,
            requestPath: "/v1/chat/completions",
            endpoint: "chat.completions",
            clientModelSlug: model,
            advertisedModelSlug: model,
            routingModelSlug: model,
            upstreamModelSlug: model,
            providerReportedModelSlug: model,
            clientModelDisplayName: model,
            routingModelDisplayName: model,
            upstreamModelDisplayName: model,
            providerID: model == "glm-5-turbo" ? "zai" : "deepseek",
            providerName: model == "glm-5-turbo" ? "Z.ai" : "DeepSeek",
            providerLogoKey: model == "glm-5-turbo" ? "ZAILogo" : "DeepSeekLogo",
            accountID: "default",
            accountLabel: "Default",
            requestedCanonicalModelID: model,
            servedCanonicalModelID: model,
            formatFamily: "openai_compat",
            endpointProfileID: nil,
            transportKind: .http,
            rewriteKind: .none,
            exactModelInvariant: .passed,
            finalStatus: .exact,
            streamed: false,
            streamInterrupted: false,
            httpStatus: 200,
            attempts: [
                BurnBarProxyRouteAttempt(
                    id: "\(id)-attempt",
                    sequence: 1,
                    startedAt: occurredAt,
                    completedAt: occurredAt.addingTimeInterval(0.1),
                    durationMilliseconds: 100,
                    providerID: model == "glm-5-turbo" ? "zai" : "deepseek",
                    providerName: model == "glm-5-turbo" ? "Z.ai" : "DeepSeek",
                    providerLogoKey: model == "glm-5-turbo" ? "ZAILogo" : "DeepSeekLogo",
                    accountID: "default",
                    accountLabel: "Default",
                    routingModelSlug: model,
                    upstreamModelSlug: model,
                    canonicalModelID: model,
                    formatFamily: "openai_compat",
                    endpointProfileID: nil,
                    transportKind: .http,
                    status: .exact,
                    httpStatus: 200,
                    failureMessage: nil
                )
            ],
            usage: nil,
            failureMessage: nil
        )
    }
}
