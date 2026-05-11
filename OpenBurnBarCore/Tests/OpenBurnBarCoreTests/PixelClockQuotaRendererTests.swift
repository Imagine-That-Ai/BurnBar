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
                    windowLabel: "5H"
                )
            ],
            config: config
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].text, "OPENBURNBAR 1 TRACKED")
        XCTAssertEqual(pages[0].color, "#38D898")
        XCTAssertEqual(pages[1].text, "Claude 5H 91% 91/100")
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
                PixelClockQuotaItem(providerID: "claude", providerName: "Claude", percentUsed: 10, usageText: "1/10", windowLabel: "5H"),
                PixelClockQuotaItem(providerID: "gemini", providerName: "Gemini", percentUsed: 55, usageText: "55/100", windowLabel: "24H")
            ],
            config: config
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].text, "OPENBURNBAR 1 TRACKED")
        XCTAssertEqual(pages[1].text, "Gemini 24H 55% 55/100")
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
                    text: "Claude 5H 80% 80/100",
                    color: "#E07868",
                    durationSeconds: 6,
                    progress: 80,
                    scrollSpeed: 150
                )
            ],
            config: config
        )

        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload[0]["text"] as? String, "Claude 5H 80% 80/100")
        XCTAssertEqual(payload[0]["color"] as? String, "#E07868")
        XCTAssertEqual(payload[0]["duration"] as? Int, 6)
        XCTAssertEqual(payload[0]["progress"] as? Int, 80)
        XCTAssertEqual(payload[0]["progressC"] as? String, "#E07868")
        XCTAssertEqual(payload[0]["progressBC"] as? String, "#181818")
        XCTAssertEqual(payload[0]["scrollSpeed"] as? Int, 150)
        XCTAssertEqual(payload[0]["lifetime"] as? Int, 60)
        XCTAssertEqual(payload[0]["save"] as? Bool, false)
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
        XCTAssertEqual(pages[0].text, "CLD 5H 28% 72/100")
        XCTAssertEqual(pages[0].color, "#D97757")
        XCTAssertFalse(pages[0].draw.isEmpty)
        XCTAssertEqual(payload[0]["text"] as? String, "")
        XCTAssertEqual(payload[0]["noScroll"] as? Bool, true)
        XCTAssertEqual(payload[0]["progress"] as? Int, 28)

        let draw = try? XCTUnwrap(payload[0]["draw"] as? [[String: [Any]]])
        XCTAssertTrue(draw?.contains(where: { instruction in
            guard let values = instruction["df"], values.count == 5 else { return false }
            return values[0] as? Int == 10
                && values[1] as? Int == 7
                && values[2] as? Int == 6
                && values[3] as? Int == 1
                && values[4] as? String == "#D97757"
        }) ?? false)
        XCTAssertTrue(draw?.contains(where: { instruction in
            guard let values = instruction["dp"], values.count == 3 else { return false }
            return values[0] as? Int == 10
                && values[1] as? Int == 1
                && values[2] as? String == "#D97757"
        }) ?? false)
        XCTAssertTrue(draw?.contains(where: { instruction in
            guard let values = instruction["dp"], values.count == 3 else { return false }
            return values[0] as? Int == 20
                && values[1] as? Int == 1
                && values[2] as? String == "#D97757"
        }) ?? false)
    }

    func testRenderPagesUsesStatusTextInsteadOfSqueezingSpinnerIntoTheFrame() {
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

        let idle = PixelClockQuotaRenderer.renderPages(items: [item], config: config, isWorking: false)
        let working = PixelClockQuotaRenderer.renderPages(items: [item], config: config, isWorking: true)

        XCTAssertEqual(idle[0].text, "CDX 7D 80% 20/100")
        XCTAssertEqual(working[0].text, "CDX 7D RUN 80% 20/100")
        XCTAssertFalse(working[0].draw.contains(.pixel(x: 10, y: 1, color: "#00AAFF")))
        XCTAssertTrue(working[0].draw.contains(.pixel(x: 20, y: 1, color: "#8EA0FF")))
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

        let pages = PixelClockQuotaRenderer.renderPages(items: [item], config: config)

        XCTAssertEqual(pages[0].text, "CDX 5H RUN 80% running")
        XCTAssertTrue(pages[0].draw.contains(.pixel(x: 20, y: 1, color: "#8EA0FF")))
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
            "CDX 5H 80% 20/100",
            "CDX 7D 60% 40/100",
            "CLD 5H 40% 60/100",
            "CLD 7D 20% 80/100"
        ])
        XCTAssertEqual(pages[0].color, "#8EA0FF")
        XCTAssertEqual(pages[1].color, "#8EA0FF")
        XCTAssertEqual(pages[2].color, "#D97757")
        XCTAssertEqual(pages[3].color, "#D97757")
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
            let litPixelCount = logo.pixels.flatMap(\.self).compactMap(\.self).count

            XCTAssertEqual(pattern.count, 8, provider.displayName)
            XCTAssertTrue(pattern.allSatisfy { $0.count == 8 }, provider.displayName)
            XCTAssertGreaterThanOrEqual(litPixelCount, 14, provider.displayName)
            XCTAssertGreaterThanOrEqual(Set(logo.pixels.flatMap(\.self).compactMap(\.self)).count, 2, provider.displayName)
            XCTAssertEqual(logo.sourceName, expectedLogoSourceName(for: provider), provider.displayName)
            XCTAssertTrue(seenColorGrids.insert(colorGrid).inserted, provider.displayName)
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

        // MiniMax — three vertical "M" strokes connected by a top
        // crossbar. Magenta (#EC1970) on the left, coral (#FF5B3F) on
        // the right, mirroring the brand gradient.
        let miniMax = logo(for: .minimax)
        XCTAssertEqual(miniMax.sourceName, "MiniMaxLogo")
        XCTAssertEqual(miniMax.rows, [
            "##.##.##",
            "##.##.##",
            "########",
            "##.##.##",
            "##.##.##",
            "########",
            "##.##.##",
            "##.##.##"
        ])
        // Outer strands magenta, middle strand coral.
        XCTAssertEqual(miniMax.colorHex(row: 0, column: 0), "#EC1970")
        XCTAssertEqual(miniMax.colorHex(row: 0, column: 3), "#FF5B3F")
        XCTAssertEqual(miniMax.colorHex(row: 0, column: 7), "#EC1970")
        // Weave band 1: magenta passes over coral.
        XCTAssertEqual(miniMax.colorHex(row: 2, column: 2), "#FF5B3F")
        XCTAssertEqual(miniMax.colorHex(row: 2, column: 5), "#EC1970")
        // Weave band 2: coral passes over magenta.
        XCTAssertEqual(miniMax.colorHex(row: 5, column: 2), "#FF5B3F")
        XCTAssertEqual(miniMax.colorHex(row: 5, column: 5), "#EC1970")
        XCTAssertNil(miniMax.colorHex(row: 0, column: 2))

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

        // Factory — eight-petal sunburst silhouette with a 2×2 grey
        // hub at the centre, mirroring the negative-space treatment
        // of the real black-on-white brand mark.
        let factory = logo(for: .factory)
        XCTAssertEqual(factory.sourceName, "FactoryLogo")
        XCTAssertEqual(factory.rows, [
            "#..##..#",
            ".#.##.#.",
            "..####..",
            "########",
            "########",
            "..####..",
            ".#.##.#.",
            "#..##..#"
        ])
        XCTAssertEqual(factory.colorHex(row: 0, column: 0), "#FFFFFF")
        XCTAssertEqual(factory.colorHex(row: 3, column: 3), "#B8B8B8")
        XCTAssertEqual(factory.colorHex(row: 4, column: 4), "#B8B8B8")

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
            ".#....#.",
            ".##..##.",
            "########",
            "###..###",
            "########",
            "########",
            ".######.",
            "..####.."
        ])
        XCTAssertEqual(ollama.colorHex(row: 3, column: 2), "#1EA7FF")
        XCTAssertEqual(ollama.colorHex(row: 3, column: 5), "#1EA7FF")
        XCTAssertEqual(ollama.colorHex(row: 5, column: 1), "#AEB7C2")
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
        default: return "monogram"
        }
    }
}
