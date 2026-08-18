import XCTest
@testable import OpenBurnBar

/// Rung 1 is the rung that can lie: it is the one making claims about whether
/// a server is up. These pin the claims.
final class PlasmaRouteTests: XCTestCase {

    // MARK: Classification

    func testOnlyTheThreeRealGatewaysAreGateways() {
        // BurnBar has exactly three OpenAI-compatible local servers a chat can
        // be routed through. Everything else spawns a CLI.
        let gateways = ChatBackendID.allCases
            .map(PlasmaRouteCatalog.route(for:))
            .filter { $0.kind == .gateway }
            .map(\.backend)
        XCTAssertEqual(Set(gateways), [.hermes, .openclaw, .piAgent])
    }

    func testGatewaysCarryAnEndpointAndDirectRoutesDoNot() {
        XCTAssertEqual(PlasmaRouteCatalog.route(for: .hermes).endpointLabel, ":8642")
        XCTAssertEqual(PlasmaRouteCatalog.route(for: .openclaw).endpointLabel, ":18789")
        XCTAssertEqual(PlasmaRouteCatalog.route(for: .piAgent).endpointLabel, ":8765")
        XCTAssertNil(PlasmaRouteCatalog.route(for: .codex).endpointLabel, "a subprocess has no port")
    }

    func testEveryBackendGetsExactlyOneRoute() {
        for backend in ChatBackendID.allCases {
            XCTAssertEqual(PlasmaRouteCatalog.route(for: backend).id, backend.rawValue)
        }
    }

    func testGatewaysSortAheadOfDirectRoutes() {
        // A dead endpoint is the most valuable thing this rung can report, so
        // the routes that can be dead lead.
        let ordered = PlasmaRouteCatalog.routes(forEnabled: [.codex, .hermes, .droid, .piAgent])
        XCTAssertEqual(ordered.map(\.kind), [.gateway, .gateway, .direct, .direct])
        XCTAssertEqual(ordered.prefix(2).map(\.backend), [.hermes, .piAgent], "enabled order is preserved within a kind")
    }

    func testDisabledBackendsAreAbsentFromTheRung() {
        let routes = PlasmaRouteCatalog.routes(forEnabled: [.codex])
        XCTAssertEqual(routes.map(\.backend), [.codex])
    }

    // MARK: Status

    func testAuthRejectionOutranksAvailability() {
        // A server answering 401 *is* reachable. Reporting it as live sends the
        // user hunting for a network problem that does not exist.
        let status = PlasmaRouteStatus.resolve(
            probe: PlasmaRouteProbe(isAvailable: true, isAuthRejected: true, hasProbed: true)
        )
        XCTAssertEqual(status, .authRejected)
    }

    func testUnprobedRouteIsNotReportedAsOffline() {
        // We only probe the active gateway. Claiming an uncontacted one is down
        // would send the user to restart a server that was fine.
        let status = PlasmaRouteStatus.resolve(
            probe: PlasmaRouteProbe(isAvailable: false, isAuthRejected: false, hasProbed: false)
        )
        XCTAssertEqual(status, .unknown)
    }

    func testProbedAndSilentIsOffline() {
        let status = PlasmaRouteStatus.resolve(
            probe: PlasmaRouteProbe(isAvailable: false, isAuthRejected: false, hasProbed: true)
        )
        XCTAssertEqual(status, .offline)
    }

    func testAvailableIsLive() {
        let status = PlasmaRouteStatus.resolve(
            probe: PlasmaRouteProbe(isAvailable: true, isAuthRejected: false, hasProbed: true)
        )
        XCTAssertEqual(status, .live)
    }

    func testOnlyBrokenStatesAreUnusableAndOnlyTheyOfferARemedy() {
        // The invariant the notice row depends on: a remedy exists exactly when
        // something is actually wrong.
        let states: [PlasmaRouteStatus] = [.live, .ready, .unknown, .authRejected, .offline]
        for state in states {
            XCTAssertEqual(
                state.remedy == nil,
                state.isUsable,
                "\(state) disagrees about whether it is broken"
            )
        }
    }

    func testStatusShapeDistinguishesTheThreeOutcomesWithoutColour() {
        // `AgentPresenceDot` holds the line that "colour is never the only
        // signal", and the pill presentation of this rung uses it. The orb
        // presentation has to make the same promise or the two disagree about
        // who can read them.
        XCTAssertEqual(PlasmaRouteStatus.live.dotStyle, .filled)
        XCTAssertEqual(PlasmaRouteStatus.ready.dotStyle, .filled)
        XCTAssertEqual(PlasmaRouteStatus.authRejected.dotStyle, .dashed)
        XCTAssertEqual(PlasmaRouteStatus.offline.dotStyle, .hollow)
        XCTAssertEqual(PlasmaRouteStatus.unknown.dotStyle, .hollow)
    }

    func testUsableStatesNeverShareAShapeWithBrokenOnes() {
        let usable = Set([PlasmaRouteStatus.live, .ready].map(\.dotStyle))
        let broken = Set([PlasmaRouteStatus.authRejected, .offline].map(\.dotStyle))
        XCTAssertTrue(usable.isDisjoint(with: broken), "shape must survive colourblindness")
    }

    func testEveryStatusHasAWordForTheLabel() {
        for state: PlasmaRouteStatus in [.live, .ready, .unknown, .authRejected, .offline] {
            XCTAssertFalse(state.word.isEmpty)
        }
    }

    func testRemediesNameAConcreteNextAction() {
        // "Something went wrong" is not a remedy.
        XCTAssertEqual(PlasmaRouteStatus.authRejected.remedy?.contains("Settings"), true)
        XCTAssertEqual(PlasmaRouteStatus.offline.remedy?.contains("Start"), true)
    }
}
