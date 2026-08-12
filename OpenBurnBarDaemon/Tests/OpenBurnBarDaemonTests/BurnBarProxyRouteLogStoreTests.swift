import OpenBurnBarEngine
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

    func testSafariAttributionIsStrictlyValidatedBeforePersistence() {
        let canonical = "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
        let valid = GatewayRequestAttribution.from(headers: [
            "x-openburnbar-client": "openburnbar-safari-extension",
            "x-openburnbar-correlation-id": canonical
        ])
        XCTAssertEqual(valid.clientSource, "openburnbar-safari-extension")
        XCTAssertEqual(valid.clientRequestCorrelationID, canonical.lowercased())

        for invalidHeaders in [
            [
                "x-openburnbar-client": "openburnbar-safari-extension-impostor",
                "x-openburnbar-correlation-id": canonical
            ],
            [
                "x-openburnbar-client": "openburnbar-safari-extension",
                "x-openburnbar-correlation-id": "https://example.com/private"
            ],
            [
                "x-openburnbar-client": "openburnbar-safari-extension",
                "x-openburnbar-correlation-id": "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51\r\nsecret"
            ],
            [
                "x-openburnbar-client": "openburnbar-safari-extension",
                "x-openburnbar-correlation-id": "2B0D4A57-A4E2-1C18-9AF0-2026E06EAF51"
            ],
            [
                "x-openburnbar-client": "unrelated-client",
                "x-openburnbar-correlation-id": canonical
            ],
            [
                "x-openburnbar-client": "openburnbar-safari-extension"
            ],
            [
                "x-openburnbar-correlation-id": canonical
            ]
        ] {
            let attribution = GatewayRequestAttribution.from(headers: invalidHeaders)
            XCTAssertNil(attribution.clientSource)
            XCTAssertNil(attribution.clientRequestCorrelationID)
        }
    }

    func testSafariAttributionCapabilityBindsSessionAndConsumesCorrelationOnce() async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let attached = Locked(true)
        let authority = SafariGatewayAttributionAuthority(
            sessionAttachmentValidator: { observedClientID, observedSessionID in
                attached.read()
                    && observedClientID == clientID
                    && observedSessionID == sessionID
            }
        )
        let issuedCapability = await authority.issue(
            clientID: clientID,
            sessionID: sessionID
        )
        let issued = try XCTUnwrap(issuedCapability)
        XCTAssertTrue(issued.expiresAt > Date())
        XCTAssertEqual(issued.token.count, 64)
        XCTAssertEqual(
            issued.token.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            )?.lowerBound,
            issued.token.startIndex
        )

        let correlationID = "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
        let headers = [
            "x-openburnbar-client": GatewayRequestAttribution.safariClientSource,
            "x-openburnbar-correlation-id": correlationID,
            SafariGatewayAttributionAuthority.capabilityHeader: issued.token
        ]
        let accepted = await authority.resolve(headers: headers)
        XCTAssertEqual(
            accepted,
            .accepted(
                GatewayRequestAttribution(
                    clientSource: GatewayRequestAttribution.safariClientSource,
                    clientRequestCorrelationID: correlationID.lowercased()
                )
            )
        )
        let replayed = await authority.resolve(headers: headers)
        XCTAssertEqual(replayed, .rejected)
    }

    func testSafariAttributionCapabilityFailsClosedAcrossExpiryDetachAndAuthorityBoundaries() async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let attached = Locked(true)
        let observedNow = Locked(Date(timeIntervalSince1970: 1_786_512_000))
        let authority = SafariGatewayAttributionAuthority(
            lifetime: 30,
            now: { observedNow.read() },
            sessionAttachmentValidator: { observedClientID, observedSessionID in
                attached.read()
                    && observedClientID == clientID
                    && observedSessionID == sessionID
            }
        )
        let issuedCapability = await authority.issue(
            clientID: clientID,
            sessionID: sessionID
        )
        let issued = try XCTUnwrap(issuedCapability)
        let baseHeaders = [
            "x-openburnbar-client": GatewayRequestAttribution.safariClientSource,
            "x-openburnbar-correlation-id": "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51",
            SafariGatewayAttributionAuthority.capabilityHeader: issued.token
        ]

        let foreignAuthority = SafariGatewayAttributionAuthority(
            sessionAttachmentValidator: { _, _ in true }
        )
        let foreignResolution = await foreignAuthority.resolve(
            headers: baseHeaders
        )
        XCTAssertEqual(foreignResolution, .rejected)

        attached.write(false)
        let detachedResolution = await authority.resolve(headers: baseHeaders)
        XCTAssertEqual(detachedResolution, .rejected)

        attached.write(true)
        let expiringCapability = await authority.issue(
            clientID: clientID,
            sessionID: sessionID
        )
        let expiring = try XCTUnwrap(expiringCapability)
        observedNow.write(expiring.expiresAt)
        let expiredResolution = await authority.resolve(
            headers: baseHeaders.merging([
                SafariGatewayAttributionAuthority.capabilityHeader: expiring.token
            ]) { _, replacement in replacement }
        )
        XCTAssertEqual(expiredResolution, .rejected)
    }

    func testSafariAttributionCapabilityReissueInvalidatesPriorTokenWithoutMalformedConsumption() async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let authority = SafariGatewayAttributionAuthority(
            sessionAttachmentValidator: { observedClientID, observedSessionID in
                observedClientID == clientID && observedSessionID == sessionID
            }
        )
        let firstCapability = await authority.issue(
            clientID: clientID,
            sessionID: sessionID
        )
        let first = try XCTUnwrap(firstCapability)
        let secondCapability = await authority.issue(
            clientID: clientID,
            sessionID: sessionID,
            forceRotation: true
        )
        let second = try XCTUnwrap(secondCapability)
        let correlationID = "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
        let headers: (String) -> [String: String] = { token in
            [
                "x-openburnbar-client": GatewayRequestAttribution.safariClientSource,
                "x-openburnbar-correlation-id": correlationID,
                SafariGatewayAttributionAuthority.capabilityHeader: token
            ]
        }

        let invalidatedResolution = await authority.resolve(
            headers: headers(first.token)
        )
        XCTAssertEqual(invalidatedResolution, .rejected)
        let malformedResolution = await authority.resolve(
            headers: headers(second.token).merging([
                "x-openburnbar-correlation-id": "not-a-correlation"
            ]) { _, replacement in replacement }
        )
        XCTAssertEqual(malformedResolution, .rejected)
        let acceptedResolution = await authority.resolve(
            headers: headers(second.token)
        )
        XCTAssertEqual(
            acceptedResolution,
            .accepted(
                GatewayRequestAttribution(
                    clientSource: GatewayRequestAttribution.safariClientSource,
                    clientRequestCorrelationID: correlationID.lowercased()
                )
            )
        )
    }

    func testSafariAttributionCapabilityReusesCurrentLiveGeneration()
        async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let authority = SafariGatewayAttributionAuthority(
            sessionAttachmentValidator: { observedClientID, observedSessionID in
                observedClientID == clientID && observedSessionID == sessionID
            }
        )

        let first = try XCTUnwrap(
            await authority.issue(
                clientID: clientID,
                sessionID: sessionID
            )
        )
        let repeated = try XCTUnwrap(
            await authority.issue(
                clientID: clientID,
                sessionID: sessionID
            )
        )

        XCTAssertEqual(repeated.token, first.token)
        XCTAssertGreaterThanOrEqual(repeated.expiresAt, first.expiresAt)
        let accepted = await authority.resolve(headers: [
            "x-openburnbar-client":
                GatewayRequestAttribution.safariClientSource,
            "x-openburnbar-correlation-id":
                "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51",
            SafariGatewayAttributionAuthority.capabilityHeader:
                first.token
        ])
        XCTAssertEqual(
            accepted.attribution.clientSource,
            GatewayRequestAttribution.safariClientSource
        )
    }

    func testSafariAttributionCapabilityRenewalExtendsExpiryWithoutLosingReplayState()
        async throws
    {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let observedNow = Locked(Date(timeIntervalSince1970: 1_786_512_000))
        let authority = SafariGatewayAttributionAuthority(
            lifetime: 5 * 60,
            now: { observedNow.read() },
            sessionAttachmentValidator: { observedClientID, observedSessionID in
                observedClientID == clientID && observedSessionID == sessionID
            }
        )
        let first = try XCTUnwrap(
            await authority.issue(clientID: clientID, sessionID: sessionID)
        )
        let consumedCorrelation =
            "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
        let freshCorrelation =
            "7DC72490-799E-4A9D-B22B-35E6860B9C31"
        let headers: (String, String) -> [String: String] = {
            token,
            correlationID in
            [
                "x-openburnbar-client":
                    GatewayRequestAttribution.safariClientSource,
                "x-openburnbar-correlation-id": correlationID,
                SafariGatewayAttributionAuthority.capabilityHeader: token,
            ]
        }

        let firstResolution = await authority.resolve(
            headers: headers(first.token, consumedCorrelation)
        )
        XCTAssertEqual(
            firstResolution.attribution.clientSource,
            GatewayRequestAttribution.safariClientSource
        )

        observedNow.write(first.expiresAt.addingTimeInterval(-29))
        let renewed = try XCTUnwrap(
            await authority.issue(clientID: clientID, sessionID: sessionID)
        )

        XCTAssertEqual(renewed.token, first.token)
        XCTAssertEqual(
            renewed.expiresAt,
            observedNow.read().addingTimeInterval(5 * 60)
        )
        XCTAssertGreaterThan(
            renewed.expiresAt.timeIntervalSince(observedNow.read()),
            30
        )
        let replay = await authority.resolve(
            headers: headers(renewed.token, consumedCorrelation)
        )
        XCTAssertEqual(replay, .rejected)
        let fresh = await authority.resolve(
            headers: headers(renewed.token, freshCorrelation)
        )
        XCTAssertEqual(
            fresh.attribution.clientSource,
            GatewayRequestAttribution.safariClientSource
        )
    }

    func testConcurrentForcedRotationPreventsSuspendedRenewalFromRevivingOldGeneration()
        async throws
    {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let validator = OrderedAttributionValidator()
        await validator.setSuspended(false)
        let authority = SafariGatewayAttributionAuthority(
            sessionAttachmentValidator: { _, _ in
                await validator.validate()
            }
        )
        let first = try XCTUnwrap(
            await authority.issue(clientID: clientID, sessionID: sessionID)
        )
        await validator.setSuspended(true)

        let renewalTask = Task {
            await authority.issue(clientID: clientID, sessionID: sessionID)
        }
        await validator.waitUntilCallCount(2)
        let rotationTask = Task {
            await authority.issue(
                clientID: clientID,
                sessionID: sessionID,
                forceRotation: true
            )
        }
        await validator.waitUntilCallCount(3)

        await validator.release(call: 2)
        XCTAssertNil(await renewalTask.value)
        await validator.release(call: 3)
        let rotatedValue = await rotationTask.value
        let rotated = try XCTUnwrap(rotatedValue)
        await validator.setSuspended(false)

        XCTAssertNotEqual(rotated.token, first.token)
        let correlationID =
            "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
        let headers: (String) -> [String: String] = { token in
            [
                "x-openburnbar-client":
                    GatewayRequestAttribution.safariClientSource,
                "x-openburnbar-correlation-id": correlationID,
                SafariGatewayAttributionAuthority.capabilityHeader: token,
            ]
        }
        let oldGenerationResolution = await authority.resolve(
            headers: headers(first.token)
        )
        XCTAssertEqual(oldGenerationResolution, .rejected)
        let rotatedResolution = await authority.resolve(
            headers: headers(rotated.token)
        )
        XCTAssertEqual(
            rotatedResolution.attribution.clientSource,
            GatewayRequestAttribution.safariClientSource
        )
    }

    func testConcurrentSafariAttributionIssuanceCommitsOnlyNewestGeneration() async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let validator = OrderedAttributionValidator()
        let authority = SafariGatewayAttributionAuthority(
            sessionAttachmentValidator: { _, _ in
                await validator.validate()
            }
        )

        let firstTask = Task {
            await authority.issue(clientID: clientID, sessionID: sessionID)
        }
        await validator.waitUntilCallCount(1)
        let secondTask = Task {
            await authority.issue(clientID: clientID, sessionID: sessionID)
        }
        await validator.waitUntilCallCount(2)

        await validator.release(call: 1)
        let first = await firstTask.value
        XCTAssertNil(first)
        await validator.release(call: 2)
        let secondValue = await secondTask.value
        let second = try XCTUnwrap(secondValue)
        await validator.setSuspended(false)

        let resolution = await authority.resolve(headers: [
            "x-openburnbar-client": GatewayRequestAttribution.safariClientSource,
            "x-openburnbar-correlation-id":
                "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51",
            SafariGatewayAttributionAuthority.capabilityHeader: second.token
        ])
        XCTAssertEqual(resolution.attribution.clientSource, GatewayRequestAttribution.safariClientSource)
    }

    func testConcurrentSafariAttributionReplayAcceptsExactlyOnce() async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let validator = OrderedAttributionValidator()
        await validator.setSuspended(false)
        let authority = SafariGatewayAttributionAuthority(
            maximumCorrelationIDs: 1,
            sessionAttachmentValidator: { _, _ in
                await validator.validate()
            }
        )
        let issuedValue = await authority.issue(
            clientID: clientID,
            sessionID: sessionID
        )
        let issued = try XCTUnwrap(issuedValue)
        await validator.setSuspended(true)

        let headers = [
            "x-openburnbar-client": GatewayRequestAttribution.safariClientSource,
            "x-openburnbar-correlation-id":
                "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51",
            SafariGatewayAttributionAuthority.capabilityHeader: issued.token
        ]
        let firstTask = Task { await authority.resolve(headers: headers) }
        await validator.waitUntilCallCount(2)
        let secondTask = Task { await authority.resolve(headers: headers) }
        let second = await secondTask.value
        XCTAssertEqual(second, .rejected)

        await validator.release(call: 2)
        let first = await firstTask.value
        XCTAssertEqual(first.attribution.clientSource, GatewayRequestAttribution.safariClientSource)
        let replay = await authority.resolve(headers: headers)
        XCTAssertEqual(replay, .rejected)
    }

    func testSafariAttributionBoundsResolvingAndConsumedCorrelationsTogether()
        async throws {
        let clientID = BurnBarClientID(rawValue: "safari-client")
        let sessionID = BurnBarSessionID(rawValue: "safari-session")
        let validator = OrderedAttributionValidator()
        await validator.setSuspended(false)
        let authority = SafariGatewayAttributionAuthority(
            maximumCorrelationIDs: 2,
            sessionAttachmentValidator: { _, _ in
                await validator.validate()
            }
        )
        let issuedValue = await authority.issue(
            clientID: clientID,
            sessionID: sessionID
        )
        let issued = try XCTUnwrap(issuedValue)
        await validator.setSuspended(true)
        let headers: (String) -> [String: String] = { correlationID in
            [
                "x-openburnbar-client":
                    GatewayRequestAttribution.safariClientSource,
                "x-openburnbar-correlation-id": correlationID,
                SafariGatewayAttributionAuthority.capabilityHeader:
                    issued.token
            ]
        }
        let firstTask = Task {
            await authority.resolve(
                headers: headers(
                    "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
                )
            )
        }
        let secondTask = Task {
            await authority.resolve(
                headers: headers(
                    "7DC72490-799E-4A9D-B22B-35E6860B9C31"
                )
            )
        }
        await validator.waitUntilCallCount(3)

        let saturated = await authority.resolve(
            headers: headers("8A738415-1411-4F36-9C79-4F5D363A0D28")
        )
        XCTAssertEqual(saturated, .rejected)

        await validator.release(call: 2)
        await validator.release(call: 3)
        _ = await firstTask.value
        _ = await secondTask.value
    }

    func testRouteLogCodableRemainsBackwardCompatibleWithRowsWithoutAttribution() throws {
        let entry = BurnBarProxyRouteLogEntry(
            occurredAt: Date(timeIntervalSince1970: 400),
            requestPath: "/v1/chat/completions",
            endpoint: "Chat Completions",
            clientModelSlug: "vision-model",
            finalStatus: .exact,
            clientSource: "openburnbar-safari-extension",
            clientRequestCorrelationID: "2b0d4a57-a4e2-4c18-9af0-2026e06eaf51"
        )
        let encoded = try JSONEncoder().encode(entry)
        var oldRow = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldRow.removeValue(forKey: "clientSource")
        oldRow.removeValue(forKey: "clientRequestCorrelationID")

        let decoded = try JSONDecoder().decode(
            BurnBarProxyRouteLogEntry.self,
            from: JSONSerialization.data(withJSONObject: oldRow)
        )

        XCTAssertNil(decoded.clientSource)
        XCTAssertNil(decoded.clientRequestCorrelationID)
        XCTAssertEqual(decoded.clientModelSlug, "vision-model")
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

private actor OrderedAttributionValidator {
    private var callCount = 0
    private var isSuspended = true
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func validate() async -> Bool {
        callCount += 1
        let call = callCount
        resumeSatisfiedCallWaiters()
        guard isSuspended else { return true }
        await withCheckedContinuation { continuation in
            releaseContinuations[call] = continuation
        }
        return true
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        if callCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((expectedCount, continuation))
        }
    }

    func release(call: Int) {
        releaseContinuations.removeValue(forKey: call)?.resume()
    }

    private func resumeSatisfiedCallWaiters() {
        let satisfied = callWaiters.filter { callCount >= $0.count }
        callWaiters.removeAll { callCount >= $0.count }
        satisfied.forEach { $0.continuation.resume() }
    }
}
