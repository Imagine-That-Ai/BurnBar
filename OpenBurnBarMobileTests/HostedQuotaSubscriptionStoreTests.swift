import StoreKit
import StoreKitTest
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

private let hostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"
private let burnBarProProductID = "com.openburnbar.pro.monthly"

@MainActor
final class HostedQuotaSubscriptionStoreTests: XCTestCase {
    func testLoadReadsHostedQuotaProductFromStoreKitConfiguration() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        let store = HostedQuotaSubscriptionStore(functions: service, isSignedIn: { true })

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
            },
            isSignedIn: { true }
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
        let store = HostedQuotaSubscriptionStore(functions: service, isSignedIn: { true })

        try await store.refreshEntitlement()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertNil(service.restoreRequests.first?.signedTransactionJWS)
    }

    func testLoadRefreshesEntitlementWhenProductCatalogFails() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(
            restoreResponse: .hostedQuota(active: true, expiresAt: expiresAt)
        )
        let store = HostedQuotaSubscriptionStore(
            functions: service,
            fetchProducts: { _ in throw TestHostedQuotaError.productCatalogUnavailable },
            isSignedIn: { true }
        )

        await store.load()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
    }

    func testRefreshUsesBurnBarProDirectEntitlementBeforeServerReplay() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let service = FakeHostedQuotaEntitlementService(restoreError: TestHostedQuotaError.replayUnavailable)
        let directReader = FakeHostedQuotaDirectReader(
            response: .burnBarPro(active: true, expiresAt: expiresAt)
        )
        let store = HostedQuotaSubscriptionStore(
            functions: service,
            directReader: directReader,
            isSignedIn: { true }
        )

        try await store.refreshEntitlement()

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(directReader.fetchCount, 1)
        XCTAssertEqual(service.restoreRequests.count, 0)
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
            syncAppStore: { didSyncAppStore = true },
            isSignedIn: { true }
        )

        await store.restorePurchases()

        XCTAssertNil(store.error)
        XCTAssertTrue(didSyncAppStore)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.expirationDate, expiresAt)
        XCTAssertEqual(service.restoreRequests.count, 1)
        XCTAssertEqual(service.restoreRequests.first?.productID, HostedQuotaSubscriptionStore.productID)
    }

    func testSignedOutPurchaseStillPresentsStoreKitAndFinishesWithActionableRecovery() async throws {
        let session = try makeCleanStoreKitSession()
        defer { session.clearTransactions() }
        let service = FakeHostedQuotaEntitlementService()
        var didFinishTransaction = false
        var capturedOptions: Set<Product.PurchaseOption>?
        let store = HostedQuotaSubscriptionStore(
            functions: service,
            purchaseProduct: { _, options in
                capturedOptions = options
                return .success(
                    signedTransactionJWS: "signed-out-transaction-jws",
                    finish: { didFinishTransaction = true }
                )
            },
            isSignedIn: { false }
        )
        await store.load()

        await store.purchase()

        XCTAssertTrue(didFinishTransaction)
        XCTAssertEqual(capturedOptions, [])
        XCTAssertEqual(service.bindingRequests.count, 0)
        XCTAssertEqual(service.verifyRequests.count, 0)
        XCTAssertFalse(store.isActive)
        XCTAssertTrue(store.error?.contains("Sign in to OpenBurnBar") == true)
        XCTAssertFalse(store.error?.localizedCaseInsensitiveContains("Unauthenticated") == true)
    }

    private func makeCleanStoreKitSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "OpenBurnBarHostedQuota")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }
}

final class HermesMobileSetupWizardGateTests: XCTestCase {
    func testDoesNotAutoPresentWhenHermesIsAlreadyReachable() {
        let shouldPresent = HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: false,
            didAutoPresent: false,
            hasUsableSetup: true
        )

        XCTAssertFalse(shouldPresent)
    }

    func testAutoPresentsOnlyForFirstUnconfiguredVisit() {
        XCTAssertTrue(HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: false,
            didAutoPresent: false,
            hasUsableSetup: false
        ))
        XCTAssertFalse(HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: true,
            didAutoPresent: false,
            hasUsableSetup: false
        ))
        XCTAssertFalse(HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: false,
            hasCompletedSetup: false,
            didAutoPresent: true,
            hasUsableSetup: false
        ))
    }

    func testUsableSetupIncludesReachabilitySelectedRelayOrSuggestedRelay() {
        let selectedRelay = HermesConnectionRecord(
            id: "relay-selected",
            displayName: "Selected Relay",
            mode: .relayLink,
            status: .online
        )
        let suggestedRelay = HermesConnectionRecord(
            id: "relay-suggested",
            displayName: "Suggested Relay",
            mode: .relayLink,
            status: .online
        )

        XCTAssertTrue(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: true,
            selectedConnection: .localDefault,
            suggestedRelayConnection: nil
        ))
        XCTAssertTrue(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: false,
            selectedConnection: selectedRelay,
            suggestedRelayConnection: nil
        ))
        XCTAssertTrue(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: false,
            selectedConnection: .localDefault,
            suggestedRelayConnection: suggestedRelay
        ))
        XCTAssertFalse(HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: false,
            selectedConnection: .localDefault,
            suggestedRelayConnection: nil
        ))
    }
}

private enum TestHostedQuotaError: Error {
    case replayUnavailable
    case productCatalogUnavailable
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
    private let restoreError: Error?

    private(set) var bindingRequests: [BindingRequest] = []
    private(set) var verifyRequests: [VerifyRequest] = []
    private(set) var restoreRequests: [RestoreRequest] = []

    init(
        bindingToken: String = "00000000-0000-4000-8000-000000000001",
        verifyResponse: HostedQuotaEntitlementResponse = .hostedQuota(active: false),
        restoreResponse: HostedQuotaEntitlementResponse = .hostedQuota(active: false),
        restoreError: Error? = nil
    ) {
        self.bindingToken = bindingToken
        self.verifyResponse = verifyResponse
        self.restoreResponse = restoreResponse
        self.restoreError = restoreError
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
        if let restoreError {
            throw restoreError
        }
        return restoreResponse
    }
}

@MainActor
private final class FakeHostedQuotaDirectReader: HostedQuotaEntitlementDirectReading {
    private let response: HostedQuotaEntitlementResponse?
    private(set) var fetchCount = 0

    init(response: HostedQuotaEntitlementResponse?) {
        self.response = response
    }

    func fetchHostedQuotaEntitlement() async throws -> HostedQuotaEntitlementResponse? {
        fetchCount += 1
        return response
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

    static func burnBarPro(active: Bool, expiresAt: Date? = nil) -> HostedQuotaEntitlementResponse {
        HostedQuotaEntitlementResponse(
            active: active,
            productID: burnBarProProductID,
            transactionID: active ? "test-pro-transaction" : nil,
            originalTransactionID: active ? "test-pro-original-transaction" : nil,
            environment: "Xcode",
            expiresAt: expiresAt,
            revokedAt: nil,
            revocationReason: nil
        )
    }
}
