import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarDaemonMetricsCountersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BurnBarDaemonMetricsCounters._resetForTesting()
    }

    func test_snapshotTracksRPCRequestsAndErrors() {
        BurnBarDaemonMetricsCounters.recordRPCRequest()
        BurnBarDaemonMetricsCounters.recordRPCRequest()
        BurnBarDaemonMetricsCounters.recordRPCError()

        let counters = BurnBarDaemonMetricsCounters.snapshot()
        XCTAssertEqual(counters["rpc_requests_total"], 2)
        XCTAssertEqual(counters["rpc_errors_total"], 1)
    }

    func test_snapshotTracksRPCLatencyP95() {
        BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: 10)
        BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: 20)
        BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: 100)
        BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: 200)

        let counters = BurnBarDaemonMetricsCounters.snapshot()
        XCTAssertEqual(counters["rpc_latency_ms_p95"], 185)
    }

    func test_liveMetricsSnapshotMergesRPCCounters() {
        BurnBarDaemonMetricsCounters.recordRPCRequest()

        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: true)
        XCTAssertEqual(snapshot.counters["rpc_requests_total"], 1)
        XCTAssertEqual(snapshot.counters["gateway_enabled"], 1)
    }
}
