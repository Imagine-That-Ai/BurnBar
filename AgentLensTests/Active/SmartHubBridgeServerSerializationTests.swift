import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SmartHubBridgeServerSerializationTests: XCTestCase {

    override func tearDown() async throws {
        // Reset shared state so subsequent tests start clean.
        SmartHubBridgeServer.shared.resetVoiceRefreshForTesting()
        SmartHubBridgeServer.shared.updateDisplayConfig(.default)
        SmartHubBridgeServer.shared.updateSnapshot(.empty)
        try await super.tearDown()
    }

    func test_renderPageUsesBurnBarLogoInTopLeftBrandSlot() throws {
        XCTAssertTrue(SmartHubBridgePage.html.contains(#"class="brand-logo" src="/brand-logo.svg" alt="OpenBurnBar""#))
        XCTAssertFalse(SmartHubBridgePage.html.contains(#"class="mark" aria-hidden="true""#))
        XCTAssertTrue(SmartHubBridgePage.brandLogoSVG.contains("<svg"))
        XCTAssertTrue(SmartHubBridgePage.brandLogoSVG.contains("#FEA41C"))
    }

    func test_renderPageDoesNotFallbackToCurrencyInTokenMode() throws {
        XCTAssertTrue(
            SmartHubBridgePage.html.contains(#": (p.tokenTotal || '');"#),
            "Token mode must not render tokenTotalCurrency under a TOKENS label."
        )
        XCTAssertFalse(
            SmartHubBridgePage.html.contains(#": (p.tokenTotal || p.tokenTotalCurrency || '');"#),
            "The old fallback showed dollar values while the card label said TOKENS."
        )
    }

    func test_renderPageLetsScreenSwipeScrollProviderRail() throws {
        XCTAssertTrue(
            SmartHubBridgePage.html.contains(#"stageEl.addEventListener('pointerdown'"#),
            "Smart Hub should translate screen-level swipes into provider rail movement."
        )
        XCTAssertTrue(
            SmartHubBridgePage.html.contains(#"stageEl.addEventListener('touchstart'"#),
            "Cast-style touch browsers need touch listeners even when pointer APIs exist."
        )
        XCTAssertTrue(
            SmartHubBridgePage.html.contains(#"window.addEventListener('touchmove'"#),
            "Touch drags should continue to move the rail after leaving the original target."
        )
        XCTAssertTrue(
            SmartHubBridgePage.html.contains("touch-action: pan-y"),
            "Horizontal swipes must be reserved for the Smart Hub provider rail handler."
        )
        XCTAssertTrue(
            SmartHubBridgePage.html.contains(#"providersEl.scrollLeft += step;"#),
            "Swipe deltas should move the provider rail horizontally."
        )
        XCTAssertTrue(
            SmartHubBridgePage.html.contains("suppressNextCardClick"),
            "Dragging a provider card should not accidentally open the detail overlay."
        )
    }

    func test_renderPageCarriesBridgeTokenToPollingAndMutationRequests() throws {
        XCTAssertTrue(SmartHubBridgePage.html.contains("const bridgeToken = new URLSearchParams"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("function bridgePath(path)"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("fetch(bridgePath('/state.json')"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("fetch(bridgePath('/period?p=' + encodeURIComponent(value))"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("fetch(bridgePath('/refresh')"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("fetch(bridgePath('/voice-refresh')"))
    }

    func test_renderPageConsumesQueuedVoiceEvents() throws {
        XCTAssertTrue(SmartHubBridgePage.html.contains("function handleVoiceEvent(voice)"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("handleVoiceEvent(state.voice)"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("const pageLoadedAt = Date.now()"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("voice.queuedAt || voice.requestedAt"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("new SpeechSynthesisUtterance(message)"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("utterance.onerror = () =>"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("stageEl.classList.add('voice-pulse')"))
    }

    func test_renderPagePostsIdentifyVoiceOnlyOnRefreshCompletion() throws {
        XCTAssertTrue(SmartHubBridgePage.html.contains("let lastRefreshingState = false"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("function triggerIdentifyVoice()"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("if (identifyOnRefresh && lastRefreshingState && !isRefreshing)"))
        XCTAssertTrue(SmartHubBridgePage.html.contains("let identifyVoiceInFlight = false"))
    }

    func test_bridgeSecuredURLCarriesRuntimeAccessTokenWithoutDroppingExistingQuery() throws {
        let raw = try XCTUnwrap(URL(string: "http://127.0.0.1:8787/render.html?display=nest"))
        let secured = SmartHubBridgeServer.shared.securedBridgeURL(raw)
        let components = try XCTUnwrap(URLComponents(url: secured, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/render.html")
        XCTAssertEqual(query["display"], "nest")
        XCTAssertEqual(query["bridgeToken"], SmartHubBridgeServer.shared.bridgeAccessToken)
        XCTAssertFalse(SmartHubBridgeServer.shared.bridgeAccessToken.isEmpty)
    }

    func test_controllerPersistsBridgeURLsWithRuntimeAccessToken() throws {
        let suiteName = "SmartHubBridgeControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        let controller = SmartHubBridgeController(settingsManager: settings, quotaService: nil)
        let staleTokenURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:8787/render.html?display=nest&bridgeToken=stale")
        )

        controller.persistPublishedBridgeURLsForTesting(dashboardURL: staleTokenURL)

        try assertPersistedBridgeURL(settings.smartHubQuotaDashboardURL, path: "/render.html")
        try assertPersistedBridgeURL(settings.smartHubQuotaRefreshURL, path: "/refresh")
        try assertPersistedBridgeURL(settings.smartHubQuotaVoiceRefreshURL, path: "/voice-refresh")
    }

    func test_runCostTotalsCacheDeduplicatesPeriodsAndReusesSameBucket() async {
        let cache = SmartHubRunCostTotalsCache()
        let now = Date(timeIntervalSince1970: 120)
        var loadedBatches: [[SmartHubTimePeriod]] = []

        let first = await cache.values(
            for: [.rolling5h, .rolling5h, .rolling7d],
            writeMarker: 41,
            now: now
        ) { periods in
            loadedBatches.append(periods)
            return Dictionary(
                uniqueKeysWithValues: periods.map { period in
                    (
                        period.rawValue,
                        [
                            .claudeCode: ProviderRunCostTotals(
                                sessionCount: Int(period.spanHours),
                                totalTokens: 100,
                                totalCost: 1
                            )
                        ]
                    )
                }
            )
        }
        let second = await cache.values(
            for: [.rolling7d, .rolling5h],
            writeMarker: 41,
            now: now.addingTimeInterval(10)
        ) { periods in
            loadedBatches.append(periods)
            return [:]
        }

        XCTAssertEqual(loadedBatches, [[.rolling5h, .rolling7d]])
        XCTAssertEqual(first, second)
    }

    func test_runCostTotalsCacheInvalidatesWhenUsageTableChanges() async {
        let cache = SmartHubRunCostTotalsCache()
        let now = Date(timeIntervalSince1970: 120)
        var loadCount = 0

        for writeMarker in [41, 42] {
            _ = await cache.values(
                for: [.rolling5h],
                writeMarker: writeMarker,
                now: now
            ) { periods in
                XCTAssertEqual(periods, [.rolling5h])
                loadCount += 1
                return [:]
            }
        }

        XCTAssertEqual(loadCount, 2)
    }

    func test_runCostTotalsCacheInvalidatesAtSixtySecondBoundary() async {
        let cache = SmartHubRunCostTotalsCache()
        var loadCount = 0

        for now in [
            Date(timeIntervalSince1970: 179.9),
            Date(timeIntervalSince1970: 180)
        ] {
            _ = await cache.values(
                for: [.rolling5h],
                writeMarker: 41,
                now: now
            ) { periods in
                XCTAssertEqual(periods, [.rolling5h])
                loadCount += 1
                return [:]
            }
        }

        XCTAssertEqual(loadCount, 2)
    }

    func testRedactedBridgeURLRemovesAccessToken() throws {
        let raw = URL(string: "http://127.0.0.1:8787/render.html?bridgeToken=secret&x=1")!
        let redacted = SmartHubBridgeServer.shared.redactedBridgeURL(raw)
        let query = try XCTUnwrap(URLComponents(url: redacted, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertNil(query.first { $0.name == "bridgeToken" })
        XCTAssertEqual(query.first { $0.name == "x" }?.value, "1")
    }

    func test_bridgeAuthorizationRequiresRuntimeAccessToken() throws {
        let token = SmartHubBridgeServer.shared.bridgeAccessToken

        XCTAssertFalse(SmartHubBridgeServer.shared.isAuthorizedBridgeRequestForTesting(path: "/state.json"))
        XCTAssertFalse(
            SmartHubBridgeServer.shared.isAuthorizedBridgeRequestForTesting(
                path: "/state.json?bridgeToken=wrong"
            )
        )
        XCTAssertTrue(
            SmartHubBridgeServer.shared.isAuthorizedBridgeRequestForTesting(
                path: "/state.json?bridgeToken=\(token)"
            )
        )
        XCTAssertTrue(
            SmartHubBridgeServer.shared.isAuthorizedBridgeRequestForTesting(
                path: "/state.json",
                authorizationHeader: "Bearer \(token)"
            )
        )
    }

    func test_jsonResponsesDoNotExposeWildcardCORS() throws {
        let header = SmartHubBridgeServer.shared.renderJSONHeaderForTesting(contentLength: 2)
        XCTAssertFalse(header.contains("Access-Control-Allow-Origin: *"))
        XCTAssertTrue(header.contains("Cache-Control: no-store"))
    }

    func test_stateJSONContainsDisplayBlockWithPaletteAndTheme() throws {
        var config = SmartHubDisplayConfig.default
        config.palette = .mercury
        config.theme = .botanicalCream
        config.brightness = 0.7
        config.refreshCadenceSeconds = 12
        config.audibleCue = true
        SmartHubBridgeServer.shared.updateDisplayConfig(config)

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"palette\": \"mercury\""))
        XCTAssertTrue(json.contains("\"theme\": \"botanicalCream\""))
        XCTAssertTrue(json.contains("\"brightness\": 0.7"))
        XCTAssertTrue(json.contains("\"refreshCadenceSeconds\": 12"))
        XCTAssertTrue(json.contains("\"audibleCue\": true"))
    }

    func test_voiceRefreshQueuesAnnouncementInStateJSON() throws {
        let provider = SmartHubBridgeSnapshot.Provider(
            name: "Claude Code",
            percent: 42,
            label: "$120 / $300",
            tone: .warning,
            windowLabel: "5h",
            slug: "claudecode",
            tokenTotal: "5.4B",
            tokenTotalCurrency: "$12.40",
            buckets: [
                .init(
                    name: "5-hour limit",
                    percent: 42,
                    headlineValue: "42%",
                    subLabel: "58% left",
                    resetsLabel: "Resets in 2h",
                    tone: .warning,
                    isCreditBalance: false
                )
            ],
            runsLabel: "14 runs",
            costLabel: "$12.40"
        )
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$12.40",
                headline: "Showing last 5 hours",
                subheadline: "Updated at 9:42 PM",
                providers: [provider]
            )
        )

        let response = SmartHubBridgeServer.shared.queueVoiceRefreshForTesting()
        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()

        XCTAssertTrue(response.contains(#""ok":true"#))
        XCTAssertTrue(response.contains(#""voice":"queued""#))
        XCTAssertTrue(response.contains(#""target":"bridge-page""#))
        XCTAssertTrue(response.contains(#""eventId":1"#))
        XCTAssertTrue(response.contains(#""message":"OpenBurnBar last 5 hours."#))
        XCTAssertTrue(response.contains(#""queuedAt":"#))
        XCTAssertTrue(response.contains(#""requestedAt":"#))
        XCTAssertTrue(json.contains(#""voice": {"#))
        XCTAssertTrue(json.contains(#""eventId": 1"#))
        XCTAssertTrue(json.contains(#""queuedAt": "#))
        XCTAssertFalse(json.contains("\"queuedAt\": \"\""))
        XCTAssertTrue(json.contains("OpenBurnBar last 5 hours."))
        XCTAssertTrue(json.contains("Claude Code is at 42%. Resets in 2h"))
    }

    func test_voiceRefreshSharedQueueReturnsActionPayloadDetails() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Showing last 5 hours",
                subheadline: "Updated now",
                providers: []
            )
        )
        let versionBeforeVoice = SmartHubBridgeServer.shared.refreshVersion

        let event = SmartHubBridgeServer.shared.queueVoiceRefresh()

        XCTAssertEqual(event.eventId, 1)
        XCTAssertEqual(event.target, "bridge-page")
        XCTAssertEqual(event.status, "queued")
        XCTAssertEqual(event.dashboardVersion, versionBeforeVoice)
        XCTAssertTrue(event.message.contains("OpenBurnBar is waiting for provider quota data."))
        XCTAssertEqual(SmartHubBridgeServer.shared.lastVoiceRefreshMessage, event.message)
        XCTAssertEqual(SmartHubBridgeServer.shared.lastVoiceRefreshAt, Optional(event.requestedAt))
    }

    func test_voiceRefreshCoalescesDuplicateAnnouncementWithinDebounceWindow() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Showing last 5 hours",
                subheadline: "Updated now",
                providers: []
            )
        )

        let first = SmartHubBridgeServer.shared.queueVoiceRefresh()
        let duplicate = SmartHubBridgeServer.shared.queueVoiceRefresh()

        XCTAssertEqual(first.status, "queued")
        XCTAssertEqual(duplicate.status, "coalesced")
        XCTAssertEqual(duplicate.eventId, first.eventId)
        XCTAssertEqual(duplicate.message, first.message)
        XCTAssertEqual(duplicate.requestedAt, first.requestedAt)
        XCTAssertEqual(SmartHubBridgeServer.shared.voiceRefreshVersion, 1)
    }

    func test_voiceRefreshDoesNotBumpDashboardVersion() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Showing last 5 hours",
                subheadline: "Updated now",
                providers: []
            )
        )
        let versionBeforeVoice = SmartHubBridgeServer.shared.refreshVersion

        _ = SmartHubBridgeServer.shared.queueVoiceRefreshForTesting()

        XCTAssertEqual(SmartHubBridgeServer.shared.refreshVersion, versionBeforeVoice)
        XCTAssertEqual(SmartHubBridgeServer.shared.voiceRefreshVersion, 1)
    }

    func test_providerFilterNarrowsProvidersArray() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$10",
                headline: "Last 5h",
                subheadline: "Updated just now",
                providers: [
                    .init(name: "Claude Code", percent: 50, label: "x", tone: .success, windowLabel: "5h"),
                    .init(name: "Codex", percent: 50, label: "y", tone: .ember, windowLabel: "24h")
                ]
            )
        )

        var config = SmartHubDisplayConfig.default
        config.providerIDs = ["claudecode"] // matches the persistedToken form
        SmartHubBridgeServer.shared.updateDisplayConfig(config)

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("Claude Code"))
        XCTAssertFalse(json.contains("Codex"))
    }

    func test_emptyProviderFilterRetainsAllProviders() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Last 5h",
                subheadline: "",
                providers: [
                    .init(name: "Claude Code", percent: 50, label: "x", tone: .success, windowLabel: "5h"),
                    .init(name: "Codex", percent: 50, label: "y", tone: .ember, windowLabel: "24h")
                ]
            )
        )
        SmartHubBridgeServer.shared.updateDisplayConfig(.default)

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("Claude Code"))
        XCTAssertTrue(json.contains("Codex"))
    }

    // MARK: - Rich card payload

    func test_stateJSONEmitsHeaderTimestampAndStatus() throws {
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$182.40",
                headline: "Showing last 5 hours",
                subheadline: "Updated at 9:42 PM",
                providers: [],
                headerTimestamp: "Thu, May 7  10:43 PM",
                headerStatus: "live provider pressure"
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"headerTimestamp\": \"Thu, May 7  10:43 PM\""))
        XCTAssertTrue(json.contains("\"headerStatus\": \"live provider pressure\""))
    }

    func test_stateJSONEmitsRichCardFieldsPerProvider() throws {
        let provider = SmartHubBridgeSnapshot.Provider(
            name: "Claude Code",
            percent: 18,
            label: "$120 / $300",
            tone: .ember,
            windowLabel: "5h",
            slug: "claudecode",
            accentHex: "CC785C",
            logoSVG: "<svg/>",
            tokenTotal: "5.4B",
            tokenTotalLabel: "TOKENS",
            statusPill: "source 3h ago",
            statusTone: .whimsy,
            freshnessLabel: "updated 3h ago",
            fetchedAtLabel: "May 7, 6:58 PM",
            buckets: [
                .init(name: "5-hour limit", percent: 8, headlineValue: "8%", subLabel: "92% left", resetsLabel: "Resets in 2h 14m · May 8, 3:35 AM", tone: .success, isCreditBalance: false),
                .init(name: "Weekly limit", percent: 18, headlineValue: "18%", subLabel: "82% left", resetsLabel: "Resets in 5d 6h · May 12, 12:00 AM", tone: .success, isCreditBalance: false)
            ],
            accounts: [
                .init(label: "Work", badge: "MAIN", tone: .whimsy, isActive: false),
                .init(label: "alberto8793@g…", badge: "ACTIVE", tone: .success, isActive: true)
            ],
            runsLabel: "1,002 runs",
            costLabel: "$5,835.40"
        )
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$5,835.40",
                headline: "Showing last 5 hours",
                subheadline: "Updated at 9:42 PM",
                providers: [provider]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"slug\":\"claudecode\""))
        XCTAssertTrue(json.contains("\"accentHex\":\"CC785C\""))
        XCTAssertTrue(json.contains("\"tokenTotal\":\"5.4B\""))
        XCTAssertTrue(json.contains("\"statusPill\":\"source 3h ago\""))
        XCTAssertTrue(json.contains("\"statusTone\":\"whimsy\""))
        XCTAssertTrue(json.contains("\"freshnessLabel\":\"updated 3h ago\""))
        XCTAssertTrue(json.contains("\"fetchedAtLabel\":\"May 7, 6:58 PM\""))
        XCTAssertTrue(json.contains("\"runsLabel\":\"1,002 runs\""))
        XCTAssertTrue(json.contains("\"costLabel\":\"$5,835.40\""))
        XCTAssertTrue(json.contains("\"tokenTotalCurrency\":\"\""))
        XCTAssertTrue(json.contains("\"hasQuotaData\":true"))
        XCTAssertTrue(json.contains("\"burnRates\":[]"))
        // Two bucket rows + two account rows must be emitted under the
        // nested arrays so the device can render them as multi-bar /
        // chip rows on the card.
        XCTAssertTrue(json.contains("\"5-hour limit\""))
        XCTAssertTrue(json.contains("\"Weekly limit\""))
        XCTAssertTrue(json.contains("\"badge\":\"MAIN\""))
        XCTAssertTrue(json.contains("\"badge\":\"ACTIVE\""))
        XCTAssertTrue(json.contains("\"isActive\":true"))
        // Both buckets must surface their `resetsLabel` to the page so the
        // Nest Hub can render the reset row beneath each bucket bar.
        XCTAssertTrue(json.contains("\"resetsLabel\":\"Resets in 2h 14m · May 8, 3:35 AM\""))
        XCTAssertTrue(json.contains("\"resetsLabel\":\"Resets in 5d 6h · May 12, 12:00 AM\""))
    }

    func test_stateJSONEmitsEmptyResetsLabelForBucketsWithoutResetTime() throws {
        // KiloCode-style buckets carry `resetsAt: nil`. The pipeline must
        // emit an empty `resetsLabel` (the page hides the row when empty)
        // rather than dropping the field, so the JSON shape stays stable
        // for the page's renderBucket() to switch on.
        let provider = SmartHubBridgeSnapshot.Provider(
            name: "KiloCode",
            percent: 0, label: "", tone: .mercury,
            buckets: [
                .init(name: "Daily", percent: 0, headlineValue: "", subLabel: "", resetsLabel: "", tone: .mercury, isCreditBalance: false)
            ]
        )
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0", headline: "", subheadline: "",
                providers: [provider]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"resetsLabel\":\"\""))
    }

    func test_stateJSONEmitsBurnRateFieldsForNonQuotaProvider() throws {
        let provider = SmartHubBridgeSnapshot.Provider(
            name: "Ollama",
            percent: 0,
            label: "",
            tone: .mercury,
            slug: "ollama",
            accentHex: "6B7280",
            logoSVG: "<svg/>",
            tokenTotal: "1.2M",
            tokenTotalCurrency: "$0.00",
            tokenTotalLabel: "TOKENS",
            statusPill: "no quota",
            statusTone: .mercury,
            freshnessLabel: "",
            fetchedAtLabel: "",
            buckets: [],
            accounts: [],
            runsLabel: "42 runs",
            costLabel: "$0.00",
            hasQuotaData: false,
            burnRates: [
                .init(windowLabel: "5h", tokens: "120K", cost: "$0.00", runs: "5 runs"),
                .init(windowLabel: "7d", tokens: "1.2M", cost: "$0.00", runs: "42 runs")
            ]
        )
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Showing last 5 hours",
                subheadline: "Updated at 9:42 PM",
                providers: [provider]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"hasQuotaData\":false"))
        XCTAssertTrue(json.contains("\"windowLabel\":\"5h\""))
        XCTAssertTrue(json.contains("\"windowLabel\":\"7d\""))
        XCTAssertTrue(json.contains("\"tokens\":\"120K\""))
        XCTAssertTrue(json.contains("\"tokens\":\"1.2M\""))
        XCTAssertTrue(json.contains("\"cost\":\"$0.00\""))
        XCTAssertTrue(json.contains("\"runs\":\"5 runs\""))
        XCTAssertTrue(json.contains("\"runs\":\"42 runs\""))
    }

    func test_providerLogoAssetNamesUseSharedProviderMapping() throws {
        for provider in AgentProvider.allCases {
            XCTAssertEqual(
                SmartHubBridgeController.logoAssetName(for: provider),
                provider.bundledLogoName,
                "Smart Hub logo mapping drifted for \(provider.displayName)"
            )
        }
        XCTAssertEqual(SmartHubBridgeController.logoAssetName(for: .piAgent), "PiAgentLogo")
        XCTAssertNotEqual(
            SmartHubBridgeController.logoAssetName(for: .piAgent),
            SmartHubBridgeController.logoAssetName(for: .hermes),
            "Pi Agent must not reuse the Hermes Smart Hub logo."
        )
    }

    func test_stateJSONLeavesRichFieldsOutWhenSnapshotIsLegacyShape() throws {
        // Legacy callers (NestHubMiniPreview, older unit tests) construct
        // providers without the rich card fields. The bridge must still
        // emit a parseable JSON document where the rich fields are present
        // as empty strings / empty arrays.
        SmartHubBridgeServer.shared.updateSnapshot(
            SmartHubBridgeSnapshot(
                totalSpend: "$0",
                headline: "Last 5h",
                subheadline: "",
                providers: [
                    .init(name: "Codex", percent: 50, label: "y", tone: .ember, windowLabel: "24h")
                ]
            )
        )

        let json = SmartHubBridgeServer.shared.renderStateJSONForTesting()
        XCTAssertTrue(json.contains("\"name\":\"Codex\""))
        XCTAssertTrue(json.contains("\"buckets\":[]"))
        XCTAssertTrue(json.contains("\"accounts\":[]"))
        XCTAssertTrue(json.contains("\"tokenTotal\":\"\""))
        XCTAssertTrue(json.contains("\"runsLabel\":\"\""))
    }

    // MARK: - Schema-v2 backward compat

    func test_legacySmartHubConfigDecodesWithoutDisplayConfig() throws {
        let raw = """
        {
          "enabled": true,
          "dashboardURL": "http://127.0.0.1:8787/render.html",
          "timePeriod": "rolling5h",
          "schemaVersion": 2
        }
        """
        let data = Data(raw.utf8)
        // `publishedAt` is omitted intentionally — the decoder falls
        // back to `Date.distantPast` and treats v2 docs as missing the
        // new fields.
        let decoded = try JSONDecoder().decode(SmartHubConfig.self, from: data)
        XCTAssertNil(decoded.displayConfig)
        XCTAssertNil(decoded.displayOrder)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    private func assertPersistedBridgeURL(_ rawURL: String, path: String) throws {
        let url = try XCTUnwrap(URL(string: rawURL))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.path, path)
        XCTAssertEqual(query["display"], "nest")
        XCTAssertEqual(query["bridgeToken"], SmartHubBridgeServer.shared.bridgeAccessToken)
    }
}
