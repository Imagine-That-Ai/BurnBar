import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class ElderWandPanelExecutionGateTests: XCTestCase {
    func testCancelledWaiterIsRemovedAndLaterWorkCanRun() async throws {
        let gate = ElderWandPanelExecutionGate()
        let latch = PanelGateTestLatch()
        let executionCounter = PanelGateExecutionCounter()
        let route = Self.route()

        let owner = Task {
            try await gate.perform(route: route) {
                await latch.holdUntilReleased()
                return "owner"
            }
        }
        await latch.waitUntilHeld()

        let waiter = Task {
            try await gate.perform(route: route) {
                await executionCounter.increment()
                return "cancelled waiter ran"
            }
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("A cancelled queued panel must not execute.")
        } catch is CancellationError {
            // Expected.
        }

        await latch.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, "owner")
        let later = try await gate.perform(route: route) { "later" }
        XCTAssertEqual(later, "later")
        let executionCount = await executionCounter.value()
        XCTAssertEqual(executionCount, 0)
    }

    private static func route() -> BurnBarProviderRoute {
        BurnBarProviderRoute(
            providerID: "anthropic",
            providerDisplayName: "Anthropic",
            credentialSlotID: "shared-account",
            credentialSlotLabel: "Shared account",
            baseURL: "https://api.anthropic.com/v1",
            requestedModel: "claude-haiku-4-5",
            resolvedModelID: "claude-haiku-4-5",
            canonicalModelID: "claude-haiku-4-5",
            apiKey: "test-key",
            pricing: .defaultFallback,
            formatFamily: .anthropic
        )
    }
}

private actor PanelGateTestLatch {
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdUntilReleased() async {
        held = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        guard !held else { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PanelGateExecutionCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
