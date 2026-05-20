import XCTest
@testable import OpenBurnBarCore

final class PixelClockQuotaRendererTests: XCTestCase {
    func testRenderQuotaCarouselBuildsStableHeaderAndProviderPages() {
        let config = PixelClockConfig(
            enabled: true,
            palette: .traffic,
            pageDurationSeconds: 8,
            updateIntervalSeconds: 45,
            scrollSpeedPercent: 120
        )
        let pages = PixelClockQuotaRenderer.renderQuotaCarousel(
            items: [
                PixelClockQuotaItem(
                    providerID: "claude",
                    providerName: "Claude Code",
                    percentUsed: 91,
                    usageText: "91/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].text, "OPENBURNBAR 1 TRACKED")
        XCTAssertEqual(pages[0].color, "#38D898")
        XCTAssertEqual(pages[1].text, "Claude 5h 91% 91/100")
        XCTAssertEqual(pages[1].color, "#E07868")
        XCTAssertEqual(pages[1].progress, 9)
        XCTAssertEqual(pages[1].durationSeconds, 8)
        XCTAssertEqual(pages[1].scrollSpeed, 120)
    }

    func testRenderQuotaCarouselFiltersByProviderIDs() {
        let config = PixelClockConfig(
            enabled: true,
            providerIDs: ["gemini"]
        )
        let pages = PixelClockQuotaRenderer.renderQuotaCarousel(
            items: [
                PixelClockQuotaItem(providerID: "claude", providerName: "Claude", percentUsed: 10, usageText: "1/10", windowLabel: "5h"),
                PixelClockQuotaItem(providerID: "gemini", providerName: "Gemini", percentUsed: 55, usageText: "55/100", windowLabel: "24h")
            ],
            config: config
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].text, "OPENBURNBAR 1 TRACKED")
        XCTAssertEqual(pages[1].text, "Gemini 24h 55% 55/100")
    }

    func testRunningProviderBypassesProviderFilterSoSpinnerCanAppear() {
        let config = PixelClockConfig(
            enabled: true,
            layout: .providerDashboard,
            workingSpinnerPrimaryHex: "#00AAFF",
            workingSpinnerSecondaryHex: "#FFFFFF",
            providerIDs: ["gemini"]
        )
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "codex",
                    providerName: "Codex",
                    percentUsed: 20,
                    usageText: "20/100",
                    windowLabel: "7d",
                    agentStatus: .running
                )
            ],
            config: config,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].text, "CDX 7d RUN 80% 20/100")
        XCTAssertTrue(pages[0].draw.contains(PixelClockDrawInstruction.pixel(x: 29, y: 3, color: "#00AAFF")))
        XCTAssertTrue(pages[0].draw.contains(PixelClockDrawInstruction.pixel(x: 30, y: 3, color: "#FFFFFF")))
    }

    func testRenderQuotaCarouselShowsWaitingWhenNoProvidersAreAvailable() {
        let config = PixelClockConfig(enabled: true)
        let pages = PixelClockQuotaRenderer.renderQuotaCarousel(items: [], config: config)

        XCTAssertEqual(pages, [
            PixelClockRenderedPage(
                text: "OPENBURNBAR WAITING",
                color: config.palette.primaryHex,
                durationSeconds: config.clampedPageDuration,
                scrollSpeed: config.clampedScrollSpeed
            )
        ])
    }

    func testAWTRIXPayloadIncludesVolatileCustomAppFields() {
        let config = PixelClockConfig(
            enabled: true,
            updateIntervalSeconds: 20,
            scrollSpeedPercent: 150
        )
        let payload = PixelClockQuotaRenderer.awtrixPayload(
            pages: [
                PixelClockRenderedPage(
                    text: "Claude 5h 80% 80/100",
                    color: "#E07868",
                    durationSeconds: 6,
                    progress: 80,
                    scrollSpeed: 150
                )
            ],
            config: config
        )

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload[0]["text"] as? String, "Claude 5h 80% 80/100")
        XCTAssertEqual(payload[0]["color"] as? String, "#E07868")
        XCTAssertEqual(payload[0]["duration"] as? Int, 6)
        XCTAssertEqual(payload[0]["progress"] as? Int, 80)
        XCTAssertEqual(payload[0]["progressC"] as? String, "#E07868")
        XCTAssertEqual(payload[0]["progressBC"] as? String, "#181818")
        XCTAssertEqual(payload[0]["scrollSpeed"] as? Int, 150)
        XCTAssertEqual(payload[0]["lifetime"] as? Int, 900)
        XCTAssertEqual(payload[0]["save"] as? Bool, false)
    }

    func testAWTRIXPayloadPacksComplexDrawAsSingleBitmapFrame() throws {
        let denseDraw = (0..<112).map { index in
            PixelClockDrawInstruction.pixel(
                x: index % 32,
                y: index / 32,
                color: index.isMultiple(of: 2) ? "#D97757" : "#8EA0FF"
            )
        }
        let payload = PixelClockQuotaRenderer.awtrixPayload(
            pages: [
                PixelClockRenderedPage(
                    text: "SAFE FALLBACK",
                    color: "#D97757",
                    durationSeconds: 6,
                    progress: 42,
                    scrollSpeed: 100,
                    draw: denseDraw
                )
            ],
            config: PixelClockConfig(enabled: true)
        )

        let awtrixDraw = try XCTUnwrap(payload[0]["draw"] as? [[String: [Any]]])
        XCTAssertEqual(awtrixDraw.count, 1)
        let bitmap = try XCTUnwrap(awtrixDraw[0]["db"])
        XCTAssertEqual(bitmap[0] as? Int, 0)
        XCTAssertEqual(bitmap[1] as? Int, 0)
        XCTAssertEqual(bitmap[2] as? Int, 32)
        XCTAssertEqual(bitmap[3] as? Int, 8)
        let pixels = try XCTUnwrap(bitmap[4] as? [Int])
        XCTAssertEqual(pixels.count, 256)
        XCTAssertEqual(pixels[0], 0xD97757)
        XCTAssertEqual(pixels[1], 0x8EA0FF)
        XCTAssertEqual(payload[0]["noScroll"] as? Bool, true)
        XCTAssertEqual(payload[0]["text"] as? String, "")
        XCTAssertNil(payload[0]["progress"])

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertLessThan(encoded.count, 2_500)
    }

    func testAWTRIXPayloadPreservesPixelRunsInsideBitmapFrame() throws {
        let draw = [
            PixelClockDrawInstruction.pixel(x: 0, y: 0, color: "#D97757"),
            PixelClockDrawInstruction.pixel(x: 1, y: 0, color: "#D97757"),
            PixelClockDrawInstruction.pixel(x: 2, y: 0, color: "#D97757"),
            PixelClockDrawInstruction.pixel(x: 4, y: 0, color: "#8EA0FF")
        ]
        let payload = PixelClockQuotaRenderer.awtrixPayload(
            pages: [
                PixelClockRenderedPage(
                    text: "DRAW",
                    color: "#D97757",
                    durationSeconds: 6,
                    scrollSpeed: 100,
                    draw: draw
                )
            ],
            config: PixelClockConfig(enabled: true)
        )

        let awtrixDraw = try XCTUnwrap(payload[0]["draw"] as? [[String: [Any]]])
        XCTAssertEqual(awtrixDraw.count, 1)
        let bitmap = try XCTUnwrap(awtrixDraw[0]["db"])
        let pixels = try XCTUnwrap(bitmap[4] as? [Int])
        XCTAssertEqual(pixels[0], 0xD97757)
        XCTAssertEqual(pixels[1], 0xD97757)
        XCTAssertEqual(pixels[2], 0xD97757)
        XCTAssertEqual(pixels[3], 0)
        XCTAssertEqual(pixels[4], 0x8EA0FF)
    }

    func testRenderPagesBuildsProviderDashboardWithProviderColoredWindowStatusAndProgressDrawInstructions() {
        let config = PixelClockConfig(
            enabled: true,
            layout: .providerDashboard,
            palette: .emberWhimsy,
            pageDurationSeconds: 7
        )

        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "claudecode",
                    providerName: "Claude Code",
                    percentUsed: 72,
                    usageText: "72/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )
        let payload = PixelClockQuotaRenderer.awtrixPayload(pages: pages, config: config)

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].text, "CLD 5h 28% 72/100")
        XCTAssertEqual(pages[0].color, "#D97757")
        XCTAssertFalse(pages[0].draw.isEmpty)
        XCTAssertEqual(payload[0]["text"] as? String, "")
        XCTAssertEqual(payload[0]["noScroll"] as? Bool, true)
        XCTAssertNotNil(payload[0]["draw"])
        XCTAssertNil(payload[0]["progress"])
        XCTAssertNil(payload[0]["progressC"])
    }

    func testRenderPagesShowsSpinnerWhenGlobalWorkingStateIsActive() {
        let config = PixelClockConfig(
            enabled: true,
            layout: .providerDashboard,
            workingSpinnerStyle: .scan,
            workingSpinnerPrimaryHex: "#00AAFF",
            workingSpinnerSecondaryHex: "#FFFFFF"
        )
        let item = PixelClockQuotaItem(
            providerID: "codex",
            providerName: "Codex",
            percentUsed: 20,
            usageText: "20/100",
            windowLabel: "7d"
        )

        let idle = PixelClockQuotaRenderer.renderPages(items: [item], config: config, now: Date(timeIntervalSince1970: 0), isWorking: false)
        let working = PixelClockQuotaRenderer.renderPages(items: [item], config: config, now: Date(timeIntervalSince1970: 0), isWorking: true)

        XCTAssertEqual(idle[0].text, "CDX 7d 80% 20/100")
        XCTAssertEqual(working[0].text, "CDX 7d RUN 80% 20/100")
        XCTAssertTrue(working[0].draw.contains(.pixel(x: 27, y: 3, color: "#00AAFF")))
        XCTAssertTrue(working[0].draw.contains(.pixel(x: 30, y: 6, color: "#FFFFFF")))
        XCTAssertTrue(working[0].draw.contains(.pixel(x: 16, y: 1, color: "#8EA0FF")))
    }

    func testRenderPagesShowsRunningSpinnerFromAgentStatus() {
        let config = PixelClockConfig(
            enabled: true,
            layout: .providerDashboard,
            workingSpinnerStyle: .pulse,
            workingSpinnerPrimaryHex: "#00AAFF",
            workingSpinnerSecondaryHex: "#FFFFFF"
        )
        let item = PixelClockQuotaItem(
            providerID: "codex",
            providerName: "Codex",
            percentUsed: 20,
            usageText: "running",
            windowLabel: "5h",
            agentStatus: .running
        )

        let pages = PixelClockQuotaRenderer.renderPages(items: [item], config: config, now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(pages[0].text, "CDX 5h RUN 80% running")
        XCTAssertTrue(pages[0].draw.contains(.pixel(x: 29, y: 4, color: "#00AAFF")))
        XCTAssertTrue(pages[0].draw.contains(.pixel(x: 31, y: 5, color: "#00AAFF")))
        XCTAssertTrue(pages[0].draw.contains(.pixel(x: 14, y: 1, color: "#8EA0FF")))
    }

    func testRenderPagesShowsCompletedStatusWithoutSpinner() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard)
        let item = PixelClockQuotaItem(
            providerID: "claudecode",
            providerName: "Claude Code",
            percentUsed: 100,
            usageText: "done",
            windowLabel: "ok",
            agentStatus: .completed
        )

        let pages = PixelClockQuotaRenderer.renderPages(items: [item], config: config)

        XCTAssertEqual(pages[0].text, "CLD OK DONE 0% done")
        XCTAssertFalse(pages[0].draw.contains(.pixel(x: 10, y: 1, color: "#52D6FF")))
    }

    func testProviderDashboardRendersProviderThen5hAnd7dBeforeNextProvider() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(providerID: "codex", providerName: "Codex", percentUsed: 20, usageText: "20/100", windowLabel: "5h"),
                PixelClockQuotaItem(providerID: "codex", providerName: "Codex", percentUsed: 40, usageText: "40/100", windowLabel: "7d"),
                PixelClockQuotaItem(providerID: "claudecode", providerName: "Claude Code", percentUsed: 60, usageText: "60/100", windowLabel: "5h"),
                PixelClockQuotaItem(providerID: "claudecode", providerName: "Claude Code", percentUsed: 80, usageText: "80/100", windowLabel: "7d")
            ],
            config: config
        )

        XCTAssertEqual(pages.map(\.text), [
            "CDX 5h 80% 20/100",
            "CDX 7d 60% 40/100",
            "CLD 5h 40% 60/100",
            "CLD 7d 20% 80/100"
        ])
        XCTAssertEqual(pages[0].color, "#8EA0FF")
        XCTAssertEqual(pages[1].color, "#8EA0FF")
        XCTAssertEqual(pages[2].color, "#D97757")
        XCTAssertEqual(pages[3].color, "#D97757")
    }

    func testProviderDashboardKeepsQuotaBarOutOfProviderLogoColumns() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(providerID: "codex", providerName: "Codex", percentUsed: 0, usageText: "0/100", windowLabel: "5h")
            ],
            config: config
        )

        let barInstructions = pages[0].draw.filter { instruction in
            guard instruction.command == .fillRect,
                  instruction.values.count >= 4,
                  case .int(let y) = instruction.values[1] else {
                return false
            }
            return y == 7
        }
        XCTAssertEqual(barInstructions.count, 1)
        XCTAssertEqual(barInstructions[0].values[0], .int(10))
        XCTAssertEqual(barInstructions[0].values[2], .int(21))
    }

    func testRenderPagesUsesIconDashboardPayloadForQuotaCarouselSelection() {
        let config = PixelClockConfig(enabled: true, layout: .quotaCarousel)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "claudecode",
                    providerName: "Claude Code",
                    percentUsed: 60,
                    usageText: "60/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )

        XCTAssertEqual(pages.count, 1)
        XCTAssertFalse(pages[0].draw.isEmpty)
        let claudeLogo = PixelClockQuotaRenderer.providerLogo(
            for: PixelClockQuotaItem(
                providerID: "claudecode",
                providerName: "Claude Code",
                percentUsed: 60,
                usageText: "60/100",
                windowLabel: "5h"
            )
        )
        let expectedPixel = firstLogoPixel(in: claudeLogo)
        XCTAssertTrue(pages[0].draw.contains(where: { instruction in
            instruction.command == .drawPixel
                && instruction.values == [.int(expectedPixel.column), .int(expectedPixel.row), .string(expectedPixel.color)]
        }))
    }

    func testProviderLogoGlyphsCoverEveryQuotaProviderWithAssetDerivedColors() {
        var seenColorGrids = Set<String>()

        for provider in AgentProvider.quotaSignalProviders {
            let item = PixelClockQuotaItem(
                providerID: provider.persistedToken,
                providerName: provider.displayName,
                percentUsed: 50,
                usageText: "50/100",
                windowLabel: "5h"
            )
            let logo = PixelClockQuotaRenderer.providerLogo(for: item)
            let pattern = logo.rows
            let colorGrid = logo.pixels
                .map { row in row.map { $0 ?? "." }.joined(separator: ",") }
                .joined(separator: "\n")
            let litPixels = renderedPixels(in: logo)
            let litPixelCount = litPixels.count

            XCTAssertEqual(pattern.count, 8, provider.displayName)
            XCTAssertTrue(pattern.allSatisfy { $0.count == 8 }, provider.displayName)
            XCTAssertGreaterThanOrEqual(litPixelCount, 14, provider.displayName)
            XCTAssertGreaterThanOrEqual(Set(litPixels).count, 2, provider.displayName)
            XCTAssertEqual(logo.sourceName, expectedLogoSourceName(for: provider), provider.displayName)
            let allowsSharedOpenAIFamilyLogo = [.openAI, .codex, .openCode].contains(provider)
            if !allowsSharedOpenAIFamilyLogo {
                XCTAssertTrue(seenColorGrids.insert(colorGrid).inserted, provider.displayName)
            }
        }

        XCTAssertEqual(
            PixelClockQuotaRenderer.providerLogo(
                for: PixelClockQuotaItem(providerID: "claudecode", providerName: "Claude Code", percentUsed: 50, usageText: "", windowLabel: "")
            ).sourceName,
            "OpenClawLogo"
        )
    }

    func testCuratedProviderLogoStencilsPreserveTinyClockIdentity() {
        // Anthropic's "Claude Crab" — chunky silhouette matching the
        // reference Alberto provided: small bump claws on the top
        // corners, solid coral shell with two dark eyes, four short
        // legs poking down. No antennae, no joints.
        let claude = logo(for: .claudeCode)
        XCTAssertEqual(claude.sourceName, "OpenClawLogo")
        XCTAssertEqual(claude.rows, [
            "........",
            ".######.",
            ".######.",
            "########",
            "########",
            "#.#..#.#",
            "#.#..#.#",
            "........"
        ])
        XCTAssertEqual(claude.colorHex(row: 1, column: 1), "#D97757")
        XCTAssertEqual(claude.colorHex(row: 2, column: 2), "#1A1208") // left eye
        XCTAssertEqual(claude.colorHex(row: 2, column: 5), "#1A1208") // right eye
        XCTAssertEqual(claude.colorHex(row: 3, column: 0), "#D97757") // left arm
        XCTAssertEqual(claude.colorHex(row: 3, column: 7), "#D97757") // right arm
        // Body fully covers every leg base — pixel directly above
        // each leg is coral, not nil.
        XCTAssertEqual(claude.colorHex(row: 4, column: 0), "#D97757")
        XCTAssertEqual(claude.colorHex(row: 4, column: 7), "#D97757")
        XCTAssertEqual(claude.colorHex(row: 5, column: 0), "#D97757")
        XCTAssertEqual(claude.colorHex(row: 6, column: 5), "#D97757")

        // MiniMax — two stacked M marks, magenta over coral.
        let miniMax = logo(for: .minimax)
        XCTAssertEqual(miniMax.sourceName, "MiniMaxLogo")
        XCTAssertEqual(miniMax.rows, [
            "#..##..#",
            "##.##.##",
            "########",
            "#..##..#",
            "#..##..#",
            "##.##.##",
            "########",
            "#..##..#"
        ])
        XCTAssertEqual(miniMax.colorHex(row: 0, column: 0), "#EC1970")
        XCTAssertEqual(miniMax.colorHex(row: 3, column: 4), "#EC1970")
        XCTAssertEqual(miniMax.colorHex(row: 4, column: 0), "#FF5B3F")
        XCTAssertEqual(miniMax.colorHex(row: 7, column: 4), "#FF5B3F")
        XCTAssertNil(miniMax.colorHex(row: 0, column: 1))

        // Z.ai — bold slanted Z: thick top bar, 3-px diagonal stem,
        // thick bottom bar. Bottom edge of each bar is shaded with
        // the brand lavender (#C9B6FF) for a subtle drop shadow.
        let zai = logo(for: .zai)
        XCTAssertEqual(zai.sourceName, "ZaiLogo")
        XCTAssertEqual(zai.rows, [
            "#######.",
            "#######.",
            "....###.",
            "...###..",
            "..###...",
            ".###....",
            ".#######",
            ".#######"
        ])
        XCTAssertEqual(zai.colorHex(row: 0, column: 0), "#FFFFFF")
        XCTAssertEqual(zai.colorHex(row: 1, column: 0), "#C9B6FF")
        XCTAssertEqual(zai.colorHex(row: 7, column: 6), "#C9B6FF")
        XCTAssertNil(zai.colorHex(row: 5, column: 7))

        // Factory — thin rosette/star line art matching the dark-tile
        // reference mark.
        let factory = logo(for: .factory)
        XCTAssertEqual(factory.sourceName, "FactoryLogo")
        XCTAssertEqual(factory.rows, [
            "...#....",
            ".#.#.#..",
            "#.#.#.#.",
            ".#####..",
            "#.#.#.#.",
            ".#.#.#..",
            "...#....",
            "........"
        ])
        XCTAssertEqual(factory.colorHex(row: 0, column: 3), "#FFFFFF")
        XCTAssertEqual(factory.colorHex(row: 3, column: 3), "#B8B8B8")
        XCTAssertNil(factory.colorHex(row: 0, column: 0))

        let codex = logo(for: .codex)
        XCTAssertEqual(codex.sourceName, "CodexLogo")
        // Left staircase stays on rows 3 and 5 (cols 2 and 2).
        XCTAssertEqual(codex.colorHex(row: 3, column: 2), "#FFFFFF")
        XCTAssertEqual(codex.colorHex(row: 5, column: 2), "#FFFFFF")
        // Right-side horizontal bar now sits one row lower.
        XCTAssertEqual(codex.colorHex(row: 5, column: 5), "#FFFFFF")
        XCTAssertEqual(codex.colorHex(row: 5, column: 7), "#FFFFFF")
        // Negative space adjacent to the staircase is filled with the
        // body's light blue rather than leaving black grid bleed.
        XCTAssertEqual(codex.colorHex(row: 3, column: 3), "#8EA0FF")
        XCTAssertEqual(codex.colorHex(row: 4, column: 4), "#8EA0FF")
        XCTAssertEqual(codex.colorHex(row: 5, column: 3), "#8EA0FF")
        XCTAssertNil(codex.colorHex(row: 0, column: 0))
        XCTAssertNil(codex.colorHex(row: 7, column: 7))

        let ollama = logo(for: .ollama)
        XCTAssertEqual(ollama.sourceName, "OllamaLogo")
        XCTAssertEqual(ollama.rows, [
            "..#.....",
            ".###....",
            "..####..",
            "..####..",
            "..####..",
            "...###..",
            "...##...",
            "...##..."
        ])
        XCTAssertEqual(ollama.colorHex(row: 3, column: 3), "#1EA7FF")
        XCTAssertEqual(ollama.colorHex(row: 4, column: 5), "#0B0B0B")
        XCTAssertNil(ollama.colorHex(row: 0, column: 0))
        XCTAssertNil(ollama.colorHex(row: 7, column: 7))

        let cursor = logo(for: .cursor)
        XCTAssertEqual(cursor.sourceName, "CursorLogo")
        XCTAssertEqual(cursor.rows, [
            "........",
            "...##...",
            "..####..",
            ".#####..",
            "..###...",
            "...#....",
            "........",
            "........"
        ])
        XCTAssertEqual(cursor.colorHex(row: 1, column: 3), "#FFFFFF")
        XCTAssertEqual(cursor.colorHex(row: 2, column: 3), "#AEB7C2")
        XCTAssertEqual(cursor.colorHex(row: 3, column: 4), "#7F8790")
        XCTAssertEqual(cursor.colorHex(row: 4, column: 2), "#30343A")
        XCTAssertNil(cursor.colorHex(row: 0, column: 0))
        XCTAssertNil(cursor.colorHex(row: 7, column: 7))

        // Antigravity CLI — rainbow gradient mountain/A-shape matching
        // the CLI startup banner: blue → cyan → green → yellow → orange → pink.
        let antigravity = logo(for: .antigravity)
        XCTAssertEqual(antigravity.sourceName, "GeminiCLILogo")
        XCTAssertEqual(antigravity.rows, [
            "...##...",
            "..####..",
            ".##..##.",
            ".##..##.",
            "##....##",
            "#......#",
            "........",
            "........"
        ])
        // Green (#34A853) — peak left
        XCTAssertEqual(antigravity.colorHex(row: 0, column: 3), "#34A853")
        // Yellow (#FFEB3B) — peak right
        XCTAssertEqual(antigravity.colorHex(row: 0, column: 4), "#FFEB3B")
        // Cyan (#00BCD4) — left slope
        XCTAssertEqual(antigravity.colorHex(row: 1, column: 2), "#00BCD4")
        XCTAssertEqual(antigravity.colorHex(row: 2, column: 1), "#00BCD4")
        // Orange (#FF9800) — right slope
        XCTAssertEqual(antigravity.colorHex(row: 1, column: 5), "#FF9800")
        XCTAssertEqual(antigravity.colorHex(row: 2, column: 5), "#FF9800")
        // Blue (#4285F4) — bottom left leg
        XCTAssertEqual(antigravity.colorHex(row: 4, column: 0), "#4285F4")
        XCTAssertEqual(antigravity.colorHex(row: 5, column: 0), "#4285F4")
        // Pink (#E91E63) — bottom right leg
        XCTAssertEqual(antigravity.colorHex(row: 4, column: 7), "#E91E63")
        XCTAssertEqual(antigravity.colorHex(row: 5, column: 7), "#E91E63")
        XCTAssertNil(antigravity.colorHex(row: 6, column: 0))
        XCTAssertNil(antigravity.colorHex(row: 7, column: 7))
    }

    func testCursorLogoIsThinAngularNorthEastFacetedMark() {
        let cursor = logo(for: .cursor)
        XCTAssertEqual(cursor.rows, [
            "........",
            "...##...",
            "..####..",
            ".#####..",
            "..###...",
            "...#....",
            "........",
            "........"
        ])
        let litPixels = renderedPixels(in: cursor)
        XCTAssertLessThanOrEqual(litPixels.count, 17)
        XCTAssertEqual(Set(litPixels), [
            "#FFFFFF",
            "#AEB7C2",
            "#7F8790",
            "#30343A"
        ])
    }

    func testWindowSuffixUsesLowercaseShapeAndZeroIsHollow() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "cursor",
                    providerName: "Cursor",
                    percentUsed: 30,
                    usageText: "30/100",
                    windowLabel: "30d"
                )
            ],
            config: config
        )

        XCTAssertEqual(pages[0].text, "CUR 30d 70% 30/100")
        XCTAssertTrue(hasPixel(pages[0].draw, x: 14, y: 1, color: "#FFFFFF"))
        XCTAssertFalse(hasAnyPixel(pages[0].draw, x: 15, y: 2))
        XCTAssertFalse(hasAnyPixel(pages[0].draw, x: 19, y: 1))
        XCTAssertTrue(hasPixel(pages[0].draw, x: 20, y: 1, color: "#FFFFFF"))
        XCTAssertTrue(hasPixel(pages[0].draw, x: 18, y: 4, color: "#FFFFFF"))
        XCTAssertFalse(hasAnyPixel(pages[0].draw, x: 19, y: 4))
        XCTAssertTrue(hasPixel(pages[0].draw, x: 20, y: 4, color: "#FFFFFF"))
    }

    func testProviderDashboardDoesNotRenderIdleZzzPixels() {
        let config = PixelClockConfig(
            enabled: true,
            layout: .providerDashboard,
            palette: .emberWhimsy
        )
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "claudecode",
                    providerName: "Claude Code",
                    percentUsed: 60,
                    usageText: "60/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )

        let staleZzzPoints = [
            (9, 2), (10, 2), (9, 3), (10, 4),
            (12, 1), (13, 1), (12, 2), (13, 3),
            (15, 0), (16, 0), (15, 1), (16, 2)
        ]

        for point in staleZzzPoints {
            let expectedValues: [PixelClockDrawValue] = [
                .int(point.0),
                .int(point.1),
                .string(config.palette.secondaryHex)
            ]
            XCTAssertFalse(pages[0].draw.contains(where: { instruction in
                instruction.command == .drawPixel && instruction.values == expectedValues
            }), "Unexpected stale Zzz pixel at \(point)")
        }
    }

    // MARK: - Rainbow palette (Pride mode)

    func testRainbowPaletteCyclesPrideColorsAcrossPages() {
        let config = PixelClockConfig(
            enabled: true,
            layout: .providerDashboard,
            palette: .rainbow
        )
        // 7 items so we exercise both a full pride-flag cycle (6 colors)
        // and the wrap-around to the seventh page.
        let items = (0..<7).map { idx in
            PixelClockQuotaItem(
                providerID: "claudecode-\(idx)",
                providerName: "Claude Code \(idx)",
                percentUsed: 30 + idx * 5,
                usageText: "\(30 + idx * 5)/100",
                windowLabel: "5h"
            )
        }
        let pages = PixelClockQuotaRenderer.renderPages(items: items, config: config)

        XCTAssertEqual(pages.count, 7)
        XCTAssertEqual(pages[0].color, "#E40303")
        XCTAssertEqual(pages[1].color, "#FF8C00")
        XCTAssertEqual(pages[2].color, "#FFED00")
        XCTAssertEqual(pages[3].color, "#008026")
        XCTAssertEqual(pages[4].color, "#004CFF")
        XCTAssertEqual(pages[5].color, "#732982")
        XCTAssertEqual(pages[6].color, "#E40303") // wraps after 6
    }

    func testRainbowPaletteWindowAndStatusTextUseRainbowColor() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "codex",
                    providerName: "Codex",
                    percentUsed: 40,
                    usageText: "40/100",
                    windowLabel: "7d"
                )
            ],
            config: config
        )
        XCTAssertEqual(pages[0].color, "#E40303")
        // Provider color (#8EA0FF) must NOT show up — every drawn pixel
        // that previously came from providerAccentHex(...) should now
        // be the rainbow page color.
        XCTAssertFalse(pages[0].draw.contains(where: { instruction in
            guard let p = pixelTuple(instruction) else { return false }
            return p.color == "#8EA0FF"
        }))
        // Window label is drawn at row 1; assert at least one window
        // pixel uses the rainbow accent.
        XCTAssertTrue(pages[0].draw.contains(where: { instruction in
            guard let p = pixelTuple(instruction) else { return false }
            return p.y == 1 && p.color == "#E40303"
        }))
    }

    func testRainbowPaletteDrawsFullRainbowBarRegardlessOfPercent() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "claudecode",
                    providerName: "Claude Code",
                    percentUsed: 10, // low usage — rainbow must still be fully drawn
                    usageText: "10/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )
        // Six fillRect stripes at row 7 totalling 21 pixels, each in the
        // pride flag order.
        let stripeWidths = [4, 4, 3, 4, 3, 3]
        var expectedX = 10
        for (idx, width) in stripeWidths.enumerated() {
            let expectedColor = PixelClockPalette.rainbowFlag[idx]
            let needle = PixelClockDrawInstruction.fillRect(
                x: expectedX, y: 7, width: width, height: 1, color: expectedColor
            )
            XCTAssertTrue(
                pages[0].draw.contains(needle),
                "Expected rainbow stripe \(idx) at x=\(expectedX) width=\(width) color=\(expectedColor)"
            )
            expectedX += width
        }
        // 10% remaining → 19% filled → expect a dim mask covering the
        // unused portion (21 - 19 = 2 columns starting at x=10+19).
        let remaining = 100 - 10
        let filled = Int(round(Double(remaining) / 100.0 * 21.0))
        let dimX = 10 + filled
        let dimW = 21 - filled
        XCTAssertTrue(
            pages[0].draw.contains(.fillRect(x: dimX, y: 7, width: dimW, height: 1, color: "#181818")),
            "Expected dim mask at x=\(dimX) width=\(dimW)"
        )
    }

    func testRainbowPaletteTintsProviderLogoWithPageRainbowColor() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "claudecode",
                    providerName: "Claude Code",
                    percentUsed: 30,
                    usageText: "30/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )
        // No pixel in the logo region (columns 0..6, rows 0..7) should
        // still be drawn in Claude's brand coral #D97757.
        for instruction in pages[0].draw {
            guard let p = pixelTuple(instruction), p.x < 8, p.y < 8 else { continue }
            XCTAssertNotEqual(p.color, "#D97757", "Logo pixel at (\(p.x),\(p.y)) was not tinted")
        }
        // At least one logo pixel exists with the rainbow accent.
        XCTAssertTrue(pages[0].draw.contains(where: { instruction in
            guard let p = pixelTuple(instruction), p.x < 8, p.y < 8 else { return false }
            return p.color == "#E40303"
        }))
    }

    func testRainbowLogosUseAtLeastTwoDistinctColorsPerPageSoShapesStayRecognizable() {
        let providers: [(String, String)] = [
            ("claudecode", "Claude Code"),
            ("codex", "Codex"),
            ("minimax", "MiniMax"),
            ("zai", "Z.ai"),
            ("factory", "Factory"),
            ("ollama", "Ollama"),
            ("cursor", "Cursor"),
            ("warp", "Warp"),
            ("kimi", "Kimi")
        ]
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)

        for (id, name) in providers {
            let pages = PixelClockQuotaRenderer.renderPages(
                items: [
                    PixelClockQuotaItem(
                        providerID: id,
                        providerName: name,
                        percentUsed: 50,
                        usageText: "50/100",
                        windowLabel: "5h"
                    )
                ],
                config: config
            )
            // Count distinct colors among logo-region pixels (x<8, y<8).
            var logoColors: Set<String> = []
            for instruction in pages[0].draw {
                guard let p = pixelTuple(instruction), p.x < 8, p.y < 8 else { continue }
                logoColors.insert(p.color)
            }
            XCTAssertGreaterThanOrEqual(
                logoColors.count, 2,
                "Rainbow \(name) logo should use ≥2 distinct colors so silhouette stays recognizable (got \(logoColors))"
            )
        }
    }

    func testRainbowLogoColorsAllComeFromPrideFlag() {
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        let pages = PixelClockQuotaRenderer.renderPages(
            items: [
                PixelClockQuotaItem(
                    providerID: "claudecode",
                    providerName: "Claude Code",
                    percentUsed: 50,
                    usageText: "50/100",
                    windowLabel: "5h"
                )
            ],
            config: config
        )
        let flag = Set(PixelClockPalette.rainbowFlag)
        for instruction in pages[0].draw {
            guard let p = pixelTuple(instruction), p.x < 8, p.y < 8 else { continue }
            XCTAssertTrue(
                flag.contains(p.color),
                "Logo pixel at (\(p.x),\(p.y)) color \(p.color) is not in the pride flag"
            )
        }
    }

    func testRainbowLogoRemapsRotateAcrossPagesPreservingZoneContrast() {
        // Same provider rendered on two different pages should produce
        // two _different_ remaps that each still preserve internal zone
        // contrast (eyes-vs-body must remain distinct on every page).
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        let items = (0..<6).map { idx in
            PixelClockQuotaItem(
                providerID: "claudecode-\(idx)",
                providerName: "Claude Code \(idx)",
                percentUsed: 50,
                usageText: "50/100",
                windowLabel: "5h"
            )
        }
        let pages = PixelClockQuotaRenderer.renderPages(items: items, config: config)
        var firstPageEyeColor: String?
        var firstPageBodyColor: String?
        for (idx, page) in pages.enumerated() {
            // Claude eye lives at (2, 2) in the logo grid.
            // Claude body lives at (1, 1).
            var bodyColor: String?
            var eyeColor: String?
            for instruction in page.draw {
                guard let p = pixelTuple(instruction) else { continue }
                if p.x == 1, p.y == 1 { bodyColor = p.color }
                if p.x == 2, p.y == 2 { eyeColor = p.color }
            }
            XCTAssertNotEqual(bodyColor, eyeColor, "Page \(idx): claude body and eye collapsed to same color")
            if idx == 0 {
                firstPageEyeColor = eyeColor
                firstPageBodyColor = bodyColor
            }
            if idx == 1 {
                XCTAssertNotEqual(bodyColor, firstPageBodyColor, "Page 1 body color didn't rotate from page 0")
                XCTAssertNotEqual(eyeColor, firstPageEyeColor, "Page 1 eye color didn't rotate from page 0")
            }
        }
    }

    /// Dump each rainbow logo as an ASCII grid for visual review.
    /// Marked `disabled` style by prefixing with `disabled_`; flip to
    /// `test_` to re-print on demand.
    func disabled_printRainbowGridsForVisualReview() {
        let providers: [(String, String)] = [
            ("claudecode", "Claude Code"),
            ("codex", "Codex"),
            ("minimax", "MiniMax"),
            ("zai", "Z.ai"),
            ("factory", "Factory"),
            ("ollama", "Ollama"),
            ("cursor", "Cursor"),
            ("warp", "Warp"),
            ("kimi", "Kimi"),
            ("copilot", "Copilot")
        ]
        let palette: [String: Character] = [
            "#E40303": "R", "#FF8C00": "O", "#FFED00": "Y",
            "#008026": "G", "#004CFF": "B", "#732982": "V"
        ]
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        for (id, name) in providers {
            let pages = PixelClockQuotaRenderer.renderPages(
                items: [
                    PixelClockQuotaItem(
                        providerID: id,
                        providerName: name,
                        percentUsed: 50,
                        usageText: "50/100",
                        windowLabel: "5h"
                    )
                ],
                config: config
            )
            print("=== \(name) (page 0) ===")
            var grid: [[Character]] = Array(repeating: Array(repeating: ".", count: 8), count: 8)
            for instruction in pages[0].draw {
                guard let p = pixelTuple(instruction), p.x < 8, p.y < 8 else { continue }
                grid[p.y][p.x] = palette[p.color] ?? "?"
            }
            for row in grid { print(String(row)) }
        }
    }

    func testRainbowLogosProduceDistinctRecognizableGrids() {
        // Snapshot-style assertions: each provider's rainbow grid must
        // contain at least 4 lit logo pixels and a meaningful color
        // distribution (no single color dominates more than 90% of the
        // logo pixels).
        let providers: [(String, String, Int)] = [
            ("claudecode", "Claude Code", 24),
            ("codex", "Codex", 30),
            ("minimax", "MiniMax", 30),
            ("zai", "Z.ai", 26),
            ("factory", "Factory", 22),
            ("ollama", "Ollama", 22),
            ("cursor", "Cursor", 18),
            ("warp", "Warp", 30),
            ("kimi", "Kimi", 16)
        ]
        let config = PixelClockConfig(enabled: true, layout: .providerDashboard, palette: .rainbow)
        for (id, name, minLitPixels) in providers {
            let pages = PixelClockQuotaRenderer.renderPages(
                items: [
                    PixelClockQuotaItem(
                        providerID: id,
                        providerName: name,
                        percentUsed: 50,
                        usageText: "50/100",
                        windowLabel: "5h"
                    )
                ],
                config: config
            )
            var lit: [(x: Int, y: Int, color: String)] = []
            for instruction in pages[0].draw {
                guard let p = pixelTuple(instruction), p.x < 8, p.y < 8 else { continue }
                lit.append(p)
            }
            XCTAssertGreaterThanOrEqual(
                lit.count, minLitPixels,
                "Rainbow \(name) logo only has \(lit.count) lit pixels (expected ≥\(minLitPixels))"
            )
            // No color may dominate (otherwise the logo looks like a blob).
            let counts = Dictionary(grouping: lit, by: \.color).mapValues(\.count)
            let total = lit.count
            for (color, count) in counts {
                let share = Double(count) / Double(total)
                XCTAssertLessThanOrEqual(
                    share, 0.9,
                    "Rainbow \(name) logo: color \(color) covers \(Int(share * 100))% of the logo (must be <90% so silhouette is recognizable)"
                )
            }
        }
    }

    /// Extracts (x, y, color) from a `.drawPixel` instruction; nil for other commands.
    private func pixelTuple(_ instruction: PixelClockDrawInstruction) -> (x: Int, y: Int, color: String)? {
        guard instruction.command == .drawPixel, instruction.values.count >= 3 else { return nil }
        guard case .int(let x) = instruction.values[0],
              case .int(let y) = instruction.values[1],
              case .string(let color) = instruction.values[2] else { return nil }
        return (x, y, color)
    }

    func testRainbowPaletteRoundTripsThroughEnumRawValue() {
        XCTAssertEqual(PixelClockPalette.rainbow.rawValue, "rainbow")
        XCTAssertEqual(PixelClockPalette(rawValue: "rainbow"), .rainbow)
        XCTAssertTrue(PixelClockPalette.rainbow.isRainbow)
        XCTAssertEqual(PixelClockPalette.rainbowFlag.count, 6)
    }

    func testRainbowPaletteSerializesAndDecodesThroughSmartDisplayConfigCodec() {
        let config = SmartHubDisplayConfig(
            layout: .quotaCarousel,
            palette: .rainbow,
            theme: .warmCharcoal,
            background: .dashboard,
            brightness: 0.85,
            scrollSpeedSeconds: 8,
            refreshCadenceSeconds: 5,
            providerIDs: [],
            audibleCue: false,
            identifyOnRefresh: false,
            updatedAt: Date()
        )
        let encoded = SmartDisplayConfigCodec.encode(config)
        XCTAssertEqual(encoded["palette"] as? String, "rainbow")

        let decoded = SmartDisplayConfigCodec.decode(encoded)
        XCTAssertEqual(decoded?.palette, .rainbow)
        XCTAssertTrue(decoded?.palette.isRainbow ?? false)
    }

    func testSmartHubDisplayPaletteRainbowSurfacesDisplayName() {
        XCTAssertEqual(SmartHubDisplayPalette.rainbow.displayName, "Pride rainbow")
        XCTAssertEqual(SmartHubDisplayPalette.rainbowFlag.count, 6)
        XCTAssertEqual(SmartHubDisplayPalette.rainbow.primaryHex, "#E40303")
    }

    private func logo(for provider: AgentProvider) -> PixelClockProviderLogo {
        PixelClockQuotaRenderer.providerLogo(
            for: PixelClockQuotaItem(
                providerID: provider.persistedToken,
                providerName: provider.displayName,
                percentUsed: 50,
                usageText: "50/100",
                windowLabel: "5h"
            )
        )
    }

    private func firstLogoPixel(in logo: PixelClockProviderLogo) -> (row: Int, column: Int, color: String) {
        for row in logo.pixels.indices {
            for column in logo.pixels[row].indices {
                if let color = logo.pixels[row][column] {
                    return (row, column, color)
                }
            }
        }
        XCTFail("Expected logo to contain at least one lit pixel.")
        return (0, 0, "#000000")
    }

    private func renderedPixels(in logo: PixelClockProviderLogo) -> [String] {
        logo.pixels.flatMap { row in
            row.compactMap { $0 }
        }
    }

    private func hasPixel(
        _ draw: [PixelClockDrawInstruction],
        x: Int,
        y: Int,
        color: String
    ) -> Bool {
        draw.contains(where: { instruction in
            instruction.command == .drawPixel
                && instruction.values == [.int(x), .int(y), .string(color)]
        })
    }

    private func hasAnyPixel(
        _ draw: [PixelClockDrawInstruction],
        x: Int,
        y: Int
    ) -> Bool {
        draw.contains(where: { instruction in
            guard instruction.command == .drawPixel,
                  instruction.values.count >= 2,
                  case .int(let pixelX) = instruction.values[0],
                  case .int(let pixelY) = instruction.values[1] else {
                return false
            }
            return pixelX == x && pixelY == y
        })
    }

    private func hasFillRect(
        _ draw: [PixelClockDrawInstruction],
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        color: String
    ) -> Bool {
        draw.contains(where: { instruction in
            instruction.command == .fillRect
                && instruction.values == [.int(x), .int(y), .int(width), .int(height), .string(color)]
        })
    }

    private func expectedLogoSourceName(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return "OpenClawLogo"
        case .codex: return "CodexLogo"
        case .copilot: return "CopilotLogo"
        case .minimax: return "MiniMaxLogo"
        case .zai: return "ZaiLogo"
        case .factory: return "FactoryLogo"
        case .cursor: return "CursorLogo"
        case .warp: return "WarpLogo"
        case .ollama: return "OllamaLogo"
        case .kimi: return "KimiLogo"
        case .deepSeek: return "DeepSeekLogo"
        case .openCode: return "OpenCodeLogo"
        case .antigravity: return "GeminiCLILogo"
        default: return "monogram"
        }
    }
}
