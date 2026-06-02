import XCTest
import FirebaseCore
@testable import OpenBurnBarMobile

@MainActor
final class ConversationCockpitAuthTests: XCTestCase {
    func testLiveAuthGateDoesNotTouchFirebaseAuthWhenFirebaseIsUnavailable() async throws {
        guard FirebaseApp.app() == nil else {
            throw XCTSkip("Firebase is configured in this test process.")
        }

        XCTAssertNil(CloudConversationAuthGate.live.currentUID())
        let prepared = await CloudConversationAuthGate.live.prepareForCallable()
        let refreshed = await CloudConversationAuthGate.live.refreshForCallable()
        XCTAssertFalse(prepared)
        XCTAssertFalse(refreshed)
    }

    func testRunQueryDoesNotCallCloudWhenAuthTokenIsUnavailable() async {
        let queryClient = FakeConversationQueryClient(results: [.success(.empty)])
        let store = ConversationCockpitStore(
            queryClient: queryClient,
            vault: NoopCloudConversationVaultGateway(),
            authGate: CloudConversationAuthGate(
                currentUID: { "uid-1" },
                prepareIDToken: { _ in false }
            )
        )

        await store.runQuery(reset: true)

        XCTAssertTrue(queryClient.requests.isEmpty)
        XCTAssertEqual(store.error, "Sign in to load cloud conversations.")
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testRunQueryRefreshesTokenAndRetriesUnauthenticatedOnce() async {
        let queryClient = FakeConversationQueryClient(results: [
            .failure(FakeLocalizedError("Unauthenticated")),
            .success(.empty)
        ])
        var tokenRefreshFlags: [Bool] = []
        let store = ConversationCockpitStore(
            queryClient: queryClient,
            vault: NoopCloudConversationVaultGateway(),
            authGate: CloudConversationAuthGate(
                currentUID: { "uid-1" },
                prepareIDToken: { forcingRefresh in
                    tokenRefreshFlags.append(forcingRefresh)
                    return true
                }
            )
        )

        await store.runQuery(reset: true)

        XCTAssertEqual(queryClient.requests.count, 2)
        XCTAssertEqual(tokenRefreshFlags, [false, true])
        XCTAssertNil(store.error)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.hasLoadedOnce)
    }

    func testRunQueryKeepsDebugAppCheckHintWhenUnauthenticatedPersists() async {
        let queryClient = FakeConversationQueryClient(results: [
            .failure(FakeLocalizedError("Unauthenticated")),
            .failure(FakeLocalizedError("Unauthenticated"))
        ])
        let store = ConversationCockpitStore(
            queryClient: queryClient,
            vault: NoopCloudConversationVaultGateway(),
            authGate: CloudConversationAuthGate(
                currentUID: { "uid-1" },
                prepareIDToken: { _ in true }
            )
        )

        await store.runQuery(reset: true)

        XCTAssertEqual(queryClient.requests.count, 2)
        #if DEBUG
        XCTAssertEqual(store.error, "Sign in again, or reinstall this debug build with a registered App Check token.")
        #else
        XCTAssertEqual(store.error, "Sign in again to load cloud conversations.")
        #endif
        XCTAssertTrue(store.rows.isEmpty)
    }
}

@MainActor
private struct NoopCloudConversationVaultGateway: CloudConversationVaultGateway {
    func unlockKey() async throws -> Data? {
        nil
    }

    func downloadBody(storagePath: String, bodyHash: String, vaultKey: Data) async throws -> String {
        throw FakeLocalizedError("Unexpected transcript download in auth test.")
    }
}

private struct FakeLocalizedError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

@MainActor
private final class FakeConversationQueryClient: ConversationQueryClient {
    struct Request: Equatable {
        let limit: Int
        let cursorDocId: String?
        let includeAggregates: Bool
    }

    private var results: [Result<ConversationQueryResponse, Error>]
    private(set) var requests: [Request] = []

    init(results: [Result<ConversationQueryResponse, Error>]) {
        self.results = results
    }

    func queryConversations(
        providers: [String],
        models: [String],
        projectName: String?,
        deviceId: String?,
        sourceType: String?,
        dateFrom: Date?,
        dateTo: Date?,
        sort: String,
        direction: String,
        limit: Int,
        cursorDocId: String?,
        includeAggregates: Bool
    ) async throws -> ConversationQueryResponse {
        requests.append(Request(limit: limit, cursorDocId: cursorDocId, includeAggregates: includeAggregates))
        guard !results.isEmpty else { return .empty }
        return try results.removeFirst().get()
    }
}

private extension ConversationQueryResponse {
    static let empty = ConversationQueryResponse(
        rows: [],
        nextCursor: nil,
        sort: nil,
        direction: nil,
        aggregates: nil
    )
}
