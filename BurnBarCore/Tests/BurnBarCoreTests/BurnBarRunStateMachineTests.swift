import XCTest
@testable import BurnBarCore

final class BurnBarRunStateMachineTests: XCTestCase {
    func test_runStateMachine_allowsReviewedTransitions() {
        XCTAssertTrue(BurnBarRunStateMachine.canTransition(from: .idle, to: .planning))
        XCTAssertTrue(BurnBarRunStateMachine.canTransition(from: .planning, to: .awaitingApproval))
        XCTAssertTrue(BurnBarRunStateMachine.canTransition(from: .executingTool, to: .awaitingApproval))
        XCTAssertTrue(BurnBarRunStateMachine.canTransition(from: .waitingOnCompanion, to: .awaitingApproval))
        XCTAssertTrue(BurnBarRunStateMachine.canTransition(from: .failed, to: .planning))
    }

    func test_runStateMachine_rejectsInvalidTransitions() {
        XCTAssertFalse(BurnBarRunStateMachine.canTransition(from: .completed, to: .planning))
        XCTAssertThrowsError(try BurnBarRunStateMachine.validatedTransition(from: .completed, to: .planning))
    }
}
