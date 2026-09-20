#if os(Linux)
import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarLinuxGatewayRoutePipelineTests: XCTestCase {
    func testReadyRemoteSlotIsEligibleAndListed() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(slots: [slot(id: "primary")])

        let facts = pipeline.catalogFacts(for: configuration)
        XCTAssertEqual(facts.accountIDs, ["primary"])
        XCTAssertTrue(facts.isEligible)
        XCTAssertTrue(pipeline.hasEligibleRoute(for: configuration))
        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["primary"])
    }

    func testDisabledProviderIsNotEligibleEvenWithCredentials() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(isEnabled: false, slots: [slot(id: "primary")])

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["primary"])
        XCTAssertFalse(pipeline.hasEligibleRoute(for: configuration))
    }

    func testProviderWithoutRoutingCapabilityIsNotEligible() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(
            capabilities: [.accounting],
            slots: [slot(id: "primary")]
        )

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["primary"])
        XCTAssertFalse(pipeline.hasEligibleRoute(for: configuration))
    }

    func testDisabledAndEmptyKeySlotsAreOmittedFromAccountIDs() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(slots: [
            slot(id: "disabled", enabled: false),
            slot(id: "blank", apiKey: "   "),
            slot(id: "ready")
        ])

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["ready"])
        XCTAssertTrue(pipeline.hasEligibleRoute(for: configuration))
    }

    func testCoolingSlotStaysInCatalogButIsNotEligible() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(slots: [
            slot(
                id: "cooling",
                status: .coolingDown,
                cooldownUntil: now.addingTimeInterval(60)
            )
        ])

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["cooling"])
        XCTAssertFalse(pipeline.hasEligibleRoute(for: configuration, now: now))
    }

    func testLocalProviderWithoutSlotsUsesLegacyAccountAndIsEligible() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(
            providerID: "ollama-local",
            local: true,
            slots: [],
            apiKey: nil
        )

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["legacy"])
        XCTAssertTrue(pipeline.hasEligibleRoute(for: configuration))
    }

    func testRemoteLegacyCredentialWithoutSlotsIsEligible() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(slots: [], apiKey: "legacy-key")

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["legacy"])
        XCTAssertTrue(pipeline.hasEligibleRoute(for: configuration))
    }

    func testRemoteWithoutSlotsOrCredentialHasNoRoute() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(slots: [], apiKey: nil)

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), [])
        XCTAssertFalse(pipeline.hasEligibleRoute(for: configuration))
    }

    func testLocalSlotsListEvenWithoutAPIKeys() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let configuration = resolvedConfiguration(
            providerID: "ollama-local",
            local: true,
            slots: [slot(id: "local-a", apiKey: nil)],
            apiKey: nil
        )

        XCTAssertEqual(pipeline.routeAccountIDs(for: configuration), ["local-a"])
        XCTAssertTrue(pipeline.hasEligibleRoute(for: configuration))
    }

    func testPreferredFormatFamiliesPreferAnthropicForMessagesAndClaudeSlugs() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()

        XCTAssertEqual(
            pipeline.preferredFormatFamilies(modelID: "glm-5-turbo", prefersAnthropicFirst: false),
            [.openaiCompat, .anthropic]
        )
        XCTAssertEqual(
            pipeline.preferredFormatFamilies(modelID: "claude-sonnet-4-6", prefersAnthropicFirst: false),
            [.anthropic, .openaiCompat]
        )
        XCTAssertEqual(
            pipeline.preferredFormatFamilies(modelID: "gpt-5.4", prefersAnthropicFirst: true),
            [.anthropic, .openaiCompat]
        )
        XCTAssertEqual(
            pipeline.preferredFormatFamilies(modelID: "  Anthropic-test  ", prefersAnthropicFirst: false),
            [.anthropic, .openaiCompat]
        )
    }

    func testChoicesPreserveRankOrderAndFailoverHeadroom() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let primary = makeRoute(providerID: "zai", slotID: "primary")
        let secondary = makeRoute(providerID: "zai", slotID: "secondary")
        let tertiary = makeRoute(providerID: "anthropic", slotID: "primary")

        XCTAssertTrue(pipeline.choices(rankedRoutes: [], formatFamily: .openaiCompat).isEmpty)

        let choices = pipeline.choices(
            rankedRoutes: [primary, secondary, tertiary],
            formatFamily: .openaiCompat
        )
        XCTAssertEqual(choices.map(\.attemptIndex), [0, 1, 2])
        XCTAssertEqual(choices.map(\.remainingCandidates), [2, 1, 0])
        XCTAssertEqual(choices.map(\.hasMoreCandidates), [true, true, false])
        XCTAssertEqual(choices.map(\.route.credentialSlotID), ["primary", "secondary", "primary"])
        XCTAssertTrue(choices.allSatisfy { $0.formatFamily == .openaiCompat })
        XCTAssertEqual(choices[2].route.providerID, "anthropic")
    }

    func testFailoverWalksQuotaAuthCapacityAndTransportErrors() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let more = BurnBarLinuxGatewayRouteChoice(
            route: makeRoute(),
            formatFamily: .openaiCompat,
            attemptIndex: 0,
            remainingCandidates: 1
        )
        let last = BurnBarLinuxGatewayRouteChoice(
            route: makeRoute(slotID: "secondary"),
            formatFamily: .openaiCompat,
            attemptIndex: 1,
            remainingCandidates: 0
        )

        XCTAssertTrue(pipeline.shouldFailOver(BurnBarProviderExecutorError.upstreamError(429, "slow down")))
        XCTAssertTrue(pipeline.shouldFailOver(BurnBarProviderExecutorError.upstreamError(401, "unauthorized")))
        XCTAssertTrue(pipeline.shouldFailOver(BurnBarProviderExecutorError.upstreamError(403, "forbidden")))
        XCTAssertTrue(pipeline.shouldFailOver(BurnBarProviderExecutorError.upstreamError(402, "pay")))
        XCTAssertTrue(pipeline.shouldFailOver(BurnBarProviderExecutorError.upstreamError(529, "overloaded")))
        XCTAssertTrue(pipeline.shouldFailOver(
            BurnBarProviderExecutorError.upstreamError(500, "insufficient_quota for this model")
        ))
        XCTAssertFalse(pipeline.shouldFailOver(BurnBarProviderExecutorError.upstreamError(500, "internal error")))
        XCTAssertFalse(pipeline.shouldFailOver(BurnBarProviderExecutorError.invalidResponse))
        XCTAssertTrue(pipeline.shouldFailOver(URLError(.timedOut)))
        XCTAssertTrue(pipeline.shouldFailOver(URLError(.cannotConnectToHost)))
        XCTAssertFalse(pipeline.shouldFailOver(URLError(.cancelled)))
        XCTAssertTrue(pipeline.shouldFailOver(QuotaDescriptionError()))
        XCTAssertFalse(pipeline.shouldFailOver(GenericDescriptionError()))

        XCTAssertTrue(pipeline.shouldTryNextCandidate(more, after: BurnBarProviderExecutorError.upstreamError(429, "")))
        XCTAssertFalse(pipeline.shouldTryNextCandidate(last, after: BurnBarProviderExecutorError.upstreamError(429, "")))
        XCTAssertFalse(pipeline.shouldTryNextCandidate(more, after: BurnBarProviderExecutorError.upstreamError(500, "no")))
    }

    func testRouteAttemptRecordsExactAndFailedAttempts() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "acme",
                    displayName: "Acme",
                    baseURL: "https://acme.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    logoKey: "AcmeCustomLogo",
                    models: []
                )
            ]
        )
        let pipeline = BurnBarLinuxGatewayRoutePipeline(catalog: catalog)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let completed = started.addingTimeInterval(1.5)
        let route = makeRoute(
            providerID: "acme",
            displayName: "Acme",
            slotID: "primary",
            slotLabel: "Primary",
            requestedModel: "acme-1",
            resolvedModelID: "acme-1",
            canonicalModelID: "acme-1",
            endpointProfileID: "us-east"
        )

        let exact = pipeline.routeAttempt(
            sequence: 1,
            startedAt: started,
            completedAt: completed,
            route: route,
            status: .exact,
            httpStatus: 200
        )
        XCTAssertEqual(exact.sequence, 1)
        XCTAssertEqual(exact.durationMilliseconds, 1500)
        XCTAssertEqual(exact.providerID, "acme")
        XCTAssertEqual(exact.providerName, "Acme")
        XCTAssertEqual(exact.providerLogoKey, "AcmeCustomLogo")
        XCTAssertEqual(exact.accountID, "primary")
        XCTAssertEqual(exact.accountLabel, "Primary")
        XCTAssertEqual(exact.routingModelSlug, "acme-1")
        XCTAssertEqual(exact.upstreamModelSlug, "acme-1")
        XCTAssertEqual(exact.canonicalModelID, "acme-1")
        XCTAssertEqual(exact.formatFamily, BurnBarProviderFormatFamily.openaiCompat.rawValue)
        XCTAssertEqual(exact.endpointProfileID, "us-east")
        XCTAssertEqual(exact.transportKind, .http)
        XCTAssertEqual(exact.status, .exact)
        XCTAssertEqual(exact.httpStatus, 200)
        XCTAssertNil(exact.failureMessage)

        let failed = pipeline.routeAttempt(
            sequence: 2,
            startedAt: started,
            completedAt: started.addingTimeInterval(-1),
            route: makeRoute(providerID: "factory"),
            status: .failed,
            httpStatus: 429,
            failureMessage: "quota\nexhausted"
        )
        XCTAssertEqual(failed.durationMilliseconds, 0)
        XCTAssertEqual(failed.transportKind, .factoryDroid)
        XCTAssertEqual(failed.providerLogoKey, "FactoryLogo")
        XCTAssertEqual(failed.failureMessage, "quota exhausted")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.httpStatus, 429)
    }

    func testUsageIdempotencyKeyIsStableAndSlotScoped() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        let primary = makeRoute(slotID: "primary")
        let secondary = makeRoute(slotID: "secondary")
        let legacy = makeRoute(slotID: nil)

        let first = pipeline.usageIdempotencyKey(accountingRequestID: "req-1", route: primary)
        let again = pipeline.usageIdempotencyKey(accountingRequestID: "req-1", route: primary)
        XCTAssertEqual(first, again)
        XCTAssertTrue(first.hasPrefix("gateway:"))
        XCTAssertNotEqual(
            first,
            pipeline.usageIdempotencyKey(accountingRequestID: "req-1", route: secondary)
        )
        XCTAssertTrue(
            pipeline.usageIdempotencyKey(accountingRequestID: "req-1", route: legacy)
                .hasPrefix("gateway:")
        )
    }

    func testSplitProviderQualifiedModelIDUsesCatalog() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "zai",
                    displayName: "Z.ai",
                    baseURL: "https://api.z.ai/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: []
                )
            ]
        )
        let pipeline = BurnBarLinuxGatewayRoutePipeline(catalog: catalog)

        let split = pipeline.splitProviderQualifiedModelID("zai/glm-5-turbo")
        XCTAssertEqual(split.0, "zai")
        XCTAssertEqual(split.1, "glm-5-turbo")

        let unknown = pipeline.splitProviderQualifiedModelID("nope/glm-5-turbo")
        XCTAssertNil(unknown.0)
        XCTAssertEqual(unknown.1, "nope/glm-5-turbo")

        let emptyModel = pipeline.splitProviderQualifiedModelID("zai/   ")
        XCTAssertNil(emptyModel.0)
        XCTAssertEqual(emptyModel.1, "zai/   ")

        let bare = pipeline.splitProviderQualifiedModelID("glm-5-turbo")
        XCTAssertNil(bare.0)
        XCTAssertEqual(bare.1, "glm-5-turbo")

        let withoutCatalog = BurnBarLinuxGatewayRoutePipeline()
            .splitProviderQualifiedModelID("zai/glm-5-turbo")
        XCTAssertNil(withoutCatalog.0)
        XCTAssertEqual(withoutCatalog.1, "zai/glm-5-turbo")
    }

    func testFailureHelpersSanitizeAndExtractStatus() {
        let pipeline = BurnBarLinuxGatewayRoutePipeline()
        XCTAssertEqual(
            pipeline.httpStatus(from: BurnBarProviderExecutorError.upstreamError(402, "no funds")),
            402
        )
        XCTAssertNil(pipeline.httpStatus(from: BurnBarProviderExecutorError.invalidResponse))
        XCTAssertEqual(
            pipeline.routeLogFailureMessage(from: BurnBarProviderExecutorError.upstreamError(429, "secret")),
            "OpenBurnBar provider request failed with status 429."
        )
        XCTAssertEqual(
            pipeline.routeLogFailureMessage(from: GenericDescriptionError()),
            "internal boom"
        )
        XCTAssertNil(pipeline.sanitizedFailureMessage("   "))
        XCTAssertNil(pipeline.sanitizedFailureMessage(nil))
        XCTAssertEqual(pipeline.sanitizedFailureMessage("a\nb\rc"), "a b c")
        XCTAssertEqual(pipeline.sanitizedFailureMessage(String(repeating: "x", count: 300))?.count, 260)
        XCTAssertEqual(
            pipeline.elapsedMilliseconds(
                from: Date(timeIntervalSince1970: 10),
                to: Date(timeIntervalSince1970: 10.4)
            ),
            400
        )
    }
}

private struct QuotaDescriptionError: Error, LocalizedError {
    var errorDescription: String? { "hit a rate limit" }
}

private struct GenericDescriptionError: Error, LocalizedError {
    var errorDescription: String? { "internal boom" }
}

private func resolvedConfiguration(
    providerID: String = "zai",
    local: Bool = false,
    capabilities: [BurnBarProviderCapability] = [.routing],
    isEnabled: Bool = true,
    slots: [BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot],
    apiKey: String? = "legacy-key"
) -> BurnBarResolvedProviderConfiguration {
    let baseURL = local ? "http://127.0.0.1:11434" : "https://api.example/v1"
    return BurnBarResolvedProviderConfiguration(
        provider: BurnBarCatalogProvider(
            id: providerID,
            displayName: providerID,
            baseURL: baseURL,
            visibility: .public,
            capabilities: capabilities,
            models: [],
            local: local
        ),
        settings: BurnBarProviderSettings(
            providerID: providerID,
            isEnabled: isEnabled,
            baseURL: baseURL,
            preferredModelIDs: ["glm-5-turbo"],
            credentialSlots: slots.map(\.slot)
        ),
        preferredModels: [],
        credentialSlots: slots,
        apiKey: apiKey
    )
}

private func slot(
    id: String,
    enabled: Bool = true,
    status: BurnBarProviderCredentialSlotStatus = .ready,
    cooldownUntil: Date? = nil,
    apiKey: String? = "sk-test"
) -> BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot {
    BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot(
        slot: BurnBarProviderCredentialSlot(
            slotID: id,
            label: id,
            isEnabled: enabled,
            status: status,
            cooldownUntil: cooldownUntil
        ),
        apiKey: apiKey
    )
}

private func makeRoute(
    providerID: String = "zai",
    displayName: String? = nil,
    slotID: String? = "primary",
    slotLabel: String? = "Primary",
    requestedModel: String = "glm-5-turbo",
    resolvedModelID: String = "glm-5-turbo",
    canonicalModelID: String? = "glm-5-turbo",
    endpointProfileID: String? = nil
) -> BurnBarProviderRoute {
    BurnBarProviderRoute(
        providerID: providerID,
        providerDisplayName: displayName ?? providerID,
        credentialSlotID: slotID,
        credentialSlotLabel: slotID == nil ? nil : slotLabel,
        baseURL: "https://api.example/v1",
        requestedModel: requestedModel,
        resolvedModelID: resolvedModelID,
        canonicalModelID: canonicalModelID,
        apiKey: "sk-test",
        pricing: .defaultFallback,
        formatFamily: .openaiCompat,
        endpointProfileID: endpointProfileID
    )
}
#endif
