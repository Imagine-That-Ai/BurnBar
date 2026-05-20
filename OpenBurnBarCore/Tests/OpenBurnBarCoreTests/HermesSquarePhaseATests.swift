import XCTest
@testable import OpenBurnBarCore

// MARK: - Hermes Square Phase A Tests
//
// Covers the pure-logic seams from plan §6.1–§6.4 + §6.2:
//   • `AgentIdentity` URI + manifest bridge
//   • `AgentManifest` validation + JSON round-trip
//   • `CardEnvelope` union round-trip + 2 MB budget gate
//   • `PinnedAgentGridConfig` sanitisation + pin/unpin/move
//   • `MissionGroupContracts` forecast aggregation + phase reducer
//   • `PersonaScopeEnvelope` round-trip
//   • `UnifiedSearchIndex` recency-boosted ranking

final class HermesSquareAgentIdentityTests: XCTestCase {

    func testBuiltInURIRoundTrip() {
        for runtime in AssistantRuntimeID.allCases {
            let uri = AgentIdentity.builtInURI(runtime)
            XCTAssertTrue(uri.hasPrefix("agent://burnbar/"))
            XCTAssertEqual(AgentIdentity.builtInRuntime(from: uri), runtime)
        }
        XCTAssertNil(AgentIdentity.builtInRuntime(from: "agent://third-party/foo/bar"))
        XCTAssertNil(AgentIdentity.builtInRuntime(from: "https://example.com"))
    }

    func testDefaultBuiltInsHasOneEntryPerRuntime() {
        let defaults = AgentIdentity.defaultBuiltIns
        XCTAssertEqual(defaults.count, AssistantRuntimeID.allCases.count)
        let runtimes = defaults.compactMap(\.runtimeID)
        XCTAssertEqual(Set(runtimes), Set(AssistantRuntimeID.allCases))
    }

    func testBuiltInClaudeDeclaresMacRelayAndCLICapabilities() {
        let claude = AgentIdentity.builtIn(.claude)
        XCTAssertEqual(claude.runtimeID, .claude)
        if case .macRelay(let runtime) = claude.dispatchTransport {
            XCTAssertEqual(runtime, "claude")
        } else {
            XCTFail("Claude built-in must use mac-relay dispatch transport")
        }
        XCTAssertTrue(claude.capabilities.contains(.fileEdits))
        XCTAssertTrue(claude.capabilities.contains(.shell))
        XCTAssertTrue(claude.capabilities.contains(.mcpUI))
    }

    func testAgentCapabilitiesDisplayPillsAreStable() {
        let caps: AgentCapabilities = [.toolUse, .fileEdits, .vision]
        XCTAssertEqual(caps.displayPills, ["Tool use", "Vision", "File edits"])
    }

    func testCodableRoundTripPreservesAllFields() throws {
        let identity = AgentIdentity(
            id: "agent://third-party/foo/research-scout",
            displayName: "Research Scout",
            glyph: "🔭",
            paletteHex: "AABBCC",
            tier: .subscription,
            availability: .online,
            installSource: .userInstalled(manifestURL: "https://example.com/manifest.json"),
            capabilities: [.toolUse, .webBrowse],
            dispatchTransport: .httpGateway(endpoint: "https://example.com/dispatch"),
            personas: [.defaultPersona],
            lastSevenDays: AgentRecentStats(threadCount: 3, missionCount: 2, burnUSD: 1.23, successRate: 0.9),
            lastRefreshedAt: Date(timeIntervalSince1970: 1_000_000),
            tagline: "Reads the web so you don't have to."
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(identity)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentIdentity.self, from: data)
        XCTAssertEqual(decoded, identity)
    }
}

final class HermesSquareAgentManifestTests: XCTestCase {

    private func validManifest() -> AgentManifest {
        AgentManifest(
            agentURI: "agent://third-party/foo/scout",
            displayName: "Scout",
            tagline: "Reads.",
            glyph: "🔭",
            paletteHex: "00A67E",
            tier: .service,
            capabilities: [.toolUse],
            dispatchTransport: .httpGateway(endpoint: "https://example.com/x"),
            author: AgentManifest.Author(name: "Foo Co"),
            requiredScopes: [
                AgentManifest.Scope(id: "files:read", displayName: "Read files", justification: "Searches your repo.")
            ],
            cardSurfaces: [AgentManifest.CardSurface(kind: "text")]
        )
    }

    func testValidManifestPasses() throws {
        XCTAssertNoThrow(try validManifest().validate())
    }

    func testManifestRejectsInvalidURI() {
        var m = validManifest()
        m = AgentManifest(
            manifestVersion: m.manifestVersion,
            agentURI: "https://not-an-agent-uri",
            displayName: m.displayName, tagline: m.tagline, glyph: m.glyph, paletteHex: m.paletteHex,
            tier: m.tier, capabilities: m.capabilities, dispatchTransport: m.dispatchTransport,
            author: m.author, requiredScopes: m.requiredScopes, cardSurfaces: m.cardSurfaces
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case AgentManifest.ValidationError.invalidURI = error else {
                XCTFail("Expected invalidURI; got \(error)")
                return
            }
        }
    }

    func testManifestRejectsUnsupportedCardKind() {
        var m = validManifest()
        m = AgentManifest(
            manifestVersion: m.manifestVersion,
            agentURI: m.agentURI, displayName: m.displayName, tagline: m.tagline, glyph: m.glyph,
            paletteHex: m.paletteHex, tier: m.tier, capabilities: m.capabilities,
            dispatchTransport: m.dispatchTransport, author: m.author,
            requiredScopes: m.requiredScopes,
            cardSurfaces: [AgentManifest.CardSurface(kind: "definitely-not-a-card")]
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case AgentManifest.ValidationError.unsupportedCardKind = error else {
                XCTFail("Expected unsupportedCardKind; got \(error)")
                return
            }
        }
    }

    func testManifestRejectsSubscriptionWithoutTopics() {
        var m = validManifest()
        m = AgentManifest(
            manifestVersion: m.manifestVersion, agentURI: m.agentURI,
            displayName: m.displayName, tagline: m.tagline, glyph: m.glyph,
            paletteHex: m.paletteHex, tier: .subscription, capabilities: m.capabilities,
            dispatchTransport: m.dispatchTransport, author: m.author,
            requiredScopes: m.requiredScopes, cardSurfaces: m.cardSurfaces,
            pushTopics: []
        )
        XCTAssertThrowsError(try m.validate()) { error in
            guard case AgentManifest.ValidationError.subscriptionWithoutTopics = error else {
                XCTFail("Expected subscriptionWithoutTopics; got \(error)")
                return
            }
        }
    }

    func testSizeDeclarationOverBudgetRejected() {
        var m = validManifest()
        m = AgentManifest(
            manifestVersion: m.manifestVersion, agentURI: m.agentURI,
            displayName: m.displayName, tagline: m.tagline, glyph: m.glyph,
            paletteHex: m.paletteHex, tier: m.tier, capabilities: m.capabilities,
            dispatchTransport: m.dispatchTransport, author: m.author,
            requiredScopes: m.requiredScopes, cardSurfaces: m.cardSurfaces,
            sizeDeclarations: AgentManifest.SizeDeclarations(
                manifestBytes: 999_999,
                totalPackageBytes: 1_000,
                perCardMaxBytes: 1_000
            )
        )
        XCTAssertThrowsError(try m.validate())
    }

    func testIdentityFromManifestPreservesFields() throws {
        let m = validManifest()
        let identity = AgentIdentity(fromManifest: m, installSource: .userInstalled(manifestURL: m.agentURI))
        XCTAssertEqual(identity.id, m.agentURI)
        XCTAssertEqual(identity.displayName, m.displayName)
        XCTAssertEqual(identity.tier, m.tier)
        if case .userInstalled = identity.installSource {
            // ok
        } else {
            XCTFail("Expected userInstalled install source")
        }
    }
}

final class HermesSquareCardEnvelopeTests: XCTestCase {

    func testTextEnvelopeRoundTrip() throws {
        let envelope = CardEnvelope.text(CardText(markdown: "**Hi**", footnote: "fn"))
        let data = try envelope.toJSON()
        let decoded = CardEnvelope.fromJSON(data)
        if case .text(let payload) = decoded {
            XCTAssertEqual(payload.markdown, "**Hi**")
            XCTAssertEqual(payload.footnote, "fn")
        } else {
            XCTFail("Round-trip should preserve text variant")
        }
    }

    func testApprovalEnvelopeRoundTripPreservesOptionKinds() throws {
        let envelope = CardEnvelope.approval(CardApproval(
            prompt: "Run pnpm test?",
            detail: "Tests take ~1 min.",
            options: [
                CardApproval.Option(id: "approve", label: "Approve", kind: .primary),
                CardApproval.Option(id: "deny", label: "Deny", kind: .destructive)
            ],
            correlationID: "abc"
        ))
        let data = try envelope.toJSON()
        let decoded = CardEnvelope.fromJSON(data)
        if case .approval(let payload) = decoded {
            XCTAssertEqual(payload.options.count, 2)
            XCTAssertEqual(payload.options[0].kind, .primary)
            XCTAssertEqual(payload.options[1].kind, .destructive)
            XCTAssertEqual(payload.correlationID, "abc")
        } else {
            XCTFail("Round-trip should preserve approval variant")
        }
    }

    func testOverBudgetPayloadCollapsesToTooLargeStub() {
        // 3 MB blob — well past the 2 MB cap.
        let huge = String(repeating: "x", count: 3_000_000)
        let envelope = CardEnvelope.text(CardText(markdown: huge))
        let data = try? envelope.toJSON()
        XCTAssertNotNil(data)
        let decoded = CardEnvelope.fromJSON(data ?? Data())
        if case .tooLarge(let stub) = decoded {
            XCTAssertEqual(stub.kindAttempted, "text")
            XCTAssertGreaterThan(stub.attemptedBytes, CardEnvelope.maxPayloadBytes)
        } else {
            XCTFail("Over-budget payload should collapse to tooLarge stub, got \(decoded)")
        }
    }

    func testUnknownKindFallsThroughToUnknown() {
        let raw = #"{"kind":"definitely-not-a-card","label":"weird"}"#.data(using: .utf8)!
        let decoded = CardEnvelope.fromJSON(raw)
        if case .unknown(let label) = decoded {
            XCTAssertEqual(label, "weird")
        } else {
            XCTFail("Expected unknown(label)")
        }
    }
}

final class HermesSquarePinnedGridTests: XCTestCase {

    func testDefaultPinsAllFiveBuiltIns() {
        let config = PinnedAgentGridConfig.default
        XCTAssertEqual(config.pinnedURIs.count, AssistantRuntimeID.allCases.count)
    }

    func testSanitiseRemovesDuplicatesAndCapsAt12() {
        var pins = (0..<20).map { "agent://burnbar/dup-\($0)" }
        pins.insert("agent://burnbar/dup-0", at: 1) // duplicate
        let config = PinnedAgentGridConfig(pinnedURIs: pins).sanitized()
        XCTAssertEqual(config.pinnedURIs.count, PinnedAgentGridConfig.maxSlots)
        XCTAssertEqual(Set(config.pinnedURIs).count, config.pinnedURIs.count)
    }

    func testPinAndUnpinAreIdempotent() {
        let start = PinnedAgentGridConfig(pinnedURIs: [])
        let after = start.pinning("agent://burnbar/a").pinning("agent://burnbar/a").pinning("agent://burnbar/b")
        XCTAssertEqual(after.pinnedURIs, ["agent://burnbar/a", "agent://burnbar/b"])
        let undone = after.unpinning("agent://burnbar/a")
        XCTAssertEqual(undone.pinnedURIs, ["agent://burnbar/b"])
    }

    func testMoveReordersWithoutLoss() {
        let config = PinnedAgentGridConfig(pinnedURIs: ["a", "b", "c", "d"])
        let moved = config.moving(from: 0, to: 3)
        XCTAssertEqual(moved.pinnedURIs, ["b", "c", "d", "a"])
    }

    func testPairedMacPinIsVisibleEvenWhenGridIsFull() {
        let full = PinnedAgentGridConfig(
            pinnedURIs: (0..<PinnedAgentGridConfig.maxSlots).map { "agent://test/\($0)" }
        )
        let pinned = full.pinningPairedMac("device://paired-mac/relay-live")

        XCTAssertEqual(pinned.pinnedURIs.count, PinnedAgentGridConfig.maxSlots)
        XCTAssertEqual(pinned.pinnedURIs.first, "device://paired-mac/relay-live")
        XCTAssertFalse(pinned.pinnedURIs.contains("agent://test/11"))
    }

    func testJSONRoundTripPreservesOrderAndDisplayMode() {
        let config = PinnedAgentGridConfig(
            pinnedURIs: ["a", "b", "c"],
            displayMode: .compact,
            lastRearrangedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let raw = config.jsonString()
        let decoded = PinnedAgentGridConfig.from(jsonString: raw)
        XCTAssertEqual(decoded.pinnedURIs, ["a", "b", "c"])
        XCTAssertEqual(decoded.displayMode, .compact)
    }
}

final class HermesSquareMissionGroupTests: XCTestCase {

    func testForecastAggregationSumsTokensAndCostMaxesETA() {
        let a = MissionConsoleForecast(
            tokensLow: 1_000, tokensHigh: 2_000,
            costLowUSD: 0.1, costHighUSD: 0.2,
            etaLow: 60, etaHigh: 120
        )
        let b = MissionConsoleForecast(
            tokensLow: 3_000, tokensHigh: 4_000,
            costLowUSD: 0.3, costHighUSD: 0.4,
            etaLow: 200, etaHigh: 300
        )
        let aggregated = MissionGroupForecastComputer.combine(children: [a, b], parallelismLimit: 2)
        XCTAssertEqual(aggregated.tokensLow, 4_000)
        XCTAssertEqual(aggregated.tokensHigh, 6_000)
        XCTAssertEqual(aggregated.costLowUSD, 0.4, accuracy: 1e-6)
        XCTAssertEqual(aggregated.costHighUSD, 0.6, accuracy: 1e-6)
        // ETA-low: max(60, 200) = 200; sum/2 = 130 → max wins.
        XCTAssertEqual(aggregated.etaLow, 200, accuracy: 0.01)
    }

    func testPhaseReducerAllTerminalGoesToAwaitingMerge() {
        let phase = MissionGroupPhaseReducer.reduce(
            childStatuses: ["completed", "completed", "completed"]
        )
        XCTAssertEqual(phase, .awaitingMerge)
    }

    func testPhaseReducerAllFailedGoesToFailed() {
        let phase = MissionGroupPhaseReducer.reduce(childStatuses: ["failed", "failed"])
        XCTAssertEqual(phase, .failed)
    }

    func testPhaseReducerAnyLiveGoesToFanningOut() {
        let phase = MissionGroupPhaseReducer.reduce(
            childStatuses: ["completed", "running", "queued"]
        )
        XCTAssertEqual(phase, .fanningOut)
    }

    func testGroupDocumentRoundTripsThroughFirestorePayload() {
        let payload = MissionGroupPayloadFactory.buildGroupPayload(
            id: "group-1",
            title: "Try three runtimes",
            prompt: "Refactor router rails.",
            missionKind: "modernization",
            targetProject: "/repo",
            childMissionIDs: ["m1", "m2", "m3"],
            runtimeTokens: ["claude", "codex", "hermes"],
            parallelismLimit: 3,
            mergeStrategy: .pickOne,
            forecast: MissionGroupDocument.ForecastBand(
                tokensLow: 1, tokensHigh: 2,
                costLowUSD: 0.01, costHighUSD: 0.02,
                etaLow: 1, etaHigh: 2
            )
        )
        let decoded = MissionGroupDocument(documentID: "group-1", data: payload)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.childMissionIDs, ["m1", "m2", "m3"])
        XCTAssertEqual(decoded?.runtimeTokens, ["claude", "codex", "hermes"])
        XCTAssertEqual(decoded?.mergeStrategy, .pickOne)
        XCTAssertEqual(decoded?.phase, .queued)
    }

    func testChildPayloadOverlayContainsGroupHints() {
        let overlay = MissionGroupPayloadFactory.childPayloadOverlay(
            groupID: "g1",
            siblingIndex: 1,
            siblingCount: 3
        )
        XCTAssertEqual(overlay["groupID"] as? String, "g1")
        XCTAssertEqual(overlay["siblingIndex"] as? Int, 1)
        XCTAssertEqual(overlay["siblingCount"] as? Int, 3)
        XCTAssertEqual(overlay["isGroupChild"] as? Bool, true)
    }
}

final class HermesSquarePersonaScopeTests: XCTestCase {

    func testEnvelopeBuildsFromPersonaPreservingAllFields() {
        let envelope = PersonaScopeEnvelope(
            persona: .techReviewer,
            agentURI: AgentIdentity.builtInURI(.claude),
            appliedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(envelope.agentURI, AgentIdentity.builtInURI(.claude))
        XCTAssertEqual(envelope.personaID, AgentPersona.techReviewer.id)
        XCTAssertEqual(envelope.permitShell, false)
        XCTAssertEqual(envelope.permitFileEdits, false)
        XCTAssertTrue(envelope.permittedTools.contains("read_file"))
    }

    func testJSONRoundTripIsLossless() throws {
        // Use a date that's already at whole-second precision so the
        // ISO-8601 round-trip doesn't lose sub-second precision.
        let stableDate = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/claude",
            personaID: "tech-reviewer",
            systemPromptAdditions: "Be terse.",
            permittedTools: ["read_file"],
            permittedFileGlobs: ["src/**"],
            permittedShellPrefixes: ["git diff"],
            permitShell: true,
            permitFileEdits: false,
            temperatureOverride: 0.2,
            preferredModel: "claude-sonnet-4-6",
            appliedAt: stableDate
        )
        let raw = try envelope.jsonString()
        let decoded = try PersonaScopeEnvelope.from(jsonString: raw)
        XCTAssertEqual(decoded.agentURI, envelope.agentURI)
        XCTAssertEqual(decoded.personaID, envelope.personaID)
        XCTAssertEqual(decoded.systemPromptAdditions, envelope.systemPromptAdditions)
        XCTAssertEqual(decoded.permittedTools, envelope.permittedTools)
        XCTAssertEqual(decoded.permittedFileGlobs, envelope.permittedFileGlobs)
        XCTAssertEqual(decoded.permittedShellPrefixes, envelope.permittedShellPrefixes)
        XCTAssertEqual(decoded.permitShell, envelope.permitShell)
        XCTAssertEqual(decoded.permitFileEdits, envelope.permitFileEdits)
        XCTAssertEqual(decoded.temperatureOverride, envelope.temperatureOverride)
        XCTAssertEqual(decoded.preferredModel, envelope.preferredModel)
        XCTAssertEqual(decoded.appliedAt, envelope.appliedAt)
    }
}

final class HermesSquareUnifiedSearchTests: XCTestCase {

    func testTokenizerStripsNonAlphanumAndFolds() {
        let tokens = UnifiedSearchIndex.tokenize("Hello, Wörld! 42-times.")
        XCTAssertEqual(tokens, ["hello", "world", "42", "times"])
    }

    func testTokenizerDropsSingleChars() {
        let tokens = UnifiedSearchIndex.tokenize("a quick brown fox")
        XCTAssertEqual(tokens, ["quick", "brown", "fox"])
    }

    func testIndexFindsExactMatchAndRanksByScore() async {
        let index = UnifiedSearchIndex()
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)

        await index.upsert(UnifiedSearchIndex.Document(
            ref: .init(corpus: .agents, id: "agent://burnbar/claude"),
            title: "Claude",
            body: "Anthropic Claude Code via your Mac",
            lastActivityAt: now
        ))
        await index.upsert(UnifiedSearchIndex.Document(
            ref: .init(corpus: .agents, id: "agent://burnbar/codex"),
            title: "Codex",
            body: "OpenAI Codex via your Mac",
            lastActivityAt: yesterday
        ))
        await index.upsert(UnifiedSearchIndex.Document(
            ref: .init(corpus: .threads, id: "thread-1"),
            title: "Claude refactor pass",
            body: "Refactoring the router rails with Claude.",
            lastActivityAt: now
        ))

        let hits = await index.search("claude")
        XCTAssertNotNil(hits[.agents])
        XCTAssertNotNil(hits[.threads])
        XCTAssertEqual(hits[.agents]?.first?.ref.id, "agent://burnbar/claude")
        XCTAssertGreaterThan(hits[.agents]?.first?.score ?? 0, 0)
    }

    func testRecencyBoostsMoreRecent() async {
        let index = UnifiedSearchIndex()
        let now = Date()
        let monthAgo = now.addingTimeInterval(-30 * 86_400)

        await index.upsert(UnifiedSearchIndex.Document(
            ref: .init(corpus: .threads, id: "old"),
            title: "Refactor",
            body: "Refactor pass",
            lastActivityAt: monthAgo
        ))
        await index.upsert(UnifiedSearchIndex.Document(
            ref: .init(corpus: .threads, id: "fresh"),
            title: "Refactor",
            body: "Refactor pass",
            lastActivityAt: now
        ))

        let hits = await index.searchFlat("refactor", limit: 5)
        XCTAssertEqual(hits.first?.ref.id, "fresh")
    }

    func testFlatSearchReturnsTopHitsAcrossCorpuses() async {
        let index = UnifiedSearchIndex()
        let now = Date()
        await index.upsert(.from(AgentIdentity.builtIn(.claude)))
        await index.upsert(UnifiedSearchIndex.Document(
            ref: .init(corpus: .threads, id: "t-1"),
            title: "Claude session",
            body: "Sessions with Claude",
            lastActivityAt: now
        ))
        let hits = await index.searchFlat("claude", limit: 10)
        XCTAssertGreaterThanOrEqual(hits.count, 2)
        XCTAssertTrue(hits.contains { $0.ref.corpus == .agents })
        XCTAssertTrue(hits.contains { $0.ref.corpus == .threads })
    }
}

final class HermesSquareFeatureFlagsTests: XCTestCase {

    @MainActor
    func testDefaultsAreAllOff() {
        // Use the test seed to avoid touching real UserDefaults.
        let flags = HermesSquareFeatureFlags.offline()
        XCTAssertFalse(flags.phaseA)
        XCTAssertFalse(flags.phaseB)
        XCTAssertFalse(flags.phaseC)
        XCTAssertFalse(flags.phaseD)
        XCTAssertFalse(flags.anyPhaseEnabled)
    }

    @MainActor
    func testPhaseATogglePersistsAndReadsBack() {
        let flags = HermesSquareFeatureFlags.phaseAOnly()
        XCTAssertTrue(flags.phaseA)
        XCTAssertTrue(flags.anyPhaseEnabled)
    }

    @MainActor
    func testResetAllClearsEverything() {
        let flags = HermesSquareFeatureFlags.phaseAOnly()
        flags.phaseB = true
        flags.phaseC = true
        flags.phaseD = true
        flags.resetAll()
        XCTAssertFalse(flags.phaseA)
        XCTAssertFalse(flags.phaseB)
        XCTAssertFalse(flags.phaseC)
        XCTAssertFalse(flags.phaseD)
    }
}

final class HermesSquareThreadInboxItemTests: XCTestCase {

    func testSortPutsNeedsAttentionFirstThenByRecency() {
        let now = Date()
        let items: [ThreadInboxItem] = [
            ThreadInboxItem(
                id: "a", agentURI: AgentIdentity.builtInURI(.hermes),
                title: "Old", preview: "—", lastActivityAt: now.addingTimeInterval(-100),
                source: .hermes
            ),
            ThreadInboxItem(
                id: "b", agentURI: AgentIdentity.builtInURI(.pi),
                title: "Recent", preview: "—", lastActivityAt: now,
                source: .pi
            ),
            ThreadInboxItem(
                id: "c", agentURI: AgentIdentity.builtInURI(.claude),
                title: "Attention", preview: "—", lastActivityAt: now.addingTimeInterval(-200),
                needsAttention: true, source: .missionGroup
            )
        ]
        let sorted = items.sortedForInbox()
        XCTAssertEqual(sorted.map(\.id), ["c", "b", "a"])
    }

    func testSplitForInboxSegmentsSubscriptionPostsOnly() {
        let now = Date()
        let items: [ThreadInboxItem] = [
            ThreadInboxItem(id: "1", agentURI: "agent://x/a", title: "T", preview: "P",
                            lastActivityAt: now, source: .hermes),
            ThreadInboxItem(id: "2", agentURI: "agent://x/b", title: "T", preview: "P",
                            lastActivityAt: now, source: .subscriptionPost),
            ThreadInboxItem(id: "3", agentURI: "agent://x/c", title: "T", preview: "P",
                            lastActivityAt: now, source: .cliMirror)
        ]
        let (service, subscription) = items.splitForInbox()
        XCTAssertEqual(Set(service.map(\.id)), ["1", "3"])
        XCTAssertEqual(subscription.map(\.id), ["2"])
    }
}
