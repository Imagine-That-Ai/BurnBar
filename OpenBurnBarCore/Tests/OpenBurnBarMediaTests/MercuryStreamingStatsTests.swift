import XCTest
@testable import OpenBurnBarMedia

final class MercuryStreamingStatsTests: XCTestCase {
    func testRtcStatsRoundTripCarriesBenchmarkFields() throws {
        let health = MercuryRuntimeHealthSnapshot(
            timestampMillis: 1_777_000,
            cpuUsagePercent: 42.5,
            batteryLevelPercent: 81,
            isCharging: true,
            isLowPowerModeEnabled: false,
            thermalState: .fair
        )
        let stats = MercuryRtcStatsSnapshot(
            timestampMillis: 1_777_001,
            codec: .hevc,
            wireVersion: .v2,
            targetBitsPerSecond: 4_000_000,
            actualBitsPerSecond: 3_800_000,
            pacerQueueDepth: 2,
            decodedFramesPerSecond: 59.7,
            presentTimeErrorMillis: 3.5,
            freezeCount: 1,
            longTermReferenceRecoveries: 2,
            fecRecoveredBytes: 1_024,
            idrFallbacks: 1,
            gopLossRate: 0.03,
            roundTripMillis: 80,
            packetLossRate: 0.01,
            networkJitterMillis: 7.5,
            contentMode: .screenText,
            runtimeHealth: health
        )

        let decoded = try JSONDecoder().decode(
            MercuryRtcStatsSnapshot.self,
            from: JSONEncoder().encode(stats)
        )

        XCTAssertEqual(decoded, stats)
    }

    func testDefaultImpairmentMatrixMatchesLaunchGateShape() {
        XCTAssertEqual(MercuryImpairmentScenario.defaultMatrix.count, 15)
        XCTAssertTrue(MercuryImpairmentScenario.defaultMatrix.contains(
            MercuryImpairmentScenario(packetLossPercent: 10, roundTripMillis: 300)
        ))
    }

    func testRuntimeHealthProbeAlwaysReturnsTimestampAndThermalState() {
        let snapshot = MercuryRuntimeHealthProbe.snapshot(timestampMillis: 123)

        XCTAssertEqual(snapshot.timestampMillis, 123)
        XCTAssertNotNil(MercuryThermalState(rawValue: snapshot.thermalState.rawValue))
        #if canImport(Darwin)
        XCTAssertNotNil(snapshot.cpuUsagePercent)
        XCTAssertGreaterThanOrEqual(snapshot.cpuUsagePercent ?? -1, 0)
        #endif
    }
}
