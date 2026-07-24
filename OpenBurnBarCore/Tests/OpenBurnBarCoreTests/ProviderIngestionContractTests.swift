import Foundation
import XCTest
import OpenBurnBarKernel
import OpenBurnBarLogParsers

final class ProviderIngestionContractTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Provider: Decodable {
            struct Paths: Decodable { let linux: String; let macos: String }
            let providerId: String
            let agentProviderCase: String
            let paths: Paths
            let filePattern: String
            let ingestion: String
            let quotaSignal: Bool
        }

        struct UsageVector: Decodable {
            struct Expected: Decodable {
                let identityKey: String
                let deterministicId: String
                let billedTotalTokens: Int
                let costUSD: Double
                let quotaSignal: Bool
            }

            let providerCase: String
            let providerRawValue: String
            let sessionId: String
            let model: String
            let sourceDeviceId: String?
            let providerAccountId: String?
            let startTime: String
            let endTime: String
            let inputTokens: Int
            let outputTokens: Int
            let cacheCreationTokens: Int
            let cacheReadTokens: Int
            let reasoningTokens: Int
            let costUSD: Double
            let expected: Expected
        }

        let schemaVersion: Int
        let providers: [Provider]
        let goldenUsageVectors: [UsageVector]
    }

    private func loadManifest() throws -> Manifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../contracts/provider-ingestion-catalog.json")
            .standardizedFileURL
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    func test_manifestDrivesEveryProviderPathPatternCoverageAndQuotaDeclaration() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.providers.count, AgentProvider.allCases.count)
        XCTAssertEqual(Set(manifest.providers.map(\.agentProviderCase)).count, AgentProvider.allCases.count)

        for provider in AgentProvider.allCases {
            let generated = AgentProviderIngestionCatalog.entry(for: provider)
            let source = try XCTUnwrap(manifest.providers.first { $0.agentProviderCase == generated.agentProviderCase })
            XCTAssertEqual(generated.providerID, source.providerId)
            XCTAssertEqual(generated.linuxLogicalPath, source.paths.linux)
            XCTAssertEqual(generated.macOSLogicalPath, source.paths.macos)
            XCTAssertEqual(generated.filePattern, source.filePattern)
            XCTAssertEqual(generated.ingestion.rawValue, source.ingestion)
            XCTAssertEqual(generated.quotaSignal, source.quotaSignal)
            XCTAssertEqual(provider.isQuotaSignalProvider, source.quotaSignal)
            XCTAssertEqual(
                AgentProviderLogDiscovery.sessionIdentityKey(provider: provider, resolvedPath: "/resolved/log"),
                "\(provider.rawValue)|/resolved/log"
            )
        }
    }

    func test_goldenUsageVectorsPinIdentityTimestampDedupCostTokensAndQuota() throws {
        let manifest = try loadManifest()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for vector in manifest.goldenUsageVectors {
            let provider = try XCTUnwrap(AgentProvider(rawValue: vector.providerRawValue))
            XCTAssertEqual(AgentProviderIngestionCatalog.entry(for: provider).agentProviderCase, vector.providerCase)
            let start = try XCTUnwrap(formatter.date(from: vector.startTime))
            let end = try XCTUnwrap(formatter.date(from: vector.endTime))
            let identityKey = TokenUsage.deterministicIdentityKey(
                provider: provider,
                sessionId: vector.sessionId,
                model: vector.model,
                sourceDeviceId: vector.sourceDeviceId,
                providerAccountID: vector.providerAccountId
            )
            let usage = TokenUsage(
                provider: provider,
                sessionId: vector.sessionId,
                projectName: "provider-contract",
                model: vector.model,
                inputTokens: vector.inputTokens,
                outputTokens: vector.outputTokens,
                cacheCreationTokens: vector.cacheCreationTokens,
                cacheReadTokens: vector.cacheReadTokens,
                reasoningTokens: vector.reasoningTokens,
                costUSD: vector.costUSD,
                startTime: start,
                endTime: end,
                sourceDeviceId: vector.sourceDeviceId,
                providerAccountID: vector.providerAccountId
            )
            XCTAssertEqual(identityKey, vector.expected.identityKey)
            XCTAssertEqual(usage.id.uuidString.lowercased(), vector.expected.deterministicId)
            XCTAssertEqual(usage.totalTokens, vector.expected.billedTotalTokens)
            XCTAssertEqual(usage.costUSD, vector.expected.costUSD, accuracy: 0.000_000_1)
            XCTAssertEqual(usage.startTime, start)
            XCTAssertEqual(usage.endTime, end)
            XCTAssertEqual(provider.isQuotaSignalProvider, vector.expected.quotaSignal)
        }
    }
}
