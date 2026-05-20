import XCTest
@testable import OpenBurnBarCore

final class ProviderAccountContractTests: XCTestCase {
    private let isoDate = "2026-05-03T12:00:00Z"

    func test_providerID_normalizesCatalogIdentityAndOpenAIProvider() {
        XCTAssertEqual(ProviderID(rawValue: " Claude Code ").rawValue, "claude-code")
        XCTAssertEqual(AgentProvider.claudeCode.providerID, .claudeCode)
        XCTAssertEqual(AgentProvider.openAI.providerID, .openAI)
        XCTAssertEqual(AgentProvider.codex.providerID, .codex)
        XCTAssertEqual(AgentProvider.openCode.providerID, .openCode)
        XCTAssertEqual(AgentProvider.fromProviderID(.openAI), .openAI)
        XCTAssertEqual(AgentProvider.fromProviderID(.codex), .codex)
        XCTAssertEqual(AgentProvider.fromProviderID(.openCode), .openCode)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("open code go"), .openCode)
        XCTAssertNotNil(BurnBarCatalogLoader.bundledCatalog.provider(id: ProviderID.openAI.rawValue))
        XCTAssertNotNil(BurnBarCatalogLoader.bundledCatalog.provider(id: ProviderID.openCode.rawValue))
    }

    func test_providerAccountDoc_roundTripsNonSecretMetadata() throws {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let account = ProviderAccountDoc(
            id: "openai_work",
            providerID: .openAI,
            label: "Work",
            identityHint: "Platform org",
            status: .connected,
            credentialKind: .bearer,
            storageScope: .cloudRefreshable,
            redactedLabel: "sk-***abcd",
            sourceDeviceID: "mac-1",
            linkedSwitcherProfileID: nil,
            isDefault: true,
            sortKey: 10,
            lastValidatedAt: date,
            lastRefreshAt: date,
            schemaVersion: 1,
            createdAt: date,
            updatedAt: date
        )

        let encoded = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(ProviderAccountDoc.self, from: encoded)

        XCTAssertEqual(decoded.id, "openai_work")
        XCTAssertEqual(decoded.providerID, .openAI)
        XCTAssertEqual(decoded.storageScope, .cloudRefreshable)
        XCTAssertEqual(decoded.redactedLabel, "sk-***abcd")
    }

    func test_quotaSnapshot_decodesLegacyProviderLevelShape() throws {
        let json = """
        {
          "id": "codex_default",
          "provider": "codex",
          "sourceKind": "provider",
          "sourceId": "default",
          "fetchedAt": "\(isoDate)",
          "source": "Codex",
          "confidence": "high",
          "buckets": [
            { "name": "daily", "used": 10, "limit": 100, "remaining": 90 }
          ],
          "schemaVersion": 1,
          "updatedAt": "\(isoDate)"
        }
        """

        let decoded = try decoder().decode(ProviderQuotaSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.providerID, .codex)
        XCTAssertEqual(decoded.sourceID, "default")
        XCTAssertNil(decoded.accountID)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func test_quotaSnapshot_decodesDesktopSyncedQuotaShape() throws {
        let json = """
        {
          "id": "cursor_unattributed_default",
          "provider": "Cursor",
          "providerID": "cursor",
          "sourceKind": "officialAPI",
          "sourceId": "default",
          "sourceID": "default",
          "fetchedAt": "\(isoDate)",
          "source": "officialAPI",
          "confidence": "exact",
          "buckets": [
            {
              "name": "cursor-plan",
              "used": 25,
              "limit": 100,
              "remaining": 75,
              "window": "monthly",
              "meta": {
                "label": "Plan",
                "unit": "requests",
                "isEstimated": "false"
              }
            }
          ],
          "schemaVersion": 2,
          "updatedAt": "\(isoDate)"
        }
        """

        let decoded = try decoder().decode(ProviderQuotaSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.provider, "Cursor")
        XCTAssertEqual(decoded.providerID, ProviderID(rawValue: "cursor"))
        XCTAssertEqual(decoded.sourceKind, .officialAPI)
        XCTAssertEqual(decoded.sourceID, "default")
        XCTAssertEqual(decoded.confidence, .high)
        XCTAssertEqual(decoded.buckets.first?.name, "cursor-plan")
        XCTAssertEqual(decoded.buckets.first?.meta?["label"], "Plan")
    }

    func test_quotaSnapshot_mapsUnavailableConfidenceToStale() throws {
        let json = """
        {
          "id": "openai_unattributed_default",
          "provider": "OpenAI",
          "providerID": "openai",
          "sourceKind": "officialAPI",
          "sourceId": "default",
          "fetchedAt": "\(isoDate)",
          "source": "officialAPI",
          "confidence": "unavailable",
          "buckets": [],
          "schemaVersion": 2,
          "updatedAt": "\(isoDate)"
        }
        """

        let decoded = try decoder().decode(ProviderQuotaSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.confidence, .stale)
    }

    func test_quotaSnapshot_encodesV2AccountIdentityAndCompatibilitySourceKeys() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: isoDate))
        let snapshot = ProviderQuotaSnapshot(
            id: "openai_work_mac-1",
            provider: "openai",
            providerID: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            accountStorageScope: .cloudRefreshable,
            sourceKind: .provider,
            sourceId: "mac-1",
            fetchedAt: date,
            source: "OpenAI",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(name: "daily", used: 10, limit: 100, remaining: 90)
            ],
            updatedAt: date
        )

        let data = try encoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["providerID"] as? String, "openai")
        XCTAssertEqual(object["accountID"] as? String, "openai_work")
        XCTAssertEqual(object["accountLabel"] as? String, "Work")
        XCTAssertEqual(object["sourceId"] as? String, "mac-1")
        XCTAssertEqual(object["sourceID"] as? String, "mac-1")
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
    }

    func test_tokenUsage_decodesLegacyRowsWithProviderAccountFallbacks() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "provider": "Codex",
          "sessionId": "session-1",
          "projectName": "BurnBar",
          "model": "codex-pro",
          "inputTokens": 10,
          "outputTokens": 20,
          "totalTokens": 30,
          "cost": 0.03,
          "startTime": "\(isoDate)",
          "endTime": "\(isoDate)"
        }
        """

        let decoded = try decoder().decode(TokenUsage.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.providerID, .codex)
        XCTAssertNil(decoded.providerAccountID)
        XCTAssertEqual(decoded.totalTokens, 30)
    }

    func test_usageRollup_decodesLegacyProviderOnlyShapeWithEmptyAccountSummaries() throws {
        let json = """
        {
          "windowKey": "today",
          "totals": { "requests": 1, "tokens": 30, "costUsd": 0.03 },
          "providerSummaries": [
            { "provider": "codex", "totalRequests": 1, "totalTokens": 30, "totalCost": 0.03 }
          ],
          "modelSummaries": [],
          "deviceSummaries": [],
          "dailyPoints": [],
          "computedAt": "\(isoDate)",
          "schemaVersion": 1
        }
        """

        let decoded = try decoder().decode(UsageRollupDoc.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.providerSummaries.first?.providerID, .codex)
        XCTAssertEqual(decoded.accountSummaries, [])
    }

    func test_accountRollup_canRepresentUnattributedUsage() {
        let summary = RollupProviderAccountSummary(
            providerID: .openAI,
            accountID: nil,
            accountLabel: "Usage not linked to an account yet",
            totalRequests: 2,
            totalTokens: 42
        )

        XCTAssertEqual(summary.id, "openai:unattributed")
        XCTAssertNil(summary.accountID)
    }

    func test_routingPolicy_roundRobinsThreeOpenAIAccountsByLeastRecentUse() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(modelID: "gpt-5.5", preferredProviderIDs: [.openAI]),
            candidates: [
                routingCandidate("work", label: "Work", lastUsedAt: now.addingTimeInterval(-10)),
                routingCandidate("personal", label: "Personal", lastUsedAt: now.addingTimeInterval(-60)),
                routingCandidate("client", label: "Client", lastUsedAt: nil)
            ],
            now: now
        )

        XCTAssertEqual(decision.selected?.accountID, "client")
        XCTAssertEqual(decision.nextFallback?.accountID, "personal")
        XCTAssertTrue(decision.lastSwitchReason.contains("Client is active"))
    }

    func test_routingPolicy_skipsExhaustedAccountUntilCooldownClears() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let exhausted = routingCandidate(
            "work",
            label: "Work",
            quotaState: .exhausted,
            cooldownUntil: now.addingTimeInterval(60)
        )
        let personal = routingCandidate("personal", label: "Personal")

        let duringCooldown = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(preferredProviderIDs: [.openAI]),
            candidates: [exhausted, personal],
            now: now
        )

        XCTAssertEqual(duringCooldown.selected?.accountID, "personal")
        XCTAssertEqual(duringCooldown.skipped.first?.reason, .exhausted)
        XCTAssertEqual(duringCooldown.exhaustedOrCoolingDown.map(\.accountID), ["work"])

        let afterCooldown = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(preferredProviderIDs: [.openAI]),
            candidates: [exhausted],
            now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(afterCooldown.selected?.accountID, "work")
        XCTAssertEqual(afterCooldown.selected?.quotaState, .unknown)
        XCTAssertNil(afterCooldown.selected?.cooldownUntil)
        XCTAssertTrue(afterCooldown.skipped.isEmpty)
    }

    func test_routingPolicy_authFailedAccountIsNotRetriedBlindly() {
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(preferredProviderIDs: [.openAI]),
            candidates: [
                routingCandidate("work", label: "Work", quotaState: .authFailed, lastFailureCode: "401"),
                routingCandidate("personal", label: "Personal")
            ]
        )

        XCTAssertEqual(decision.selected?.accountID, "personal")
        XCTAssertEqual(decision.skipped.first?.reason, .authFailed)
    }

    func test_routingPolicy_unknownQuotaRemainsEligibleUntilRuntimeFailure() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let unknown = routingCandidate("work", label: "Work", quotaState: .unknown)

        let beforeFailure = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(preferredProviderIDs: [.openAI]),
            candidates: [unknown],
            now: now
        )

        XCTAssertEqual(beforeFailure.selected?.accountID, "work")

        let afterFailureCandidate = unknown.applying(.rateLimited, at: now, cooldown: 300, failureCode: "429")
        let afterFailure = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(preferredProviderIDs: [.openAI]),
            candidates: [afterFailureCandidate, routingCandidate("personal", label: "Personal")],
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(afterFailure.selected?.accountID, "personal")
        XCTAssertEqual(afterFailure.skipped.first?.reason, .rateLimited)
    }

    func test_routingPolicy_legacySingleAccountStillRoutes() {
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(modelID: "gpt-5.5"),
            candidates: [
                .defaultLegacyAccount(providerID: .openAI, providerLabel: "OpenAI")
            ]
        )

        XCTAssertEqual(decision.selected?.providerID, .openAI)
        XCTAssertEqual(decision.selected?.accountID, "default")
    }

    func test_providerFamilyMode_keepsCodexFailoverInsideCodexAccounts() {
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(
                modelID: "codex-pro",
                preferredProviderIDs: [.codex],
                routerMode: .providerFamilyFailover,
                selectedProviderID: .codex,
                selectedAccountID: "codex_work",
                taskCategory: .coding
            ),
            candidates: [
                routingCandidate("codex_work", providerID: .codex, label: "Codex Work", quotaState: .exhausted),
                routingCandidate("codex_personal", providerID: .codex, label: "Codex Personal"),
                routingCandidate("claude_team", providerID: .claudeCode, label: "Claude Team"),
                routingCandidate("zai_team", providerID: ProviderID(rawValue: "zai"), label: "Z.ai Team")
            ]
        )

        XCTAssertEqual(decision.selected?.providerID, .codex)
        XCTAssertEqual(decision.selected?.accountID, "codex_personal")
        XCTAssertEqual(
            Set(decision.skipped.filter { $0.reason == .providerNotPreferred }.map(\.providerID)),
            Set([.claudeCode, ProviderID(rawValue: "zai")])
        )
    }

    func test_providerFamilyMode_keepsClaudeFailoverInsideClaudeAccounts() {
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(
                modelID: "claude-opus-4.7",
                preferredProviderIDs: [.claudeCode],
                routerMode: .providerFamilyFailover,
                selectedProviderID: .claudeCode,
                selectedAccountID: "claude_pro"
            ),
            candidates: [
                routingCandidate("claude_pro", providerID: .claudeCode, label: "Claude Pro", quotaState: .rateLimited),
                routingCandidate("claude_team", providerID: .claudeCode, label: "Claude Team"),
                routingCandidate("zai_team", providerID: ProviderID(rawValue: "zai"), label: "Z.ai Team")
            ]
        )

        XCTAssertEqual(decision.selected?.providerID, .claudeCode)
        XCTAssertEqual(decision.selected?.accountID, "claude_team")
        XCTAssertTrue(decision.skipped.contains { $0.providerID == ProviderID(rawValue: "zai") && $0.reason == .providerNotPreferred })
    }

    func test_providerFamilyMode_keepsZAIFailoverInsideZAIAccounts() {
        let zai = ProviderID(rawValue: "zai")
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(
                modelID: "glm-5",
                preferredProviderIDs: [zai],
                routerMode: .providerFamilyFailover,
                selectedProviderID: zai,
                selectedAccountID: "zai_a"
            ),
            candidates: [
                routingCandidate("zai_a", providerID: zai, label: "Z.ai A", quotaState: .authFailed),
                routingCandidate("zai_b", providerID: zai, label: "Z.ai B"),
                routingCandidate("codex_work", providerID: .codex, label: "Codex Work")
            ]
        )

        XCTAssertEqual(decision.selected?.providerID, zai)
        XCTAssertEqual(decision.selected?.accountID, "zai_b")
        XCTAssertTrue(decision.skipped.contains { $0.providerID == .codex && $0.reason == .providerNotPreferred })
    }

    func test_providerFamilyMode_selectedHealthyRouteStaysActive() {
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(
                modelID: "codex-pro",
                preferredProviderIDs: [.codex],
                routerMode: .providerFamilyFailover,
                selectedProviderID: .codex,
                selectedAccountID: "codex_work"
            ),
            candidates: [
                routingCandidate("codex_personal", providerID: .codex, label: "Codex Personal", lastUsedAt: .distantPast),
                routingCandidate("codex_work", providerID: .codex, label: "Codex Work", lastUsedAt: Date())
            ]
        )

        XCTAssertEqual(decision.selected?.accountID, "codex_work")
    }

    func test_sameModelFailoverCanUseCrossProviderCandidatesAfterHardConstraints() {
        let zai = ProviderID(rawValue: "zai")
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(
                modelID: "glm-5",
                preferredProviderIDs: [zai, .codex],
                routerMode: .sameModelFailover,
                requiredCanonicalModelID: "glm-5",
                selectedProviderID: zai,
                selectedAccountID: "zai_a",
                taskCategory: .coding,
                benchmarkStatus: ProviderModelBenchmarkStatus(
                    source: .terminalBench,
                    freshness: .fresh,
                    message: "Fresh terminal benchmark data."
                )
            ),
            candidates: [
                routingCandidate("zai_a", providerID: zai, label: "Z.ai A", quotaState: .exhausted, canonicalModelID: "glm-5"),
                routingCandidate("codex_work", providerID: .codex, label: "Codex Work", canonicalModelID: "glm-5")
            ]
        )

        XCTAssertEqual(decision.routerMode, ProviderRouterMode.sameModelFailover)
        XCTAssertEqual(decision.selected?.providerID, .codex)
        XCTAssertEqual(decision.event.benchmarkStatus?.freshness, .fresh)
        XCTAssertTrue(decision.event.explanation.contains("Exact Model Failover"))
        XCTAssertTrue(decision.event.exactModelInvariantPassed)
        XCTAssertEqual(decision.event.failoverDestinationProviderID, ProviderID.codex)
    }

    func test_routingEventsNeverIncludeCredentialsOrSecretRefs() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // The sanitiser must scrub these plaintext-shaped credential
        // strings before they reach the persisted routing event JSON.
        // Strings split via concatenation so the source itself can never
        // be mistaken for a real secret by entropy-based scanners.
        let sensitiveCredentialHandle = "secretVersionName=" + "REDACTED_PLACEHOLDER"
        let sensitiveFailureCode = "Authorization: " + "Bearer REDACTED_PLACEHOLDER"
        let sensitiveAccount = routingCandidate(
            "work",
            label: "Work",
            credentialHandle: sensitiveCredentialHandle,
            quotaState: .authFailed,
            lastFailureCode: sensitiveFailureCode
        )
        let decision = ProviderRoutingPolicy.decide(
            request: ProviderRoutingRequest(modelID: "gpt-5.5", preferredProviderIDs: [.openAI]),
            candidates: [
                sensitiveAccount,
                routingCandidate("personal", label: "Personal")
            ],
            now: now
        )

        let encoded = String(decoding: try encoder().encode(decision.event), as: UTF8.self)

        // The candidate's `credentialHandle` and `lastFailureCode` flow
        // through `ProviderRoutingPolicy.sanitizedAuditText` at init time,
        // so the in-memory values must already be scrubbed. The encoded
        // routing event must additionally never leak the placeholder
        // payload, the secret-shaped tag, or the credential handle key.
        XCTAssertFalse(sensitiveAccount.credentialHandle.localizedCaseInsensitiveContains("secretVersionName"))
        XCTAssertFalse(sensitiveAccount.credentialHandle.localizedCaseInsensitiveContains("REDACTED_PLACEHOLDER"))
        XCTAssertFalse(sensitiveAccount.lastFailureCode?.localizedCaseInsensitiveContains("Bearer ") ?? false)
        XCTAssertFalse(sensitiveAccount.lastFailureCode?.localizedCaseInsensitiveContains("REDACTED_PLACEHOLDER") ?? false)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("secretVersionName"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("REDACTED_PLACEHOLDER"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("Bearer "))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("credentialHandle"))
        XCTAssertTrue(encoded.contains("Personal"))
    }

    func test_providerLevelTotalsRemainSeparateFromAccountRoutingHealth() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let providerSnapshot = ProviderQuotaSnapshot(
            id: "openai_provider_total",
            provider: "openai",
            providerID: .openAI,
            accountID: nil,
            accountLabel: nil,
            sourceKind: .provider,
            sourceId: "rollup",
            fetchedAt: now,
            source: "OpenAI",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(name: "monthly", used: 100_000, limit: 1_000_000, remaining: 900_000)
            ],
            updatedAt: now
        )
        let accountCandidate = routingCandidate("work", label: "Work", quotaState: .exhausted)

        XCTAssertNil(providerSnapshot.accountID)
        XCTAssertEqual(accountCandidate.quotaState, .exhausted)
        XCTAssertEqual(providerSnapshot.buckets.first?.remaining, 900_000)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func routingCandidate(
        _ accountID: String,
        providerID: ProviderID = .openAI,
        label: String,
        credentialHandle: String = "keychain-slot",
        quotaState: ProviderRoutingQuotaState = .healthy,
        cooldownUntil: Date? = nil,
        priority: Int = 0,
        canonicalModelID: String? = nil,
        lastUsedAt: Date? = nil,
        lastFailureCode: String? = nil,
        localCredentialAvailable: Bool = true
    ) -> ProviderRoutingCandidate {
        ProviderRoutingCandidate(
            providerID: providerID,
            accountID: accountID,
            accountLabel: label,
            credentialHandle: credentialHandle,
            storageScope: .deviceKeychain,
            modelCompatibility: .compatible,
            canonicalModelID: canonicalModelID,
            quotaState: quotaState,
            cooldownUntil: cooldownUntil,
            priority: priority,
            routingEnabled: true,
            lastUsedAt: lastUsedAt,
            lastFailureCode: lastFailureCode,
            localCredentialAvailable: localCredentialAvailable
        )
    }
}
