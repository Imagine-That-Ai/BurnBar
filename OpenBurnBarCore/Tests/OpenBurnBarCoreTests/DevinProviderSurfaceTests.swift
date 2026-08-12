import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

/// Pins the Devin provider landing and the `*-desktop` execution-source rows that
/// shipped with it: catalog logo resolution, `AgentProvider` identity and aliases,
/// resume display names, and the `UsageExecutionSourceResolver` tables.
///
/// The desktop rows are ordering-sensitive (`fromClientMarker` is first-match-wins
/// over an ordered alias array, and `"devin"` is a substring of `"devin desktop"`),
/// so these assertions pin behavior, not just line reachability.
final class DevinProviderSurfaceTests: XCTestCase {

    // MARK: - Catalog logo resolution

    func test_catalogBundledLogoName_resolvesDevinAndDesktopTwins() {
        // Devin's own ids.
        for providerID in ["devin", "devin-desktop", "devin-cli", "Devin", " DEVIN "] {
            XCTAssertEqual(
                BurnBarCatalogProvider.bundledLogoName(forProviderID: providerID),
                "DevinLogo",
                providerID
            )
        }

        // Desktop twins reuse the CLI provider's artwork rather than a copied
        // placeholder — the macOS asset catalog only ships the base marks.
        let desktopTwins: [String: String] = [
            "factory-desktop": "FactoryLogo",
            "claude-desktop": "ClaudeCodeLogo",
            "warp-desktop": "WarpLogo",
            "ollama-desktop": "OllamaLogo",
            "zcode": "ZaiLogo",
            "zcode-desktop": "ZaiLogo",
            "minimax-desktop": "MiniMaxLogo",
            "codex-desktop": "CodexLogo",
            "cursor-desktop": "CursorLogo"
        ]
        for (providerID, expected) in desktopTwins {
            XCTAssertEqual(
                BurnBarCatalogProvider.bundledLogoName(forProviderID: providerID),
                expected,
                providerID
            )
        }

        XCTAssertNil(BurnBarCatalogProvider.bundledLogoName(forProviderID: "devin-cloud"))
    }

    func test_bundledCatalog_listsDevinAsAccountingOnly() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        let devin = try XCTUnwrap(catalog.provider(id: "devin"))

        XCTAssertEqual(devin.bundledLogoName, "DevinLogo")
        XCTAssertEqual(devin.logoKey, AgentProvider.devin.bundledLogoName)
        // No Devin executor exists: `BurnBarCompositeProviderExecutor` sends every
        // non-Factory route to the OpenAI-compatible executor, which rejects the
        // `devin://local` sentinel with `invalidBaseURL`. Devin stays accounting-only
        // until a real executor or API ingestion path ships.
        XCTAssertFalse(devin.capabilities.contains(.routing))
        XCTAssertTrue(devin.capabilities.contains(.accounting))
    }

    // MARK: - AgentProvider identity

    func test_agentProvider_devinIdentityAndAliases() {
        XCTAssertEqual(AgentProvider.devin.providerID.rawValue, "devin")
        XCTAssertEqual(AgentProvider.fromProviderID(AgentProvider.devin.providerID), .devin)
        XCTAssertEqual(AgentProvider.devin.bundledLogoName, "DevinLogo")
        XCTAssertEqual(AgentProvider.devin.iconName, "desktopcomputer")
        XCTAssertTrue(AgentProvider.swarmGlyphProviders.contains(.devin))

        for alias in [
            "devin", "devin-desktop", "devin_desktop",
            "devin-cli", "devin_cli", "devin.ai", "devinai"
        ] {
            XCTAssertEqual(AgentProvider.fromCatalogProviderID(alias), .devin, alias)
        }

        // Devin supersedes the Windsurf branding but is a distinct provider — the
        // two must never collapse onto each other.
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("windsurf"), .windsurf)
        XCTAssertNotEqual(AgentProvider.devin.bundledLogoName, AgentProvider.windsurf.bundledLogoName)
    }

    // MARK: - Resume presentation

    func test_resumeOutcome_derivesDevinDisplayNameFromWireID() throws {
        XCTAssertEqual(CLIAgentResumeOutcome.displayName(forWireID: "devin"), "Devin")

        // The production caller: no explicit target, so the headline is built from
        // the wire id the Mac returned.
        let handoff = CLIAgentResumeOutcome(
            response: CLIAgentSessionActionResponse(
                status: .handoff,
                targetRuntime: "devin",
                argv: ["devin", "--prompt-file", "/tmp/brief.md"],
                briefingPath: "/tmp/burnbar-resume.md"
            )
        )
        XCTAssertTrue(handoff.headline.hasSuffix("Devin"), handoff.headline)
    }

    // MARK: - Execution source resolution

    func test_providerLogInference_mapsDevinToTheCLIRuntime() {
        let usage = TokenUsage(
            provider: .devin,
            sessionId: "devin-session",
            projectName: "BurnBar",
            model: "devin",
            inputTokens: 10,
            outputTokens: 5,
            startTime: Date(timeIntervalSince1970: 1),
            endTime: Date(timeIntervalSince1970: 2),
            usageSource: .providerLog
        )
        XCTAssertEqual(usage.executionSourceID, "devin-cli")
        XCTAssertEqual(usage.executionSourceName, "Devin CLI")
        XCTAssertEqual(usage.executionSourceKind, .cli)
        XCTAssertEqual(usage.executionSourceConfidence, .derivedExact)
    }

    func test_clientMarkers_separateDesktopSurfacesFromTheirCLIs() {
        let expectations: [(marker: String, id: String, kind: UsageExecutionSourceKind)] = [
            ("Claude Desktop/2026.7", "claude-desktop", .desktopApp),
            ("Cursor Desktop/1.4", "cursor-desktop", .ide),
            ("cursor-ide/1.4", "cursor-desktop", .ide),
            ("Factory Desktop/3.1", "factory-desktop", .desktopApp),
            ("MiniMax Agent/2.0", "minimax-desktop", .desktopApp),
            ("ZCode Desktop/1.0", "zcode-desktop", .desktopApp),
            ("z.ai desktop/1.0", "zcode-desktop", .desktopApp),
            ("Devin Desktop/1.0", "devin-desktop", .desktopApp),
            ("Warp Terminal/0.9", "warp-desktop", .desktopApp),
            ("Ollama Desktop/0.4", "ollama-desktop", .desktopApp),
            ("Hermes Dashboard/1.2", "hermes-desktop", .desktopApp)
        ]
        for expectation in expectations {
            let resolved = UsageExecutionSourceResolver.fromClientMarker(expectation.marker)
            XCTAssertEqual(resolved?.id, expectation.id, expectation.marker)
            XCTAssertEqual(resolved?.kind, expectation.kind, expectation.marker)
        }

        // Ordering guard: the alias table is scanned in declaration order with a
        // `contains` match, so the more specific "devin desktop" row must be reached
        // before the bare "devin" row that maps to the CLI.
        XCTAssertEqual(UsageExecutionSourceResolver.fromClientMarker("Devin/2.1")?.id, "devin-cli")
        XCTAssertEqual(UsageExecutionSourceResolver.fromClientMarker("devin-cli/2.1")?.id, "devin-cli")
        XCTAssertEqual(UsageExecutionSourceResolver.fromClientMarker("Devin Desktop/2.1")?.id, "devin-desktop")
    }

    func test_explicitSourceIDs_pickUpNameAndKindFromTheKnownSourceTable() {
        // Only the id is supplied — name/kind/confidence must come from the table,
        // which is what makes a row worth having.
        let expectations: [(id: String, name: String, kind: UsageExecutionSourceKind)] = [
            ("devin-cli", "Devin CLI", .cli),
            ("devin-desktop", "Devin Desktop", .desktopApp),
            ("cursor-desktop", "Cursor Desktop", .ide),
            ("claude-desktop", "Claude Desktop", .desktopApp),
            ("factory-desktop", "Factory Desktop", .desktopApp),
            ("minimax-cli", "MiniMax CLI", .cli),
            ("minimax-desktop", "MiniMax Desktop", .desktopApp),
            ("zai-cli", "Z.ai CLI", .cli),
            ("zcode-desktop", "ZCode Desktop", .desktopApp),
            ("warp", "Warp", .cli),
            ("warp-desktop", "Warp Desktop", .desktopApp),
            ("ollama", "Ollama", .service),
            ("ollama-desktop", "Ollama Desktop", .desktopApp),
            ("hermes", "Hermes", .cli),
            ("hermes-desktop", "Hermes Dashboard", .desktopApp),
            ("windsurf", "Windsurf", .ide),
            ("cline", "Cline", .ide),
            ("kilo-code", "Kilo Code", .ide),
            ("roo-code", "Roo Code", .ide)
        ]
        for expectation in expectations {
            let resolved = UsageExecutionSourceResolver.resolve(
                provider: .devin,
                usageSource: .daemon,
                explicitID: expectation.id
            )
            XCTAssertEqual(resolved.id, expectation.id, expectation.id)
            XCTAssertEqual(resolved.name, expectation.name, expectation.id)
            XCTAssertEqual(resolved.kind, expectation.kind, expectation.id)
        }
    }
}
