import XCTest

@testable import BurnBar

final class FleetChatOpenPolicyTests: XCTestCase {
    func test_noConsentRequestsSheet() {
        XCTAssertEqual(
            FleetChatOpenPolicy.decision(consentShown: false, requestedMode: .orchestrator),
            .showConsent
        )
    }

    func test_consentShownPresentsOrchestrator() {
        XCTAssertEqual(
            FleetChatOpenPolicy.decision(consentShown: true, requestedMode: .orchestrator),
            .present(mode: .orchestrator)
        )
    }

    func test_pendingAllowPresentsOrchestratorAndDenyDoesNot() {
        XCTAssertEqual(
            FleetChatOpenPolicy.afterConsent(pendingOrchestrator: true, allowed: true),
            .presentOrchestrator
        )
        XCTAssertEqual(
            FleetChatOpenPolicy.afterConsent(pendingOrchestrator: true, allowed: false),
            .dismiss
        )
    }

    func test_fabDismissDoesNotForceOrchestrator() {
        XCTAssertEqual(
            FleetChatOpenPolicy.afterConsent(pendingOrchestrator: false, allowed: true),
            .dismiss
        )
        XCTAssertEqual(
            FleetChatOpenPolicy.decision(consentShown: true, requestedMode: nil),
            .present(mode: nil)
        )
    }
}
