import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonSocketRPCCoverageTests: XCTestCase {
    func testEveryBurnBarRPCMethodMapsToDaemonHandler() {
        let handled = BurnBarDaemonSocketRPCCoverage.allHandled
        let allMethods = Set(BurnBarRPCMethod.allCases)

        for method in BurnBarRPCMethod.allCases {
            XCTAssertTrue(
                handled.contains(method),
                "BurnBarRPCMethod.\(method) (\(method.rawValue)) is not mapped to a daemon socket handler domain"
            )
            XCTAssertNotNil(
                BurnBarDaemonSocketRPCCoverage.domain(for: method),
                "BurnBarRPCMethod.\(method) (\(method.rawValue)) has no handler domain assignment"
            )
        }

        XCTAssertEqual(
            handled,
            allMethods,
            "Daemon handler registry must cover exactly BurnBarRPCMethod.allCases with no extras"
        )
    }

    func testHandlerDomainsAreDisjoint() {
        let domains: [Set<BurnBarRPCMethod>] = [
            BurnBarDaemonSocketRPCCoverage.lifecycle,
            BurnBarDaemonSocketRPCCoverage.config,
            BurnBarDaemonSocketRPCCoverage.usage,
            BurnBarDaemonSocketRPCCoverage.tooling,
            BurnBarDaemonSocketRPCCoverage.computerUse,
            BurnBarDaemonSocketRPCCoverage.missionControl,
            BurnBarDaemonSocketRPCCoverage.client,
            BurnBarDaemonSocketRPCCoverage.runWorkspaceApproval,
            BurnBarDaemonSocketRPCCoverage.search
        ]

        for (index, left) in domains.enumerated() {
            for right in domains[(index + 1)...] {
                XCTAssertTrue(
                    left.isDisjoint(with: right),
                    "RPC handler domains must not overlap: \(left) intersects \(right)"
                )
            }
        }
    }
}
