import Foundation
import XCTest
@testable import OpenBurnBarCore

final class CloudVaultSearchContractTests: XCTestCase {
    func test_tokenizationAndSemanticFeaturesMatchSharedContract() throws {
        let fixture = try Self.loadFixture()
        XCTAssertEqual(fixture.schema, "openburnbar.domain-core.cloudvault.search.v1")

        for testCase in fixture.tokenizationCases {
            XCTAssertEqual(
                CloudVaultCrypto.normalizedTokens(from: testCase.text),
                testCase.normalizedTokens,
                testCase.id
            )
            XCTAssertEqual(
                CloudVaultCrypto.exactPhraseTokensForContract(from: testCase.text),
                testCase.exactPhraseTokens,
                testCase.id
            )
        }

        for testCase in fixture.semanticFeatureCases {
            XCTAssertEqual(
                CloudVaultCrypto.semanticFeatureNamesForContract(from: testCase.text),
                testCase.features,
                testCase.id
            )
        }
    }

    func test_hashOperationsMatchSharedContractAndRemainBounded() throws {
        let fixture = try Self.loadFixture()
        let primaryKey = try Self.data(hex: fixture.primaryKeyHex)
        let alternateKey = try Self.data(hex: fixture.alternateKeyHex)

        for testCase in fixture.hashCases {
            let key = testCase.key == "alternate" ? alternateKey : primaryKey
            let text = try testCase.resolvedText()
            let hashes: [String]
            switch testCase.operation {
            case "token":
                hashes = try CloudVaultCrypto.tokenHashes(for: text, keyData: key, limit: testCase.limit)
            case "index":
                hashes = try CloudVaultCrypto.searchIndexTokenHashes(for: text, keyData: key, limit: testCase.limit)
            case "query":
                hashes = try CloudVaultCrypto.searchQueryTokenHashes(for: text, keyData: key, limit: testCase.limit)
            case "semantic":
                hashes = try CloudVaultCrypto.semanticHashes(for: text, keyData: key, limit: testCase.limit)
            default:
                XCTFail("Unknown operation \(testCase.operation) in \(testCase.id)")
                continue
            }
            XCTAssertEqual(hashes, testCase.expected, testCase.id)
            XCTAssertLessThanOrEqual(hashes.count, max(0, testCase.limit), testCase.id)
        }

        let isolationCases = Dictionary(grouping: fixture.hashCases.compactMap { testCase in
            testCase.isolationGroup.map { ($0, testCase) }
        }, by: \.0)
        for (group, entries) in isolationCases {
            XCTAssertEqual(entries.count, 2, group)
            let outputs = entries.map { Set($0.1.expected) }
            XCTAssertTrue(outputs[0].isDisjoint(with: outputs[1]), group)
        }
    }

    private static func loadFixture() throws -> SearchContractFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-search-contract.json")
            .standardizedFileURL
        return try JSONDecoder().decode(SearchContractFixture.self, from: Data(contentsOf: url))
    }

    private static func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw FixtureError.invalidHex }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw FixtureError.invalidHex }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

private struct SearchContractFixture: Decodable {
    let schema: String
    let primaryKeyHex: String
    let alternateKeyHex: String
    let tokenizationCases: [TokenizationCase]
    let semanticFeatureCases: [SemanticFeatureCase]
    let hashCases: [HashCase]
}

private struct TokenizationCase: Decodable {
    let id: String
    let text: String
    let normalizedTokens: [String]
    let exactPhraseTokens: [String]
}

private struct SemanticFeatureCase: Decodable {
    let id: String
    let text: String
    let features: [String]
}

private struct HashCase: Decodable {
    let id: String
    let isolationGroup: String?
    let operation: String
    let key: String
    let text: String?
    let input: GeneratedInput?
    let limit: Int
    let expected: [String]

    func resolvedText() throws -> String {
        if let text { return text }
        guard let input, input.kind == "numberedTokens", input.count.signum() >= 0 else {
            throw FixtureError.invalidInput
        }
        return (0..<input.count).map { "\(input.prefix)\($0)" }.joined(separator: " ")
    }
}

private struct GeneratedInput: Decodable {
    let kind: String
    let prefix: String
    let count: Int
}

private enum FixtureError: Error {
    case invalidHex
    case invalidInput
}
