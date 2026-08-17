@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarFleetMachineStatusProbeTests: XCTestCase {
    func testCPUPercent_usesDeltaBetweenConsecutiveHostSamples() {
        let queue = SampleQueue(samples: [
            BurnBarFleetCPUSample(user: 90, system: 10, idle: 0, nice: 0),
            BurnBarFleetCPUSample(user: 100, system: 20, idle: 80, nice: 0)
        ])
        let probe = BurnBarFleetMachineStatusProbe(cpuSampleProvider: { queue.next() })

        XCTAssertEqual(probe.read().cpuPercent, 0)
        XCTAssertEqual(probe.read().cpuPercent, 20)
    }

    func testCPUPercent_counterReset_degradesOneSampleThenReestablishesBaseline() {
        let queue = SampleQueue(samples: [
            BurnBarFleetCPUSample(user: 100, system: 0, idle: 0, nice: 0),
            BurnBarFleetCPUSample(user: 5, system: 0, idle: 0, nice: 0),
            BurnBarFleetCPUSample(user: 15, system: 10, idle: 0, nice: 0)
        ])
        let probe = BurnBarFleetMachineStatusProbe(cpuSampleProvider: { queue.next() })

        XCTAssertEqual(probe.read().cpuPercent, 0)
        XCTAssertNil(probe.read().cpuPercent)
        XCTAssertEqual(probe.read().cpuPercent, 100)
    }
}

private final class SampleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [BurnBarFleetCPUSample]

    init(samples: [BurnBarFleetCPUSample]) {
        self.samples = samples
    }

    func next() -> BurnBarFleetCPUSample? {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        return samples.removeFirst()
    }
}
