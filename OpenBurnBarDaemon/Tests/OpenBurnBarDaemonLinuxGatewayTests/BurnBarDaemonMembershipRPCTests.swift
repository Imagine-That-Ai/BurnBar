import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

final class BurnBarDaemonMembershipRPCTests: XCTestCase {
    private let proProductID = "com.openburnbar.pro.monthly"
    private let hostedQuotaProductID = "com.openburnbar.hostedQuotaSync.cloud.monthly"

    func testMembershipRPCMethodStringsMatchLinuxShellWire() throws {
        XCTAssertEqual(BurnBarRPCMethod.membershipStatus.rawValue, "daemon.membership.status")
        XCTAssertEqual(BurnBarRPCMethod.membershipCheckoutURL.rawValue, "daemon.membership.checkoutUrl")
        XCTAssertEqual(BurnBarRPCMethod.membershipPortalURL.rawValue, "daemon.membership.portalUrl")
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

        let portal = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarMembershipPortalURLRequest>.self,
            from: Data(#"{"id":"portal-1","method":"daemon.membership.portalUrl","params":{"return_url":"https://openburnbar.com/"}}"#.utf8)
        )
        XCTAssertEqual(portal.params.returnURL, "https://openburnbar.com/")
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

    func testPortalUsesProductionCallableEnvelopeDaemonAuthAppCheckAndValidatedStripeURL() async throws {
        MembershipURLProtocol.reset(responseBody: #"{"data":{"url":"https://billing.stripe.com/p/session/member_123"}}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        let client = EnvironmentBurnBarMembershipCloudClient(
            environment: [
                "OPENBURNBAR_FIREBASE_ID_TOKEN": "daemon-id-token",
                "OPENBURNBAR_FIREBASE_APP_CHECK_TOKEN": "daemon-app-check-token"
            ],
            session: URLSession(configuration: configuration)
        )

        let response = try await client.portalURL(BurnBarMembershipPortalURLRequest())
        XCTAssertEqual(response.url, "https://billing.stripe.com/p/session/member_123")
        XCTAssertEqual(response.source, "stripe_billing_portal")

        let request = try XCTUnwrap(MembershipURLProtocol.lastRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://us-central1-burnbar.cloudfunctions.net/createStripeBurnBarProPortalSession"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer daemon-id-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "daemon-app-check-token")
        XCTAssertEqual(request.timeoutInterval, 15, accuracy: 0.01)
        let body = try XCTUnwrap(MembershipURLProtocol.lastRequestBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["returnUrl"] as? String, "https://openburnbar.com/")
    }

    func testCheckoutUsesProductionCallableEnvelopeAndApprovedRedirects() async throws {
        MembershipURLProtocol.reset(responseBody: #"{"data":{"url":"https://checkout.stripe.com/c/pay/free_123","source":"stripe_checkout"}}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        let client = EnvironmentBurnBarMembershipCloudClient(
            environment: ["OPENBURNBAR_FIREBASE_ID_TOKEN": "daemon-id-token"],
            session: URLSession(configuration: configuration)
        )

        let response = try await client.checkoutURL(BurnBarMembershipCheckoutURLRequest())
        XCTAssertEqual(response.url, "https://checkout.stripe.com/c/pay/free_123")
        let request = try XCTUnwrap(MembershipURLProtocol.lastRequest())
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://us-central1-burnbar.cloudfunctions.net/createStripeBurnBarProCheckoutSession"
        )
        let body = try XCTUnwrap(MembershipURLProtocol.lastRequestBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["successUrl"] as? String, "https://openburnbar.com/account")
        XCTAssertEqual(data["cancelUrl"] as? String, "https://openburnbar.com/account")
    }

    func testPortalRejectsUntrustedCallableURL() async throws {
        MembershipURLProtocol.reset(responseBody: #"{"result":{"url":"https://billing.stripe.com.evil.example/p/session/member_123"}}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        let client = EnvironmentBurnBarMembershipCloudClient(
            environment: [
                "OPENBURNBAR_MEMBERSHIP_PORTAL_ENDPOINT": "https://example.com/createStripeBurnBarProPortalSession",
                "OPENBURNBAR_FIREBASE_ID_TOKEN": "daemon-id-token"
            ],
            session: URLSession(configuration: configuration)
        )
        do {
            _ = try await client.portalURL(BurnBarMembershipPortalURLRequest())
            XCTFail("portalURL must reject a lookalike Stripe host")
        } catch let error as BurnBarMembershipServiceError {
            XCTAssertEqual(error.membershipCode, .invalidResponse)
        }
    }

    func testPortalRejectsUnownedReturnURLBeforeCallingStripe() async throws {
        MembershipURLProtocol.reset(responseBody: #"{"data":{"url":"https://billing.stripe.com/p/session/member_123"}}"#)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        let client = EnvironmentBurnBarMembershipCloudClient(
            environment: [
                "OPENBURNBAR_MEMBERSHIP_PORTAL_ENDPOINT": "https://example.com/createStripeBurnBarProPortalSession",
                "OPENBURNBAR_FIREBASE_ID_TOKEN": "daemon-id-token"
            ],
            session: URLSession(configuration: configuration)
        )
        for refused in [
            "http://openburnbar.com/",
            "https://openburnbar.com.evil.example/",
            "https://user@openburnbar.com/",
            "https://openburnbar.com:444/",
            "https://openburnbar.com/admin",
            "https://openburnbar.com/?next=https://evil.example"
        ] {
            do {
                _ = try await client.portalURL(BurnBarMembershipPortalURLRequest(returnURL: refused))
                XCTFail("portalURL must reject return URL: \(refused)")
            } catch let error as BurnBarMembershipServiceError {
                XCTAssertEqual(error.membershipCode, .invalidResponse)
            }
        }
        XCTAssertNil(MembershipURLProtocol.lastRequest())
    }

    func testCheckoutRejectsNonStripeOrInsecureExternalURLs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MembershipURLProtocol.self]
        let client = EnvironmentBurnBarMembershipCloudClient(
            environment: [
                "OPENBURNBAR_MEMBERSHIP_CHECKOUT_ENDPOINT": "https://example.com/createStripeBurnBarProCheckoutSession",
                "OPENBURNBAR_FIREBASE_ID_TOKEN": "daemon-id-token"
            ],
            session: URLSession(configuration: configuration)
        )
        for refused in [
            "http://checkout.stripe.com/c/pay/session",
            "https://checkout.stripe.com.evil.example/c/pay/session",
            "https://user@checkout.stripe.com/c/pay/session",
            "https://checkout.stripe.com:444/c/pay/session",
            "https://billing.stripe.com/p/session/not-checkout"
        ] {
            MembershipURLProtocol.reset(responseBody: #"{"data":{"url":"\#(refused)"}}"#)
            do {
                _ = try await client.checkoutURL(BurnBarMembershipCheckoutURLRequest())
                XCTFail("checkoutURL must reject external URL: \(refused)")
            } catch let error as BurnBarMembershipServiceError {
                XCTAssertEqual(error.membershipCode, .invalidResponse)
            }
        }
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
                portalResponse: BurnBarMembershipPortalURLResponse(url: "https://billing.stripe.com/p/session/member_123"),
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

        let portalData = try await server.handleMembershipRPC(
            method: .membershipPortalURL,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"portal-1","method":"daemon.membership.portalUrl","params":{"return_url":"https://openburnbar.com/"}}"#.utf8)
        )
        let portal = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarMembershipPortalURLResponse>.self,
            from: portalData
        )
        XCTAssertEqual(portal.result?.url, "https://billing.stripe.com/p/session/member_123")

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
    var portalResponse: BurnBarMembershipPortalURLResponse?
    var portalError: BurnBarMembershipServiceError?
    var restoreResponse: BurnBarMembershipSnapshot?
    var restoreError: BurnBarMembershipServiceError?

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        if let checkoutError { throw checkoutError }
        if let checkoutResponse { return checkoutResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("checkout fixture not configured")
    }

    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse {
        if let portalError { throw portalError }
        if let portalResponse { return portalResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("portal fixture not configured")
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
    var portalResponse: BurnBarMembershipPortalURLResponse?
    var portalError: BurnBarMembershipServiceError?
    var restoreResponse: BurnBarMembershipRestoreResponse

    func status() async -> BurnBarMembershipStatusResponse {
        statusResponse
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        if let checkoutError { throw checkoutError }
        if let checkoutResponse { return checkoutResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("checkout fixture not configured")
    }

    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse {
        if let portalError { throw portalError }
        if let portalResponse { return portalResponse }
        throw BurnBarMembershipServiceError.cloudUnavailable("portal fixture not configured")
    }

    func restore() async -> BurnBarMembershipRestoreResponse {
        restoreResponse
    }
}

private final class MembershipURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var responseBody = Data()
    private nonisolated(unsafe) static var request: URLRequest?
    private nonisolated(unsafe) static var requestBody: Data?

    static func reset(responseBody: String) {
        lock.lock()
        self.responseBody = Data(responseBody.utf8)
        request = nil
        requestBody = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    static func lastRequestBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return requestBody
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        Self.lock.lock()
        Self.request = request
        Self.requestBody = body
        let responseBody = Self.responseBody
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
