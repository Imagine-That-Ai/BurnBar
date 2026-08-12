import AppKit
import BurnBarCore
import GRDB
import SwiftUI
import XCTest

@testable import BurnBar

// MARK: - Color Resolution Helpers

private struct RGBComponents {
    let red: Double
    let green: Double
    let blue: Double
}

private enum AppearanceColor {
    /// Resolves an adaptive SwiftUI color under the given appearance to sRGB components.
    static func resolve(_ color: Color, appearance: NSAppearance) -> RGBComponents {
        var result = RGBComponents(red: 0, green: 0, blue: 0)
        appearance.performAsCurrentDrawingAppearance {
            let nsColor = NSColor(color)
            let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
            result = RGBComponents(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            )
        }
        return result
    }

    /// WCAG relative luminance from sRGB components.
    static func luminance(_ components: RGBComponents) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.red)
            + 0.7152 * linear(components.green)
            + 0.0722 * linear(components.blue)
    }

    /// WCAG contrast ratio between two resolved colors.
    static func contrast(_ first: RGBComponents, _ second: RGBComponents) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }
}

// MARK: - AgentProvider Coverage Tests

/// VAL-PROV-001/002/003/008/010/019/020 + VAL-CROSS-003: the three new
/// AgentProvider cases are listable, fully themable, honest about support
/// level, and map 1:1 from the fleet roster.
@MainActor
final class AgentProviderCoverageTests: XCTestCase {

    private let darkAppearance = NSAppearance(named: .darkAqua)!
    private let lightAppearance = NSAppearance(named: .aqua)!

    // MARK: VAL-PROV-001 — listable and themable

    func test_newProvidersAreListable() {
        let all = AgentProvider.allCases
        XCTAssertTrue(all.contains(.grokBot), "Grok Bot must be a case")
        XCTAssertTrue(all.contains(.grokCLI), "Grok CLI must be a case")
        XCTAssertTrue(all.contains(.pi), "Pi must be a case")
    }

    func test_newProvidersResolveCompleteMetadata() {
        for provider in [AgentProvider.grokBot, .grokCLI, .pi] {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) displayName")
            XCTAssertFalse(provider.iconName.isEmpty, "\(provider) iconName")
            XCTAssertFalse(provider.logDirectory.isEmpty, "\(provider) logDirectory")
            XCTAssertFalse(provider.filePattern.isEmpty, "\(provider) filePattern")
            XCTAssertNotNil(provider.logoURL, "\(provider) logoURL must be non-nil (documented)")
        }
    }

    func test_iconNamesAreValidSFSymbols() {
        for provider in [AgentProvider.grokBot, .grokCLI, .pi] {
            let image = NSImage(systemSymbolName: provider.iconName, accessibilityDescription: nil)
            XCTAssertNotNil(image, "\(provider).iconName '\(provider.iconName)' must be a valid SF Symbol")
        }
    }

    func test_themeLookupsDifferFromFallbackInBothAppearances() {
        let fallback = ProviderTheme.theme(for: .factory)
        for provider in [AgentProvider.grokBot, .grokCLI, .pi] {
            let theme = ProviderTheme.theme(for: provider)
            for (appearanceName, appearance) in [("dark", darkAppearance), ("light", lightAppearance)] {
                let primary = AppearanceColor.resolve(theme.primaryColor, appearance: appearance)
                let fallbackPrimary = AppearanceColor.resolve(fallback.primaryColor, appearance: appearance)
                let accent = AppearanceColor.resolve(theme.accentColor, appearance: appearance)
                let fallbackAccent = AppearanceColor.resolve(fallback.accentColor, appearance: appearance)
                let message = "\(provider) differs from fallback in \(appearanceName)"
                XCTAssertNotEqual(primary.red, fallbackPrimary.red, accuracy: 0.01, message)
                XCTAssertNotEqual(primary.green, fallbackPrimary.green, accuracy: 0.01, message)
                XCTAssertNotEqual(accent.red, fallbackAccent.red, accuracy: 0.01, message)
                XCTAssertNotEqual(accent.green, fallbackAccent.green, accuracy: 0.01, message)
            }
        }
    }

    func test_themeColorsMeetContrastAgainstSurfacesInBothAppearances() {
        // UI-component threshold: 3:1 (WCAG AA for large text / UI components).
        for provider in [AgentProvider.grokBot, .grokCLI, .pi] {
            let theme = ProviderTheme.theme(for: provider)
            for (appearanceName, appearance) in [("dark", darkAppearance), ("light", lightAppearance)] {
                let surface = AppearanceColor.resolve(DesignSystem.Colors.surface, appearance: appearance)
                let primary = AppearanceColor.resolve(theme.primaryColor, appearance: appearance)
                let accent = AppearanceColor.resolve(theme.accentColor, appearance: appearance)
                let primaryContrast = AppearanceColor.contrast(primary, surface)
                let accentContrast = AppearanceColor.contrast(accent, surface)
                let primaryMessage = "\(provider) primary \(primaryContrast):1 vs surface in \(appearanceName)"
                let accentMessage = "\(provider) accent \(accentContrast):1 vs surface in \(appearanceName)"
                XCTAssertGreaterThanOrEqual(primaryContrast, 3.0, primaryMessage)
                XCTAssertGreaterThanOrEqual(accentContrast, 3.0, accentMessage)
            }
        }
    }

    // MARK: VAL-PROV-002/003 — real roots

    func test_grokCLIPointsAtRealHistoryRoot() {
        XCTAssertEqual(AgentProvider.grokCLI.logDirectory, "~/.grok/sessions")
        XCTAssertEqual(AgentProvider.grokCLI.filePattern, "*.jsonl")
        // The live-signal root is owned by the M1 probe; the usage root must
        // never point at active_sessions.json.
        XCTAssertNotEqual(AgentProvider.grokCLI.logDirectory, "~/.grok")
    }

    func test_piPointsAtRealTranscriptRoot() {
        XCTAssertEqual(AgentProvider.pi.logDirectory, "~/.pi/agent/sessions")
        XCTAssertEqual(AgentProvider.pi.filePattern, "*.jsonl")
        // Config files under ~/.pi/agent are not transcripts.
        XCTAssertNotEqual(AgentProvider.pi.logDirectory, "~/.pi/agent")
    }

    // MARK: VAL-PROV-008 — Grok Bot honest metadata

    func test_grokBotIsLiveSignalOnly() {
        XCTAssertEqual(AgentProvider.grokBot.supportLevel, .unsupported)
        XCTAssertEqual(AgentProvider.grokBot.dataConfidence, .unavailable)
        XCTAssertNotEqual(AgentProvider.grokBot.supportLevel, .supported)
        XCTAssertNotEqual(AgentProvider.grokBot.dataConfidence, .exact)
    }

    func test_grokCLIAndPiArePartial() {
        XCTAssertEqual(AgentProvider.grokCLI.supportLevel, .partial)
        XCTAssertEqual(AgentProvider.grokCLI.dataConfidence, .estimated)
        XCTAssertEqual(AgentProvider.pi.supportLevel, .partial)
        XCTAssertEqual(AgentProvider.pi.dataConfidence, .estimated)
    }

    // MARK: VAL-PROV-010 — honest labels

    func test_supportLabelsDeriveFromMetadata() {
        XCTAssertEqual(AgentProvider.grokBot.supportLevel.label, "Not yet supported")
        XCTAssertEqual(AgentProvider.grokBot.dataConfidence.label, "Unsupported")
        XCTAssertEqual(AgentProvider.grokCLI.supportLevel.label, "Partial support")
        XCTAssertEqual(AgentProvider.pi.supportLevel.label, "Partial support")
        // No provider claims exact tracking without the metadata to back it.
        XCTAssertEqual(AgentProvider.grokBot.dataConfidence, .unavailable)
    }

    // MARK: VAL-PROV-019 — settings/provider surfaces without drift

    func test_settingsDetectionCoversNewProviders() {
        let settings = SettingsManager.shared
        let detection = settings.detectAvailableProviders()
        XCTAssertNotNil(detection[.grokBot])
        XCTAssertNotNil(detection[.grokCLI])
        XCTAssertNotNil(detection[.pi])
        // resolvedPath honors the declared root for each new provider.
        let grokCLIRoot = ("~/.grok/sessions" as NSString).expandingTildeInPath
        let piRoot = ("~/.pi/agent/sessions" as NSString).expandingTildeInPath
        let grokBotRoot = ("~/.grokbot" as NSString).expandingTildeInPath
        XCTAssertEqual(settings.resolvedPath(for: .grokCLI)?.path, grokCLIRoot)
        XCTAssertEqual(settings.resolvedPath(for: .pi)?.path, piRoot)
        XCTAssertEqual(settings.resolvedPath(for: .grokBot)?.path, grokBotRoot)
    }

    func test_grokBotNeverAppearsAsPhantomModelEntry() throws {
        // Models mode derives entries from usage rows only. Grok Bot's parser
        // is an empty no-op, so no usage row exists and no model summary can
        // carry a grokBot provider breakdown.
        let queue = try DatabaseQueue(path: ":memory:")
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "s1",
            projectName: "p",
            model: "claude-sonnet-4",
            inputTokens: 10,
            outputTokens: 10,
            startTime: Date(),
            endTime: Date()
        )
        try store.insert(usage)
        store.refresh()
        let models = store.modelSummaries
        for model in models {
            XCTAssertFalse(
                model.providerBreakdown.contains { $0.provider == .grokBot },
                "grokBot must never appear as a phantom model entry"
            )
        }
    }

    // MARK: VAL-CROSS-003 — fleet identity mapping

    func test_fleetRosterMapsOneToOneToAppProviders() {
        let roster = BurnBarFleetAgentID.declaredRoster
        XCTAssertEqual(roster.count, 10)
        var mapped: Set<AgentProvider> = []
        for fleetID in roster {
            guard let provider = AgentProvider(fleetAgentID: fleetID) else {
                XCTFail("Fleet id \(fleetID.wireValue) must resolve to an AgentProvider")
                continue
            }
            XCTAssertFalse(mapped.contains(provider), "Duplicate mapping for \(provider)")
            mapped.insert(provider)
        }
        XCTAssertEqual(mapped.count, 10, "All ten roster ids map to distinct providers")
    }

    func test_unknownFleetIDDoesNotMap() {
        XCTAssertNil(AgentProvider(fleetAgentID: .unknown("aider")))
    }

    func test_mappedProvidersShareIdentityMetadata() {
        // The fleet surface and the usage surface must render the same
        // display name / icon / theme for the same provider.
        let pairs: [(BurnBarFleetAgentID, AgentProvider)] = [
            (.grokBot, .grokBot),
            (.grokCLI, .grokCLI),
            (.pi, .pi),
            (.claudeCode, .claudeCode),
            (.factoryDroid, .factory),
            (.hermes, .hermes)
        ]
        for (fleetID, provider) in pairs {
            let mapped = AgentProvider(fleetAgentID: fleetID)
            XCTAssertEqual(mapped, provider)
            XCTAssertEqual(mapped?.displayName, provider.displayName)
            XCTAssertEqual(mapped?.iconName, provider.iconName)
        }
    }
}

// MARK: - Grok Bot Parser Tests

/// VAL-PROV-006/008: Grok Bot's usage parser is an honest empty no-op —
/// missing directories return empty without crashing, and no usage rows are
/// ever fabricated from live-signal daemon files.
@MainActor
final class GrokBotParserTests: XCTestCase {

    func test_missingDirectoryReturnsEmpty() async throws {
        let parser = GrokBotParser()
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func test_parserIsHonestEmptyNoOp() async throws {
        let parser = GrokBotParser()
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty, "Grok Bot must never fabricate usage rows")
        XCTAssertEqual(parser.provider, .grokBot)
        XCTAssertEqual(AgentProvider.grokBot.supportLevel, .unsupported)
        XCTAssertEqual(AgentProvider.grokBot.dataConfidence, .unavailable)
    }

    func test_registeredInUsageAggregator() throws {
        // The aggregator's parser registry must include grokBot (VAL-PROV-009
        // registration half, owned here for the no-op parser). The grokCLI/pi
        // parser registrations are owned by the usage-parsers feature.
        let aggregator = UsageAggregator(
            dataStore: try makeInMemoryStore(),
            settingsManager: SettingsManager.shared
        )
        XCTAssertTrue(aggregator.registeredParserProviders.contains(.grokBot))
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
