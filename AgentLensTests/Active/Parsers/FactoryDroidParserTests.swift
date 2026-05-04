import XCTest
@testable import OpenBurnBar

final class FactoryDroidParserTests: XCTestCase {
    func testParseEmptyDirectory() async throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-factory-parser-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let parser = TestableFactoryDroidParser(testSessionsPath: tempRoot)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }
    
    func testProviderReturnsCorrectValue() {
        let parser = FactoryDroidParser()
        XCTAssertEqual(parser.provider, .factory)
    }
}
