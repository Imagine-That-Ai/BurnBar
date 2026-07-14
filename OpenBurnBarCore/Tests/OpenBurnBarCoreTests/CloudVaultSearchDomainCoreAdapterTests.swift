import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

final class CloudVaultSearchDomainCoreAdapterTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))

    func testMigrationModeDefaultsUnknownValuesAndResolvesExplicitModes() {
        XCTAssertEqual(CloudVaultSearchDomainCoreMigrationMode.resolve(environment: [:]), .legacy)
        XCTAssertEqual(
            CloudVaultSearchDomainCoreMigrationMode.resolve(
                environment: [CloudVaultSearchDomainCoreMigrationMode.environmentKey: "SHADOW"]
            ),
            .shadow
        )
        XCTAssertEqual(
            CloudVaultSearchDomainCoreMigrationMode.resolve(
                environment: [CloudVaultSearchDomainCoreMigrationMode.environmentKey: "rust"]
            ),
            .rust
        )
        XCTAssertEqual(
            CloudVaultSearchDomainCoreMigrationMode.resolve(
                environment: [CloudVaultSearchDomainCoreMigrationMode.environmentKey: "invalid"]
            ),
            .legacy
        )
    }

    func testLegacyModeDoesNotLoadOrCallNativeBackend() throws {
        let recorder = InvocationRecorder()
        let result = try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .token,
            text: "legacy input",
            keyData: key,
            limit: 4,
            mode: .legacy,
            logger: recorder,
            backend: recorder.backend(result: ["rust"])
        ) {
            recorder.recordLegacy()
            return ["legacy"]
        }

        XCTAssertEqual(result, ["legacy"])
        XCTAssertEqual(recorder.nativeCalls, 0)
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testShadowModePassesCompleteUnicodeInputOnceAndRemainsLegacyAuthoritative() throws {
        let recorder = InvocationRecorder()
        let text = "The X API, Caf\u{00E9}, \u{6771}\u{4EAC}, and \u{10437} repeat repeat"
        let result = try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .index,
            text: text,
            keyData: key,
            limit: 40,
            mode: .shadow,
            logger: recorder,
            backend: recorder.backend { operation, receivedText, receivedKey, limit in
                XCTAssertEqual(operation, .index)
                XCTAssertEqual(receivedText, text)
                XCTAssertEqual(receivedKey, self.key)
                XCTAssertEqual(limit, 40)
                return ["rust"]
            }
        ) {
            recorder.recordLegacy()
            return ["legacy"]
        }

        XCTAssertEqual(result, ["legacy"])
        XCTAssertEqual(recorder.nativeCalls, 1)
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertEqual(
            recorder.messages,
            ["domain_core.cloudvault_search operation=index category=value_mismatch core=test-core"]
        )
        XCTAssertFalse(recorder.messages.joined().contains(text))
        XCTAssertFalse(recorder.messages.joined().contains("legacy"))
        XCTAssertFalse(recorder.messages.joined().contains("rust"))
        XCTAssertFalse(recorder.messages.joined().contains(key.base64EncodedString()))
    }

    func testShadowModeReturnsExactLegacyOrderingWithoutMismatchDiagnostic() throws {
        let recorder = InvocationRecorder()
        let ordered = ["b", "a", "c"]
        let result = try CloudVaultSearchDomainCoreAdapter.hashes(
            operation: .query,
            text: "duplicates duplicates and stopwords",
            keyData: key,
            limit: 10,
            mode: .shadow,
            logger: recorder,
            backend: recorder.backend(result: ordered)
        ) {
            recorder.recordLegacy()
            return ordered
        }

        XCTAssertEqual(result, ordered)
        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testShadowLegacyRejectionDoesNotTouchNative() {
        let recorder = InvocationRecorder()
        XCTAssertThrowsError(
            try CloudVaultSearchDomainCoreAdapter.hashes(
                operation: .token,
                text: "legacy rejects",
                keyData: key,
                limit: 10,
                mode: .shadow,
                logger: recorder,
                backend: recorder.backend(result: ["rust"])
            ) {
                recorder.recordLegacy()
                throw TestError.legacy
            }
        )
        XCTAssertEqual(recorder.legacyCalls, 1)
        XCTAssertEqual(recorder.nativeCalls, 0)
        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testShadowModeFallsBackOnUnavailableInvalidAndNativeErrors() throws {
        for scenario in ShadowFallbackScenario.allCases {
            let recorder = InvocationRecorder()
            let backend: CloudVaultSearchDomainCoreAdapter.NativeBackend?
            let limit: Int
            switch scenario {
            case .unavailable:
                backend = nil
                limit = 10
            case .abiMismatch:
                backend = recorder.backend(result: ["unused"], abiVersion: 99)
                limit = 10
            case .invalidLimit:
                backend = recorder.backend(result: ["unused"])
                limit = Int.max
            case .nativeError:
                backend = recorder.backend { _, _, _, _ in throw TestError.native }
                limit = 10
            }

            let result = try CloudVaultSearchDomainCoreAdapter.hashes(
                operation: .semantic,
                text: "bounded search",
                keyData: key,
                limit: limit,
                mode: .shadow,
                logger: recorder,
                backend: backend
            ) {
                recorder.recordLegacy()
                return ["legacy"]
            }

            XCTAssertEqual(result, ["legacy"], scenario.rawValue)
            XCTAssertEqual(recorder.legacyCalls, 1, scenario.rawValue)
            XCTAssertEqual(recorder.messages.count, 1, scenario.rawValue)
        }
    }

    func testRustModeNeverEvaluatesLegacyOnUnavailableABIInvalidInputOrNativeError() {
        for scenario in RustFailureScenario.allCases {
            let recorder = InvocationRecorder()
            let backend: CloudVaultSearchDomainCoreAdapter.NativeBackend?
            let limit: Int
            switch scenario {
            case .unavailable:
                backend = nil
                limit = 10
            case .abiMismatch:
                backend = recorder.backend(result: [], abiVersion: 99)
                limit = 10
            case .invalidLimit:
                backend = recorder.backend(result: [])
                limit = Int.max
            case .nativeError:
                backend = recorder.backend { _, _, _, _ in throw TestError.native }
                limit = 10
            }

            XCTAssertThrowsError(
                try CloudVaultSearchDomainCoreAdapter.hashes(
                    operation: .token,
                    text: "fail closed",
                    keyData: key,
                    limit: limit,
                    mode: .rust,
                    logger: recorder,
                    backend: backend
                ) {
                    recorder.recordLegacy()
                    return ["legacy"]
                },
                scenario.rawValue
            )
            XCTAssertEqual(recorder.legacyCalls, 0, scenario.rawValue)
            XCTAssertEqual(recorder.messages.count, 1, scenario.rawValue)
        }
    }

    func testRustModeReturnsEmptyForZeroAndNegativeLimitsWithoutLegacy() throws {
        for limit in [0, -1] {
            let recorder = InvocationRecorder()
            let result = try CloudVaultSearchDomainCoreAdapter.hashes(
                operation: .token,
                text: "bounded search",
                keyData: key,
                limit: limit,
                mode: .rust,
                logger: recorder,
                backend: recorder.backend { _, _, _, receivedLimit in
                    XCTAssertEqual(receivedLimit, Int32(limit))
                    return []
                }
            ) {
                recorder.recordLegacy()
                return ["legacy"]
            }
            XCTAssertEqual(result, [])
            XCTAssertEqual(recorder.nativeCalls, 1)
            XCTAssertEqual(recorder.legacyCalls, 0)
        }
    }

    func testDenseShortTokenBodyChunksStayWithinNativeCapWithoutDataLoss() throws {
        let body = Array(repeating: "aa", count: 5_000).joined(separator: " ")
        let metadata = "dense title provider"
        let chunks = try CloudVaultCrypto.cloudSearchBodyChunks(
            body,
            metadata: metadata,
            maxBytes: 16_000,
            maxExtractedTokens: 4_096
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), body)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf8.count, 16_000)
            XCTAssertLessThanOrEqual(
                CloudVaultCrypto.exactPhraseTokensForContract(from: chunk + " " + metadata).count,
                4_096
            )
        }

        #if canImport(OpenBurnBarDomainCoreFFI)
        let backend = try XCTUnwrap(CloudVaultSearchDomainCoreAdapter.productionBackend)
        for chunk in chunks {
            XCTAssertNoThrow(
                try CloudVaultSearchDomainCoreAdapter.hashes(
                    operation: .index,
                    text: chunk + " " + metadata,
                    keyData: key,
                    limit: 1_024,
                    mode: .rust,
                    logger: InvocationRecorder(),
                    backend: backend,
                    legacy: { XCTFail("Rust mode evaluated legacy"); return [] }
                )
            )
        }
        #endif
    }

    func testSearchBodyChunkingRejectsMetadataThatConsumesTokenBudget() {
        let metadata = Array(repeating: "meta", count: 4_096).joined(separator: " ")
        XCTAssertThrowsError(
            try CloudVaultCrypto.cloudSearchBodyChunks("body token", metadata: metadata)
        ) { error in
            guard case CloudVaultCryptoError.invalidSearchInput = error else {
                return XCTFail("Expected invalidSearchInput, got \(error)")
            }
        }
    }

    #if canImport(OpenBurnBarDomainCoreFFI)
    func testProductionNativeBackendMatchesEveryCanonicalHashFixture() throws {
        let fixture = try Self.loadFixture()
        let primaryKey = try Self.data(hex: fixture.primaryKeyHex)
        let alternateKey = try Self.data(hex: fixture.alternateKeyHex)
        let backend = try XCTUnwrap(CloudVaultSearchDomainCoreAdapter.productionBackend)
        let logger = InvocationRecorder()

        for testCase in fixture.hashCases {
            let key = testCase.key == "alternate" ? alternateKey : primaryKey
            let operation = try XCTUnwrap(CloudVaultSearchDomainCoreOperation(rawValue: testCase.operation))
            let hashes = try CloudVaultSearchDomainCoreAdapter.hashes(
                operation: operation,
                text: try testCase.resolvedText(),
                keyData: key,
                limit: testCase.limit,
                mode: .rust,
                logger: logger,
                backend: backend
            ) {
                XCTFail("Rust mode evaluated the legacy closure for \(testCase.id)")
                return []
            }
            XCTAssertEqual(hashes, testCase.expected, testCase.id)
        }

        XCTAssertThrowsError(
            try CloudVaultSearchDomainCoreAdapter.hashes(
                operation: .query,
                text: "oversized limit",
                keyData: primaryKey,
                limit: 1_025,
                mode: .rust,
                logger: logger,
                backend: backend,
                legacy: { XCTFail("Rust mode evaluated legacy for an oversized limit"); return [] }
            )
        )
    }
    #endif

    private static func loadFixture() throws -> SearchFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-search-contract.json")
            .standardizedFileURL
        return try JSONDecoder().decode(SearchFixture.self, from: Data(contentsOf: url))
    }

    private static func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw TestError.invalidFixture }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw TestError.invalidFixture }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

private final class InvocationRecorder: CloudVaultSearchDomainCoreLogging {
    private(set) var nativeCalls = 0
    private(set) var legacyCalls = 0
    private(set) var messages: [String] = []

    func recordLegacy() {
        legacyCalls += 1
    }

    func log(_ message: String) {
        messages.append(message)
    }

    func backend(
        result: [String],
        abiVersion: UInt32 = CloudVaultSearchDomainCoreAdapter.requiredABIVersion
    ) -> CloudVaultSearchDomainCoreAdapter.NativeBackend {
        backend(abiVersion: abiVersion) { _, _, _, _ in result }
    }

    func backend(
        abiVersion: UInt32 = CloudVaultSearchDomainCoreAdapter.requiredABIVersion,
        search: @escaping (
            CloudVaultSearchDomainCoreOperation,
            String,
            Data,
            Int32
        ) throws -> [String]
    ) -> CloudVaultSearchDomainCoreAdapter.NativeBackend {
        .init(
            abiVersion: { abiVersion },
            coreVersion: { "test-core" },
            search: { operation, text, keyData, limit in
                self.nativeCalls += 1
                return try search(operation, text, keyData, limit)
            }
        )
    }
}

private enum ShadowFallbackScenario: String, CaseIterable {
    case unavailable
    case abiMismatch
    case invalidLimit
    case nativeError
}

private enum RustFailureScenario: String, CaseIterable {
    case unavailable
    case abiMismatch
    case invalidLimit
    case nativeError
}

private enum TestError: Error {
    case native
    case legacy
    case invalidFixture
}

private struct SearchFixture: Decodable {
    let primaryKeyHex: String
    let alternateKeyHex: String
    let hashCases: [SearchHashCase]
}

private struct SearchHashCase: Decodable {
    let id: String
    let operation: String
    let key: String
    let text: String?
    let input: SearchGeneratedInput?
    let limit: Int
    let expected: [String]

    func resolvedText() throws -> String {
        if let text { return text }
        guard let input, input.kind == "numberedTokens", input.count.signum() >= 0 else {
            throw TestError.invalidFixture
        }
        return (0..<input.count).map { "\(input.prefix)\($0)" }.joined(separator: " ")
    }
}

private struct SearchGeneratedInput: Decodable {
    let kind: String
    let prefix: String
    let count: Int
}
