import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonMembershipRPCTests: XCTestCase {
    private let proProductID = "com.openburnbar.pro.monthly"
    private let hostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"

    func testMembershipRPCMethodStringsMatchLinuxShellWire() throws {
        XCTAssertEqual(BurnBarRPCMethod.membershipStatus.rawValue, "daemon.membership.status")
        XCTAssertEqual(BurnBarRPCMethod.membershipCheckoutURL.rawValue, "daemon.membership.checkoutUrl")
        XCTAssertEqual(BurnBarRPCMethod.membershipRestore.rawValue, "daemon.membership.restore")

        let checkout = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarMembershipCheckoutURLRequest>.self,
            from: Data("""
            {
              "id": "checkout-1",
              "method": "daemon.membership.checkoutUrl",
              "params": {
                "success_url": "openburnbar://membership/success",
                "cancel_url": "openburnbar://membership/cancel"
              }
            }
            """.utf8)
        )
        XCTAssertEqual(checkout.params.successURL, "openburnbar://membership/success")
        XCTAssertEqual(checkout.params.cancelURL, "openburnbar://membership/cancel")
    }

    func testLocalCacheBackedStatusStatesSatisfyLinuxMembershipMapper() async throws {
        let cacheURL = try temporaryCacheURL()
        let service = BurnBarMembershipService(cacheURL: cacheURL, cloudClient: StubCloudClient())

        let active = snapshot(
            state: .active,
            tier: "pro",
            entitlementIds: ["burnbar_pro", "hosted_quota_sync"],
            entitlementDocs: [
                "burnbar_pro": BurnBarMembershipEntitlementDocument(
                    active: true,
                    productID: proProductID,
                    expiresAt: "2099-01-01T00:00:00Z",
                    source: "stripe_checkout"
                ),
                "hosted_quota_sync": BurnBarMembershipEntitlementDocument(
                    active: true,
                    productID: hostedQuotaProductID,
                    expiresAt: "2099-01-01T00:00:00Z",
                    source: "stripe_checkout"
                )
            ],
            renewsAt: "2099-01-01T00:00:00Z",
            restoreAvailable: true
        )
        try await service.replaceCachedSnapshot(active)
        var status = await service.status()
        XCTAssertEqual(status.membership.tier, "pro")
        XCTAssertEqual(status.membership.entitlementIds, ["burnbar_pro", "hosted_quota_sync"])
        XCTAssertEqual(status.membership.entitlementDocs["burnbar_pro"]?.productID, proProductID)
        XCTAssertEqual(status.membership.state, .active)
        XCTAssertEqual(status.membership.cacheEvent, "membership.entitlement_cache.updated")

        for state in [BurnBarMembershipState.cancelled, .paymentFailed] {
            try await service.replaceCachedSnapshot(snapshot(state: state, restoreAvailable: true))
            status = await service.status()
            XCTAssertEqual(status.membership.tier, "free")
            XCTAssertEqual(status.membership.entitlementIds, [])
            XCTAssertEqual(status.membership.state, state)
            XCTAssertTrue(status.membership.restoreAvailable)
        }

        try FileManager.default.removeItem(at: cacheURL)
        status = await service.status()
        XCTAssertEqual(status.membership.state, .offline)
        XCTAssertEqual(status.membership.tier, "free")
        XCTAssertFalse(status.membership.restoreAvailable)
        XCTAssertEqual(status.membership.error?.code, .offline)
    }

    func testCheckoutAndRestoreUseTypedErrorsWithoutNetworkOrFakeURLs() async throws {
        let unauthenticatedClient = EnvironmentBurnBarMembershipCloudClient(
            environment: ["OPENBURNBAR_MEMBERSHIP_CHECKOUT_ENDPOINT": "https://example.com/membership/checkout"]
        )
        do {
            _ = try await unauthenticatedClient.checkoutURL(BurnBarMembershipCheckoutURLRequest())
            XCTFail("checkoutURL should require a real Firebase auth token")
        } catch let error as BurnBarMembershipServiceError {
            XCTAssertEqual(error.membershipCode, .unauthenticated)
        }

        // Once a protected auth-token provider is wired, it is the sole token
        // source: an environment token must be ignored.
        let providerBackedClient = EnvironmentBurnBarMembershipCloudClient(
            environment: [
                "OPENBURNBAR_MEMBERSHIP_CHECKOUT_ENDPOINT": "https://example.com/membership/checkout",
                "OPENBURNBAR_FIREBASE_ID_TOKEN": "environment-token-must-not-be-used"
            ],
            authTokenProvider: { nil }
        )
        do {
            _ = try await providerBackedClient.checkoutURL(BurnBarMembershipCheckoutURLRequest())
            XCTFail("checkoutURL must not fall back to the environment token when a provider is wired")
        } catch let error as BurnBarMembershipServiceError {
            XCTAssertEqual(error.membershipCode, .unauthenticated)
        }

        let service = BurnBarMembershipService(
            cacheURL: try temporaryCacheURL(),
            cloudClient: StubCloudClient(restoreError: .cloudUnavailable("Firebase callable auth is unavailable in this environment."))
        )
        let restore = await service.restore()
        XCTAssertFalse(restore.ok)
        XCTAssertEqual(restore.error?.code, .cloudUnavailable)
        XCTAssertNil(restore.membership)
    }

    func testMembershipHandlerEncodesStatusCheckoutAndRestoreEnvelopes() async throws {
        let membership = snapshot(
            state: .active,
            tier: "pro",
            entitlementIds: ["burnbar_pro"],
            entitlementDocs: [
                "burnbar_pro": BurnBarMembershipEntitlementDocument(
                    active: true,
                    productID: proProductID,
                    expiresAt: "2099-01-01T00:00:00Z",
                    source: "stripe_checkout"
                )
            ],
            renewsAt: "2099-01-01T00:00:00Z",
            restoreAvailable: true
        )
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketAuthToken: "test-token", startsMissionControlBackgroundLoops: false),
            membershipService: StubMembershipService(
                statusResponse: BurnBarMembershipStatusResponse(membership: membership),
                checkoutError: .unauthenticated,
                restoreResponse: BurnBarMembershipRestoreResponse(
                    ok: false,
                    error: BurnBarMembershipServiceError.unauthenticated.errorResult
                )
            )
        )

        let statusData = try await server.handleMembershipRPC(
            method: .membershipStatus,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"status-1","method":"daemon.membership.status"}"#.utf8)
        )
        let status = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarMembershipStatusResponse>.self,
            from: statusData
        )
        XCTAssertEqual(status.result?.membership.state, .active)
        XCTAssertEqual(status.result?.membership.entitlementDocs["burnbar_pro"]?.productID, proProductID)

        let checkoutData = try await server.handleMembershipRPC(
            method: .membershipCheckoutURL,
            decoder: JSONDecoder(),
            requestData: Data("""
            {"id":"checkout-1","method":"daemon.membership.checkoutUrl","params":{"success_url":"openburnbar://membership/success","cancel_url":"openburnbar://membership/cancel"}}
            """.utf8)
        )
        let checkout = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarMembershipCheckoutURLResponse>.self,
            from: checkoutData
        )
        XCTAssertNil(checkout.result)
        XCTAssertEqual(checkout.error?.code, BurnBarRPCErrorCode.unauthorized)
        XCTAssertTrue(checkout.error?.message.contains("membership.unauthenticated") ?? false)

        let restoreData = try await server.handleMembershipRPC(
            method: .membershipRestore,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"restore-1","method":"daemon.membership.restore"}"#.utf8)
        )
        let restore = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarMembershipRestoreResponse>.self,
            from: restoreData
        )
        XCTAssertEqual(restore.result?.ok, false)
        XCTAssertEqual(restore.result?.error?.code, .unauthenticated)
    }

    private func snapshot(
        state: BurnBarMembershipState,
        tier: String = "free",
        entitlementIds: [String] = [],
        entitlementDocs: [String: BurnBarMembershipEntitlementDocument] = [:],
        renewsAt: String? = nil,
        restoreAvailable: Bool
    ) -> BurnBarMembershipSnapshot {
        BurnBarMembershipSnapshot(
            tier: tier,
            entitlementIds: entitlementIds,
            entitlementDocs: entitlementDocs,
            renewsAt: renewsAt,
            restoreAvailable: restoreAvailable,
            state: state,
            daemonCacheKey: "entitlements/\(state.rawValue)",
            source: "stripe_checkout",
            updatedAt: "2026-07-06T00:00:00Z"
        )
    }

    private func temporaryCacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-membership-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("membership-entitlement-cache.json")
    }
}

private struct StubCloudClient: BurnBarMembershipCloudClient {
    var checkoutResponse: BurnBarMembershipCheckoutURLResponse?
    var checkoutError: BurnBarMembershipServiceError?
    var restoreResponse: BurnBarMembershipSnapshot?
    var restoreError: BurnBarMembershipServiceError?

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        if let checkoutError { throw checkoutError }
        if let checkoutResponse { return checkoutResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("checkout fixture not configured")
    }

    func restore() async throws -> BurnBarMembershipSnapshot {
        if let restoreError { throw restoreError }
        if let restoreResponse { return restoreResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("restore fixture not configured")
    }
}

private struct StubMembershipService: BurnBarMembershipServing {
    var statusResponse: BurnBarMembershipStatusResponse
    var checkoutResponse: BurnBarMembershipCheckoutURLResponse?
    var checkoutError: BurnBarMembershipServiceError?
    var restoreResponse: BurnBarMembershipRestoreResponse

    func status() async -> BurnBarMembershipStatusResponse {
        statusResponse
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        if let checkoutError { throw checkoutError }
        if let checkoutResponse { return checkoutResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("checkout fixture not configured")
    }

    func restore() async -> BurnBarMembershipRestoreResponse {
        restoreResponse
    }
}
