import GRDB
import XCTest

@testable import BurnBar

@MainActor
final class DataStoreConcurrencyTests: XCTestCase {
    func testPrimaryQueueUsesBoundedBusyTimeout() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-concurrent-migrations-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let queue = try DataStore.makeDatabaseQueue(path: databaseURL.path)
        guard case .timeout(let seconds) = queue.configuration.busyMode else {
            return XCTFail("primary queue must wait for a bounded SQLite lock timeout")
        }

        XCTAssertEqual(seconds, 10)
    }
}
