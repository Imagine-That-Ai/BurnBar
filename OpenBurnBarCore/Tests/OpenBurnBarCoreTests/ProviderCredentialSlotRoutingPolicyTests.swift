import XCTest
@testable import OpenBurnBarCore

final class ProviderCredentialSlotRoutingPolicyTests: XCTestCase {
    func testPastResetMessageRecoversExhaustedSlot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let slot = BurnBarProviderCredentialSlot(
            label: "Z.ai Coding Plan",
            status: .exhausted,
            lastStatusMessage: "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-05-18 03:56:03",
            updatedAt: now
        )

        XCTAssertEqual(
            BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: slot, now: now),
            .ready
        )
        XCTAssertTrue(
            BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(slot: slot, hasCredential: true, now: now)
        )
    }

    func testFutureResetMessageKeepsSlotCoolingDown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let futureReset = formattedResetDate(now.addingTimeInterval(3600))
        let slot = BurnBarProviderCredentialSlot(
            label: "Z.ai Coding Plan",
            status: .exhausted,
            lastStatusMessage: "Weekly/Monthly Limit Exhausted. Your limit will reset at \(futureReset)",
            updatedAt: now
        )

        XCTAssertEqual(
            BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: slot, now: now),
            .coolingDown
        )
        XCTAssertFalse(
            BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(slot: slot, hasCredential: true, now: now)
        )
    }

    func testStaleExhaustionWithoutResetCanRetry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let slot = BurnBarProviderCredentialSlot(
            label: "DeepSeek",
            status: .exhausted,
            lastStatusMessage: "OpenBurnBar provider request failed with status 402: Insufficient Balance",
            updatedAt: now.addingTimeInterval(-31 * 60)
        )

        XCTAssertEqual(
            BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: slot, now: now),
            .ready
        )
    }

    func testRecentExhaustionWithoutResetRemainsBlocked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let slot = BurnBarProviderCredentialSlot(
            label: "DeepSeek",
            status: .exhausted,
            lastStatusMessage: "OpenBurnBar provider request failed with status 402: Insufficient Balance",
            updatedAt: now.addingTimeInterval(-5 * 60)
        )

        XCTAssertEqual(
            BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: slot, now: now),
            .exhausted
        )
    }

    private func formattedResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
