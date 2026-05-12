import StoreKitTest
import XCTest
@testable import OpenBurnBarMobile

private let hostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"

@MainActor
final class HostedQuotaSubscriptionStoreTests: XCTestCase {
    func testLoadReadsHostedQuotaProductFromStoreKitConfiguration() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        let store = HostedQuotaSubscriptionStore(functions: service)

        await store.load()

        XCTAssertNil(store.error)
        XCTAssertEqual(store.product?.id, HostedQuotaSubscriptionStore.productID)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(service.restoreRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testPurchaseMintsBindingAndTrustsServerEntitlementResponse() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            verifyResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        var didFinishTransaction = false
        let store = HostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { _, _ in
                .success(
                    signedTransactionJWS: "signed-transaction-jws",
                    finish: { didFinishTransaction = true }
                )
            }
        )
        await store.load()

        await store.purchase()

        XCTAssertNil(store.error)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(service.bindingRequests.count, 1)
        XCTAssertEqual(service.bindingRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
        XCTAssertEqual(service.bindingRequests.first?.clientPlatform, "ios")
        XCTAssertEqual(service.verifyRequests.count, 1)
        XCTAssertEqual(service.verifyRequests.first?.signedTransactionJWS, "signed-transaction-jws")
        XCTAssertEqual(service.verifyRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testRefreshFallsBackToServerEntitlementWhenNoLocalTransactionExists() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        let store = HostedQuotaSubscriptionStore(functions: service)

        try await store.refreshEntitlement()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertNil(service.restoreRequests.first?.signedTransactionJWS)
    }

    func testRestoreFallsBackToServerWhenStoreKitHasNoCurrentEntitlement() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        var didSyncAppStore = false
        let store = HostedQuotaSubscriptionStore(
            functions: service,
            syncAppStore: { didSyncAppStore = true }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(service.restoreRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    private func makeCleanStoreKitSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "OpenBurnBarHostedQuota")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }
}

@MainActor
private final class FakeHostedQuotaEntitlementService: HostedQuotaEntitlementServicing {
    struct BindingRequest: Equatable {
        let productID: String
        let clientPlatform: String?
    }

    struct VerifyRequest: Equatable {
        let signedTransactionJWS: String
        let signedRenewalInfoJWS: String?
        let productID: String?
    }

    struct RestoreRequest: Equatable {
        let productID: String?
        let signedTransactionJWS: String?
    }

    private let bindingToken: String
    private let verifyResponse: HostedQuotaEntitlementResponse
    private let restoreResponse: HostedQuotaEntitlementResponse

    private(set) var bindingRequests: [BindingRequest] = []
    private(set) var verifyRequests: [VerifyRequest] = []
    private(set) var restoreRequests: [RestoreRequest] = []

    init(
        bindingToken: String = "00000000-0000-4000-8000-000000000001",
        verifyResponse: HostedQuotaEntitlementResponse = .hostedQuota(active: false),
        restoreResponse: HostedQuotaEntitlementResponse = .hostedQuota(active: false)
    ) {
        self.bindingToken = bindingToken
        self.verifyResponse = verifyResponse
        self.restoreResponse = restoreResponse
    }

    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String?
    ) async throws -> String {
        bindingRequests.append(BindingRequest(productID: productID, clientPlatform: clientPlatform))
        return bindingToken
    }

    func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        signedRenewalInfoJWS: String?,
        productID: String?
    ) async throws -> HostedQuotaEntitlementResponse {
        verifyRequests.append(
            VerifyRequest(
                signedTransactionJWS: signedTransactionJWS,
                signedRenewalInfoJWS: signedRenewalInfoJWS,
                productID: productID
            )
        )
        return verifyResponse
    }

    func restoreHostedQuotaEntitlement(
        productID: String?,
        signedTransactionJWS: String?
    ) async throws -> HostedQuotaEntitlementResponse {
        restoreRequests.append(
            RestoreRequest(
                productID: productID,
                signedTransactionJWS: signedTransactionJWS
            )
        )
        return restoreResponse
    }
}

private extension HostedQuotaEntitlementResponse {
    static func hostedQuota(active: Bool, expiresAt: Date? = nil) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: hostedQuotaProductID,
            transactionID: active ? "test-transaction" : nil,
            originalTransactionID: active ? "test-original-transaction" : nil,
            environment: "Xcode",
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }
}
