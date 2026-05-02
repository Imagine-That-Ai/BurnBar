import XCTest
@testable import OpenBurnBar

final class OpenBurnBarDaemonSupervisorTests: XCTestCase {

    // MARK: - advance(_:daemonIsHealthy:daemonIsInstalled:)

    func test_advance_idleToHealthy_whenDaemonHealthy() {
        let now = Date()
        let state = OpenBurnBarDaemonSupervisor.advance(
            from: .idle,
            daemonIsHealthy: true,
            daemonIsInstalled: true,
            now: now
        )
        XCTAssertEqual(state, .healthy)
    }

    func test_advance_healthyToHealthy_whenDaemonHealthy() {
        let now = Date()
        let state = OpenBurnBarDaemonSupervisor.advance(
            from: .healthy,
            daemonIsHealthy: true,
            daemonIsInstalled: true,
            now: now
        )
        XCTAssertEqual(state, .healthy)
    }

    func test_advance_idleToRetrying_whenDaemonUnhealthy() {
        let now = Date()
        let state = OpenBurnBarDaemonSupervisor.advance(
            from: .idle,
            daemonIsHealthy: false,
            daemonIsInstalled: true,
            now: now
        )
        if case .retrying(let failures, _) = state {
            XCTAssertEqual(failures, 1)
        } else {
            XCTFail("Expected .retrying, got \(state)")
        }
    }

    func test_advance_healthyToRetrying_whenDaemonUnhealthy() {
        let now = Date()
        let state = OpenBurnBarDaemonSupervisor.advance(
            from: .healthy,
            daemonIsHealthy: false,
            daemonIsInstalled: true,
            now: now
        )
        if case .retrying(let failures, _) = state {
            XCTAssertEqual(failures, 1)
        } else {
            XCTFail("Expected .retrying, got \(state)")
        }
    }

    func test_advance_retryingIncrementsFailureCount() {
        let now = Date()
        let state1 = OpenBurnBarDaemonSupervisor.advance(
            from: .idle,
            daemonIsHealthy: false,
            daemonIsInstalled: true,
            now: now
        )
        XCTAssertEqual(state1.consecutiveFailures, 1)

        let state2 = OpenBurnBarDaemonSupervisor.advance(
            from: state1,
            daemonIsHealthy: false,
            daemonIsInstalled: true,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(state2.consecutiveFailures, 2)

        let state3 = OpenBurnBarDaemonSupervisor.advance(
            from: state2,
            daemonIsHealthy: false,
            daemonIsInstalled: true,
            now: now.addingTimeInterval(7)
        )
        XCTAssertEqual(state3.consecutiveFailures, 3)
    }

    func test_advance_entersCrashLoopAfterThreshold() {
        let now = Date()
        let config = OpenBurnBarDaemonSupervisorConfig(crashLoopThreshold: 3)

        var state: OpenBurnBarDaemonSupervisionState = .idle
        for i in 1...3 {
            state = OpenBurnBarDaemonSupervisor.advance(
                from: state,
                daemonIsHealthy: false,
                daemonIsInstalled: true,
                config: config,
                now: now.addingTimeInterval(TimeInterval(i))
            )
        }
        // After threshold, should be crashLoop
        if case .crashLoop(let failures, _, _) = state {
            XCTAssertEqual(failures, 3)
        } else {
            XCTFail("Expected .crashLoop, got \(state)")
        }
    }

    func test_advance_healthyResetsFailureCount() {
        let now = Date()
        // Get into a retrying state
        let retrying = OpenBurnBarDaemonSupervisor.advance(
            from: .idle,
            daemonIsHealthy: false,
            daemonIsInstalled: true,
            now: now
        )
        XCTAssertEqual(retrying.consecutiveFailures, 1)

        // Daemon recovers
        let recovered = OpenBurnBarDaemonSupervisor.advance(
            from: retrying,
            daemonIsHealthy: true,
            daemonIsInstalled: true,
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(recovered, .healthy)
        XCTAssertEqual(recovered.consecutiveFailures, 0)
    }

    func test_advance_notInstalledResultsInIdle() {
        let now = Date()
        let state = OpenBurnBarDaemonSupervisor.advance(
            from: .healthy,
            daemonIsHealthy: false,
            daemonIsInstalled: false,
            now: now
        )
        XCTAssertEqual(state, .idle)
    }

    func test_advance_crashLoopRecoveryOnHealthyDaemon() {
        let now = Date()
        let config = OpenBurnBarDaemonSupervisorConfig(crashLoopThreshold: 2)
        let crashLoop: OpenBurnBarDaemonSupervisionState = .crashLoop(
            consecutiveFailures: 5,
            nextRetryAt: now.addingTimeInterval(30),
            detectedAt: now.addingTimeInterval(-60)
        )
        let recovered = OpenBurnBarDaemonSupervisor.advance(
            from: crashLoop,
            daemonIsHealthy: true,
            daemonIsInstalled: true,
            config: config,
            now: now
        )
        XCTAssertEqual(recovered, .healthy)
    }

    // MARK: - shouldProbeNow

    func test_shouldProbeNow_idle() {
        XCTAssertTrue(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: .idle))
    }

    func test_shouldProbeNow_healthy() {
        XCTAssertTrue(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: .healthy))
    }

    func test_shouldProbeNow_retryingBeforeBackoff() {
        let config = OpenBurnBarDaemonSupervisorConfig(backoffBaseDelay: 10)
        let now = Date()
        // Backoff hasn't elapsed
        let state: OpenBurnBarDaemonSupervisionState = .retrying(
            consecutiveFailures: 2,
            nextRetryAt: now.addingTimeInterval(5)
        )
        XCTAssertFalse(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: state, config: config, now: now))
    }

    func test_shouldProbeNow_retryingAfterBackoff() {
        let config = OpenBurnBarDaemonSupervisorConfig(backoffBaseDelay: 1)
        let now = Date()
        let state: OpenBurnBarDaemonSupervisionState = .retrying(
            consecutiveFailures: 2,
            nextRetryAt: now.addingTimeInterval(-1) // already passed
        )
        XCTAssertTrue(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: state, config: config, now: now))
    }

    func test_shouldProbeNow_crashLoopBeforeResetInterval() {
        let config = OpenBurnBarDaemonSupervisorConfig(crashLoopResetInterval: 300)
        let now = Date()
        let state: OpenBurnBarDaemonSupervisionState = .crashLoop(
            consecutiveFailures: 5,
            nextRetryAt: now.addingTimeInterval(30), // still in backoff
            detectedAt: now.addingTimeInterval(-10)   // detected 10s ago, reset at 300s
        )
        // Not past nextRetry, not past reset interval
        XCTAssertFalse(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: state, config: config, now: now))
    }

    func test_shouldProbeNow_crashLoopAfterBackoffExpires() {
        let config = OpenBurnBarDaemonSupervisorConfig(crashLoopResetInterval: 300)
        let now = Date()
        let state: OpenBurnBarDaemonSupervisionState = .crashLoop(
            consecutiveFailures: 5,
            nextRetryAt: now.addingTimeInterval(-1), // backoff expired
            detectedAt: now.addingTimeInterval(-10)
        )
        XCTAssertTrue(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: state, config: config, now: now))
    }

    func test_shouldProbeNow_crashLoopAfterResetIntervalExpires() {
        let config = OpenBurnBarDaemonSupervisorConfig(crashLoopResetInterval: 300)
        let now = Date()
        let state: OpenBurnBarDaemonSupervisionState = .crashLoop(
            consecutiveFailures: 5,
            nextRetryAt: now.addingTimeInterval(100), // still in backoff window
            detectedAt: now.addingTimeInterval(-310)    // detected over 300s ago
        )
        // Reset interval has elapsed even though backoff hasn't — allow probe
        XCTAssertTrue(OpenBurnBarDaemonSupervisor.shouldProbeNow(state: state, config: config, now: now))
    }

    // MARK: - resetAfterRepair

    func test_resetAfterRepair_returnsIdle() {
        let state = OpenBurnBarDaemonSupervisor.resetAfterRepair()
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Backoff calculation

    func test_backoff_increasesExponentially() {
        let config = OpenBurnBarDaemonSupervisorConfig(
            crashLoopThreshold: 10,
            backoffBaseDelay: 1.0,
            backoffMaxDelay: 300.0,
            jitterFactor: 0
        )
        let now = Date()

        var state: OpenBurnBarDaemonSupervisionState = .idle
        var delays: [TimeInterval] = []

        for i in 1...6 {
            state = OpenBurnBarDaemonSupervisor.advance(
                from: state,
                daemonIsHealthy: false,
                daemonIsInstalled: true,
                config: config,
                now: now.addingTimeInterval(Double(i) * 100)
            )
            if let nextRetry = state.nextRetryAt {
                let baseTime = now.addingTimeInterval(Double(i) * 100)
                let delay = nextRetry.timeIntervalSince(baseTime)
                delays.append(delay)
            }
        }

        // j=0 → delay ≈ 2^0 = 1s
        // j=1 → delay ≈ 2^1 = 2s
        // j=2 → delay ≈ 2^2 = 4s
        // j=3 → delay ≈ 2^3 = 8s
        // j=4 → delay ≈ 2^4 = 16s
        // j=5 → delay ≈ 2^5 = 32s
        // With jitter=0, delays should be exact powers of 2
        XCTAssertEqual(delays[0], 1.0, accuracy: 0.01)
        XCTAssertEqual(delays[1], 2.0, accuracy: 0.01)
        XCTAssertEqual(delays[2], 4.0, accuracy: 0.01)
        XCTAssertEqual(delays[3], 8.0, accuracy: 0.01)
        XCTAssertEqual(delays[4], 16.0, accuracy: 0.01)
        XCTAssertEqual(delays[5], 32.0, accuracy: 0.01)
    }

    func test_backoff_cappedAtMaxDelay() {
        let config = OpenBurnBarDaemonSupervisorConfig(
            crashLoopThreshold: 100,
            backoffBaseDelay: 1.0,
            backoffMaxDelay: 10.0,
            jitterFactor: 0
        )
        let now = Date()

        var state: OpenBurnBarDaemonSupervisionState = .idle
        for i in 1...20 {
            state = OpenBurnBarDaemonSupervisor.advance(
                from: state,
                daemonIsHealthy: false,
                daemonIsInstalled: true,
                config: config,
                now: now.addingTimeInterval(Double(i) * 100)
            )
        }

        if let nextRetry = state.nextRetryAt {
            let baseTime = now.addingTimeInterval(20.0 * 100)
            let delay = nextRetry.timeIntervalSince(baseTime)
            // 2^19 = 524288 but capped at 10s
            XCTAssertEqual(delay, 10.0, accuracy: 0.01)
        }
    }
}
