import Foundation
import XCTest
@testable import OpenBurnBarCore

#if os(Linux)
final class AgentProviderLogDiscoveryLinuxTests: XCTestCase {
    func testGeneratedManifestCoversEveryAgentProviderExactlyOnce() {
        XCTAssertEqual(AgentProvider.allCases.count, 33)
        XCTAssertEqual(AgentProviderCapabilities.byProvider.count, AgentProvider.allCases.count)
        XCTAssertEqual(Set(AgentProviderCapabilities.byProvider.keys), Set(AgentProvider.allCases))
        XCTAssertEqual(Set(AgentProviderCapabilities.all.map(\.providerID)).count, AgentProvider.allCases.count)
        for provider in AgentProvider.allCases {
            let record = provider.capabilityRecord
            XCTAssertEqual(record.provider, provider)
            XCTAssertEqual(record.providerID, provider.providerID.rawValue)
            XCTAssertEqual(record.displayName, provider.rawValue)
        }
    }

    func testGeneratedCapabilitiesMatchCanonicalQuotaChatAndAccountSets() {
        XCTAssertEqual(
            Set(AgentProviderCapabilities.all.filter(\.quotaSupported).map(\.provider)),
            Set(AgentProvider.quotaSignalProviders)
        )
        XCTAssertEqual(
            Set(AgentProviderCapabilities.all.filter(\.accountConnectSupported).map(\.provider)),
            Set(AgentProvider.mobileAccountConnectableProviders)
        )
        XCTAssertEqual(
            Set(AgentProviderCapabilities.all.compactMap(\.chatRuntimeID)),
            Set(AssistantRuntimeID.allCases.map(\.rawValue))
        )
        for record in AgentProviderCapabilities.all {
            XCTAssertEqual(record.unsupportedReasons.quota == nil, record.quotaSupported)
            XCTAssertEqual(record.unsupportedReasons.chat == nil, record.chatRuntimeID != nil)
            XCTAssertEqual(record.unsupportedReasons.accountConnect == nil, record.accountConnectSupported)
            XCTAssertEqual(record.unsupportedReasons.localLogs == nil, record.localLogsSupported)
        }
    }

    func testResolveLogSourceUsesXDGConfigAndDataForEveryApplicableProvider() throws {
        let environment = [
            "HOME": "/home/linux-fixture",
            "XDG_CONFIG_HOME": "/custom/config",
            "XDG_DATA_HOME": "/custom/data"
        ]
        for record in AgentProviderCapabilities.all where record.localLogsSupported {
            let source = try XCTUnwrap(AgentProviderLogDiscovery.resolveLogSource(for: record.provider, environment: environment))
            switch record.xdgBehavior {
            case .xdgConfig: XCTAssertTrue(source.resolvedPath.hasPrefix("/custom/config/"), record.providerID)
            case .xdgData: XCTAssertTrue(source.resolvedPath.hasPrefix("/custom/data/"), record.providerID)
            case .homeRelative: XCTAssertTrue(source.resolvedPath.hasPrefix("/home/linux-fixture/"), record.providerID)
            case .noLocalLogs: XCTFail("No-local-log provider unexpectedly registered a parser: \(record.providerID)")
            }
            XCTAssertEqual(source.parserSource, record.parserSource)
            XCTAssertEqual(source.filePattern, record.filePattern)
        }
    }

    func testProviderHomeOverridesSupportSnapAndExplicitHostHome() throws {
        let snap = try XCTUnwrap(AgentProviderLogDiscovery.resolveLogSource(
            for: .codex,
            environment: ["HOME": "/snap/openburnbar/current", "SNAP_REAL_HOME": "/home/alice"]
        ))
        XCTAssertEqual(snap.resolvedPath, "/home/alice/.codex/sessions")

        let explicit = try XCTUnwrap(AgentProviderLogDiscovery.resolveLogSource(
            for: .codex,
            environment: ["HOME": "/sandbox", "SNAP_REAL_HOME": "/home/alice", "OPENBURNBAR_PROVIDER_HOME": "/mnt/host-home"]
        ))
        XCTAssertEqual(explicit.resolvedPath, "/mnt/host-home/.codex/sessions")
    }

    func testFlatpakStyleXDGOverridesRemainAuthoritative() throws {
        let source = try XCTUnwrap(AgentProviderLogDiscovery.resolveLogSource(
            for: .openCode,
            environment: [
                "HOME": "/home/alice",
                "FLATPAK_ID": "com.openburnbar.OpenBurnBar",
                "XDG_DATA_HOME": "/home/alice/.var/app/com.openburnbar.OpenBurnBar/data"
            ]
        ))
        XCTAssertEqual(source.resolvedPath, "/home/alice/.var/app/com.openburnbar.OpenBurnBar/data/opencode")
    }

    func testNoLocalLogAndUnregisteredParserCasesFailClosed() {
        for provider in [AgentProvider.openAI, .openBurnBar, .deepSeek, .mimo, .openClaude, .omp] {
            XCTAssertNil(AgentProviderLogDiscovery.resolveLogSource(for: provider, environment: ["HOME": "/home/alice"]))
            XCTAssertNotNil(provider.capabilityRecord.unsupportedReasons.localLogs)
        }
    }

    func testSessionIdentityStandardizesPathsAndSurvivesRotation() {
        XCTAssertEqual(
            AgentProviderLogDiscovery.sessionIdentityKey(provider: .codex, resolvedPath: "/home/alice/.codex/./sessions/"),
            "Codex|/home/alice/.codex/sessions"
        )
        let directory = "/home/alice/.claude/projects"
        XCTAssertEqual(
            AgentProviderLogDiscovery.sessionIdentityKey(provider: .claudeCode, resolvedPath: directory),
            AgentProviderLogDiscovery.sessionIdentityKey(provider: .claudeCode, resolvedPath: directory)
        )
    }

    func testSymlinkIdentityUsesLogicalPathWithoutResolvingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obb-provider-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("real-codex", isDirectory: true)
        let link = root.appendingPathComponent(".codex", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let source = try XCTUnwrap(AgentProviderLogDiscovery.resolveLogSource(for: .codex, environment: ["HOME": root.path]))
        XCTAssertEqual(source.resolvedPath, link.appendingPathComponent("sessions").path)
        XCTAssertEqual(source.sessionIdentityKey, "Codex|\(link.appendingPathComponent("sessions").path)")
    }
}
#endif
