import XCTest
@testable import OpenBurnBarMedia

final class LatestFrameMailboxTests: XCTestCase {
    func testCoalescesRapidSubmitsToLatestValue() async {
        let consumed = LockedBox<[Int]>([])
        let mailbox = LatestFrameMailbox<Int> { value in
            try? await Task.sleep(nanoseconds: 20_000_000)
            consumed.mutate { $0.append(value) }
        }
        mailbox.submit(1)
        mailbox.submit(2)
        mailbox.submit(3)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let values = consumed.value
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last, 3)
        XCTAssertLessThan(values.count, 3, "A 3-submit burst must not start 3 pumps")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
