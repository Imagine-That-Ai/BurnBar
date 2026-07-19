import XCTest
@testable import OpenBurnBar

@MainActor
final class SerialAsyncWorkQueueTests: XCTestCase {
    func testFIFOAndSingleHandlerConcurrency() async {
        let probe = QueueProbe()
        let queue = SerialAsyncWorkQueue<Item, Int>(identifier: \.id)
        defer { queue.stop(); probe.releaseAll() }
        let items = [Item(1, "one"), Item(2, "two"), Item(3, "three")]
        let first = probe.expectStarts(1)
        let second = probe.expectStarts(2)
        let third = probe.expectStarts(3)
        let allFinished = probe.expectFinishes(3)

        queue.start { await probe.run($0) }
        queue.enqueue(items)

        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(probe.started, ["main:one"])
        XCTAssertEqual(probe.active, 1)
        probe.release(items[0])

        await fulfillment(of: [second], timeout: 1)
        probe.release(items[1])
        await fulfillment(of: [third], timeout: 1)
        probe.release(items[2])
        await fulfillment(of: [allFinished], timeout: 1)

        XCTAssertEqual(probe.started, ["main:one", "main:two", "main:three"])
        XCTAssertEqual(probe.finished, probe.started)
        XCTAssertEqual(probe.maximumActive, 1)
        XCTAssertEqual(probe.active, 0)
    }

    func testSuppressesDuplicatesWhileInFlightAndQueued() async {
        let probe = QueueProbe()
        let queue = SerialAsyncWorkQueue<Item, Int>(identifier: \.id)
        defer { queue.stop(); probe.releaseAll() }
        let original = Item(1, "original")
        let duplicateInFlight = Item(1, "duplicate-in-flight")
        let queued = Item(2, "queued")
        let duplicateQueued = Item(2, "duplicate-queued")
        let first = probe.expectStarts(1)
        let second = probe.expectStarts(2)
        let bothFinished = probe.expectFinishes(2)

        queue.start { await probe.run($0) }
        queue.enqueue([original])
        await fulfillment(of: [first], timeout: 1)

        queue.enqueue([duplicateInFlight, queued, duplicateQueued])
        probe.release(original)
        await fulfillment(of: [second], timeout: 1)

        XCTAssertEqual(probe.started, ["main:original", "main:queued"])
        probe.release(queued)
        await fulfillment(of: [bothFinished], timeout: 1)
        XCTAssertEqual(probe.finished, probe.started)
        XCTAssertEqual(probe.maximumActive, 1)
    }

    func testAcceptsIDAgainAfterItsHandlerCompletes() async {
        let probe = QueueProbe()
        let queue = SerialAsyncWorkQueue<Item, Int>(identifier: \.id)
        defer { queue.stop(); probe.releaseAll() }
        let firstUse = Item(7, "first-use")
        let duplicate = Item(7, "duplicate")
        let witness = Item(8, "completion-witness")
        let secondUse = Item(7, "second-use")
        let first = probe.expectStarts(1)
        let witnessStarted = probe.expectStarts(2)
        let secondUseStarted = probe.expectStarts(3)
        let allFinished = probe.expectFinishes(3)

        queue.start { await probe.run($0) }
        queue.enqueue([firstUse, witness])
        await fulfillment(of: [first], timeout: 1)
        queue.enqueue([duplicate])

        probe.release(firstUse)
        await fulfillment(of: [witnessStarted], timeout: 1)
        queue.enqueue([secondUse])
        probe.release(witness)
        await fulfillment(of: [secondUseStarted], timeout: 1)

        XCTAssertEqual(
            probe.started,
            ["main:first-use", "main:completion-witness", "main:second-use"]
        )
        probe.release(secondUse)
        await fulfillment(of: [allFinished], timeout: 1)
        XCTAssertEqual(probe.finished, probe.started)
    }

    func testStopClearsQueueAndRestartDoesNotOverlapOldGeneration() async {
        let probe = QueueProbe()
        let queue = SerialAsyncWorkQueue<Item, Int>(identifier: \.id)
        defer { queue.stop(); probe.releaseAll() }
        let oldInFlight = Item(1, "in-flight")
        let oldQueued = Item(2, "queued")
        let restarted = Item(3, "restarted")
        let oldStarted = probe.expectStarts(1)
        let restartedStarted = probe.expectStarts(2)
        let bothFinished = probe.expectFinishes(2)

        queue.start { await probe.run($0, lane: "old") }
        queue.enqueue([oldInFlight, oldQueued])
        await fulfillment(of: [oldStarted], timeout: 1)

        queue.stop()
        queue.start { await probe.run($0, lane: "new") }
        queue.enqueue([restarted])
        await Task.yield()
        XCTAssertEqual(probe.started, ["old:in-flight"])
        XCTAssertEqual(probe.active, 1)

        probe.release(oldInFlight, lane: "old")
        await fulfillment(of: [restartedStarted], timeout: 1)
        XCTAssertEqual(probe.started, ["old:in-flight", "new:restarted"])
        XCTAssertEqual(probe.maximumActive, 1)

        probe.release(restarted, lane: "new")
        await fulfillment(of: [bothFinished], timeout: 1)
        XCTAssertEqual(probe.finished, probe.started)
        XCTAssertEqual(probe.active, 0)
    }
}

private struct Item: Sendable {
    let id: Int
    let name: String

    init(_ id: Int, _ name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
private final class QueueProbe {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var earlyReleases: Set<String> = []
    private var startWaiters: [Int: XCTestExpectation] = [:]
    private var finishWaiters: [Int: XCTestExpectation] = [:]

    func expectStarts(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) handler(s) started")
        startWaiters[count] = expectation
        return expectation
    }

    func expectFinishes(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) handler(s) finished")
        finishWaiters[count] = expectation
        return expectation
    }

    func run(_ item: Item, lane: String = "main") async {
        let key = "\(lane):\(item.name)"
        active += 1
        maximumActive = max(maximumActive, active)
        started.append(key)
        startWaiters.removeValue(forKey: started.count)?.fulfill()
        await withCheckedContinuation { continuation in
            if earlyReleases.remove(key) != nil {
                continuation.resume()
            } else {
                gates[key] = continuation
            }
        }
        active -= 1
        finished.append(key)
        finishWaiters.removeValue(forKey: finished.count)?.fulfill()
    }

    func release(_ item: Item, lane: String = "main") {
        let key = "\(lane):\(item.name)"
        if let gate = gates.removeValue(forKey: key) {
            gate.resume()
        } else {
            earlyReleases.insert(key)
        }
    }

    func releaseAll() {
        let blocked = gates.values
        gates.removeAll()
        blocked.forEach { $0.resume() }
    }
}
