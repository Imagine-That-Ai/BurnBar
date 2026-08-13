#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

@MainActor
final class ComputerUseSafariCoordinatorBoundaryTests: XCTestCase {
    private func makeCoordinator(
        browserDispatcher: ComputerUseSessionCoordinator.BrowserDispatcher? = nil
    ) -> ComputerUseSessionCoordinator {
        ComputerUseSessionCoordinator(
            configuration: ComputerUseSessionCoordinator.Configuration(
                userId: "uid-safari-boundary",
                macHostNodeId: "mac-safari-boundary",
                entitlement: ComputerUseEntitlementSnapshot(
                    isActive: true,
                    productId: "hosted_computer_use_sync",
                    allowsBrowser: true
                ),
                quotaUsage: ComputerUseQuotaUsage(dayKey: "2026-08-10"),
                auditBaseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("computer-use-safari-boundary-\(UUID().uuidString)", isDirectory: true),
                macAppVersion: "test"
            ),
            browserDispatcher: browserDispatcher,
            approvalPresenter: { request, _ in
                HermesRealtimeRelayApprovalResponse(
                    approvalId: request.approvalId,
                    decision: .approve,
                    respondedBy: "test",
                    respondedAt: Date()
                )
            }
        )
    }

    private func safariAction(
        kind: BurnBarSafariActionKind = .click,
        url: String? = "https://example.com/checkout"
    ) -> ComputerUseAction {
        .safari(SafariActionDescriptor(
            kind: kind,
            safariSessionId: "safari-session",
            tabId: 17,
            expectedNavigationEpoch: 4,
            selector: "#continue",
            url: url
        ))
    }

    private func invocation() -> BurnBarToolInvocation {
        BurnBarToolInvocation(
            callID: "call-safari-boundary",
            runID: BurnBarRunID(rawValue: "run-safari-boundary"),
            tool: .browserClick,
            arguments: .object([:]),
            requestedBy: BurnBarClientID(rawValue: "test"),
            requestedAt: Date()
        )
    }

    func testSafariActionsUseBrowserQuotaWithoutPhoneCapExemption() {
        for kind in [BurnBarSafariActionKind.pageContext, .click, .runJavaScript] {
            let action = safariAction(kind: kind)
            let localPolicy = ComputerUseSessionCoordinator.quotaReservationPolicy(
                for: action,
                originatedFromPhone: false
            )
            let phonePolicy = ComputerUseSessionCoordinator.quotaReservationPolicy(
                for: action,
                originatedFromPhone: true
            )

            XCTAssertEqual(localPolicy.actionClass, .browser)
            XCTAssertFalse(localPolicy.exemptsMeteredCap)
            XCTAssertEqual(phonePolicy.actionClass, .browser)
            XCTAssertFalse(
                phonePolicy.exemptsMeteredCap,
                "Safari work must never inherit the phone-control metering exemption"
            )
        }
    }

    func testSafariScopeUsesOnlyExplicitPageMetadata() {
        let coordinator = makeCoordinator()

        XCTAssertEqual(
            coordinator.scopeContext(for: safariAction()),
            ComputerUseScopeContext(
                url: "https://example.com/checkout",
                bundleId: "com.apple.Safari"
            )
        )
        XCTAssertEqual(
            coordinator.scopeContext(for: safariAction(url: nil)),
            ComputerUseScopeContext(
                url: nil,
                bundleId: "com.apple.Safari"
            ),
            "A Safari action without an explicit URL must not borrow an unrelated frontmost-window URL"
        )
    }

    func testSafariDispatchRefusesExecutionOutsideDaemonAuthority() async {
        var browserDispatchCount = 0
        let coordinator = makeCoordinator { _ in
            browserDispatchCount += 1
            return .object(["unexpected": .bool(true)])
        }

        do {
            _ = try await coordinator.dispatch(
                action: safariAction(),
                invocation: invocation()
            )
            XCTFail("App-side Safari dispatch must fail closed")
        } catch let error as ComputerUseSessionCoordinator.CoordinatorError {
            XCTAssertEqual(
                error,
                .unsupportedExecutionSurface(ComputerUseExecutionSurface.safariExtension.rawValue)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            browserDispatchCount,
            0,
            "Safari actions must not be reinterpreted by the managed-browser dispatcher"
        )
    }
}
#endif
