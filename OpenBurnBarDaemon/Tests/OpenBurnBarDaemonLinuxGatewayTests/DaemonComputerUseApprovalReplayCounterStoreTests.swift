import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class DaemonComputerUseApprovalReplayCounterStoreTests: XCTestCase {
    func testSeparateInstancesSerializeOneFileHighWaterMark() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-counter-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("counters.json", isDirectory: false)
        let stores = [
            DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL),
            DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        ]
        let failures = Locked([String]())

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            do {
                _ = try stores[index % stores.count].commit(
                    peerNodeID: "phone-peer",
                    counter: UInt64(index + 1)
                )
            } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }

        XCTAssertTrue(failures.read().isEmpty, failures.read().joined(separator: "\n"))
        let independentlyConstructed = DaemonComputerUseApprovalReplayCounterStore(fileURL: fileURL)
        XCTAssertEqual(
            try independentlyConstructed.commit(peerNodeID: "phone-peer", counter: 64),
            .replay(lastSeen: 64)
        )
    }
}
