import OpenBurnBarEngine
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
            BurnBarDaemonSocketRPCCoverage.auth,
            BurnBarDaemonSocketRPCCoverage.lifecycle,
            BurnBarDaemonSocketRPCCoverage.config,
            BurnBarDaemonSocketRPCCoverage.usage,
            BurnBarDaemonSocketRPCCoverage.chat,
            BurnBarDaemonSocketRPCCoverage.observability,
            BurnBarDaemonSocketRPCCoverage.membership,
            BurnBarDaemonSocketRPCCoverage.tooling,
            BurnBarDaemonSocketRPCCoverage.computerUse,
            BurnBarDaemonSocketRPCCoverage.media,
            BurnBarDaemonSocketRPCCoverage.missionControl,
            BurnBarDaemonSocketRPCCoverage.client,
            BurnBarDaemonSocketRPCCoverage.runWorkspaceApproval,
            BurnBarDaemonSocketRPCCoverage.search,
            BurnBarDaemonSocketRPCCoverage.memory,
            BurnBarDaemonSocketRPCCoverage.code,
            BurnBarDaemonSocketRPCCoverage.databaseRecovery,
            BurnBarDaemonSocketRPCCoverage.inbox
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

    func testInboxPresentationMethodsUseInboxDomain() {
        let methods: Set<BurnBarRPCMethod> = [
            .inboxPresentationList,
            .inboxPresentationGet,
            .inboxPresentationMutate,
            .inboxPresentationMarkAllRead
        ]
        XCTAssertTrue(methods.isSubset(of: BurnBarDaemonSocketRPCCoverage.inbox))
        for method in methods {
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), "inbox")
        }
    }

    func testChatMethodsUseChatDomain() {
        for method in [
            BurnBarRPCMethod.chatThreadList,
            .chatThreadGet,
            .chatMessageAppend
        ] {
            XCTAssertTrue(BurnBarDaemonSocketRPCCoverage.chat.contains(method))
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), "chat")
        }
    }
}
