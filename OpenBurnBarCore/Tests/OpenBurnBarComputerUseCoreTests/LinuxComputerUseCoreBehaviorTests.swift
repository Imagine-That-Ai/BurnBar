#if os(Linux)
import Foundation
import XCTest
@testable import OpenBurnBarComputerUseCore

/// Linux execution coverage for the platform-neutral Computer Use policy
/// substrate. These tests deliberately exercise deterministic contracts rather
/// than checking that XCTest can link the target; the same values are consumed
/// by the macOS coordinator and the Linux daemon.
final class LinuxComputerUseCoreBehaviorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testScopeMatcherDenyPrecedenceAndRuleBudgetAreDeterministic() {
        let allow = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("linux.allow.example"),
            effect: .allow,
            origin: .user,
            label: "Allow example",
            urlPrefix: "https://example.test",
            actionBudget: 2,
            createdAt: now.addingTimeInterval(-10)
        )
        let deny = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("linux.deny.private"),
            effect: .deny,
            origin: .builtIn,
            label: "Deny private path",
            urlPrefix: "https://example.test/private",
            createdAt: now
        )
        let context = ComputerUseScopeContext(url: "https://example.test/private/report")
        let matcher = ComputerUseScopeMatcher()

        XCTAssertEqual(
            matcher.evaluate(rules: [allow, deny], context: context, at: now),
            .denied(rule: deny.id)
        )
        XCTAssertEqual(
            matcher.evaluate(
                rules: [allow],
                context: ComputerUseScopeContext(url: "https://example.test/report"),
                budgetStates: [allow.id: ComputerUseScopeBudgetState(ruleId: allow.id, actionsConsumed: 2)],
                at: now
            ),
            .notMatched
        )
        XCTAssertEqual(
            matcher.evaluate(
                rules: [allow],
                context: ComputerUseScopeContext(url: "https://example.test/report"),
                budgetStates: [allow.id: ComputerUseScopeBudgetState(ruleId: allow.id, actionsConsumed: 1)],
                at: now
            ),
            .allowed(rule: allow.id)
        )
    }

    func testBuiltInDenyRegistryRejectsSensitiveLinuxBrowserDestinations() {
        let matcher = ComputerUseScopeMatcher()
        let probes: [(String, ComputerUseScopeContext)] = [
            ("file URL", ComputerUseScopeContext(url: "file:///etc/passwd", bundleId: "org.mozilla.firefox")),
            ("loopback", ComputerUseScopeContext(url: "http://127.0.0.1:8080/health", bundleId: "org.mozilla.firefox")),
            ("metadata", ComputerUseScopeContext(url: "http://metadata.google.internal/computeMetadata/v1")),
            ("OAuth", ComputerUseScopeContext(url: "https://accounts.google.com/o/oauth2/v2/auth?client_id=test"))
        ]

        for (label, context) in probes {
            guard case .denied = matcher.evaluate(
                rules: ComputerUseDenyRegistry.builtInRules,
                context: context,
                at: now
            ) else {
                XCTFail("built-in deny registry must reject (label)")
                continue
            }
        }
        XCTAssertTrue(ComputerUseDenyRegistry.isBuiltIn(ComputerUseScopeRuleID("builtin.browser_file_url")))
    }

    func testBudgetProjectorUsesStableThresholdsAndProjectionMath() {
        let normal = ComputerUseBudgetProjector.envelope(forProjectedMonthEnd: 1_499.99, monthToDate: 500, at: now)
        XCTAssertEqual(normal.level, .normal)
        XCTAssertEqual(normal.activeActionsPerRun, 50)

        let soft = ComputerUseBudgetProjector.envelope(forProjectedMonthEnd: 1_500, monthToDate: 750, at: now)
        XCTAssertEqual(soft.level, .softCap)
        XCTAssertEqual(soft.activeActionsPerRun, 25)
        XCTAssertEqual(soft.perUserDailySpendCeilingUSD, 2.5)

        let hard = ComputerUseBudgetProjector.envelope(forProjectedMonthEnd: 2_500, monthToDate: 1_250, at: now)
        XCTAssertEqual(hard.level, .hardCap)
        XCTAssertEqual(hard.activeActionsPerRun, 0)
        XCTAssertEqual(hard.activeSessionsPerDay, 0)

        XCTAssertEqual(
            ComputerUseBudgetProjector.projectMonthEnd(monthToDateUSD: 100, daysElapsed: 10, daysInMonth: 30),
            300,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ComputerUseBudgetProjector.projectMonthEnd(monthToDateUSD: 100, daysElapsed: 0, daysInMonth: 30),
            3_000,
            accuracy: 0.000_001
        )
    }

    func testActionDescriptorWireRoundTripPreservesAuditKindAndApprovalSummary() throws {
        let action = ComputerUseAction.browser(
            BrowserAction(
                kind: .goto,
                url: "https://example.test/dashboard",
                timeoutMillis: 4_000
            )
        )
        let encoded = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(ComputerUseAction.self, from: encoded)

        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.auditKind, "browser.goto")
        XCTAssertTrue(
            decoded.executableSummary(
                forApproval: ComputerUseScopeContext(url: "https://example.test/home")
            ).contains("Navigate to https://example.test/dashboard")
        )
    }

    func testCapabilityGateFailsClosedForKillSwitchAndDeniedScope() {
        let manifest = ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID("linux-session"),
            mode: .browser,
            trustMode: .manual,
            // Keep the fixture inside the wall-clock session limit. The gate
            // intentionally evaluates the timeout against the current clock.
            startedAt: Date(),
            userId: "linux-user",
            entitlementProductId: ComputerUseEntitlementSnapshot.hostedProductID,
            actionCap: 50,
            sessionTimeoutSeconds: 1_800
        )
        let session = ComputerUseSessionState(
            sessionId: manifest.sessionId,
            manifest: manifest,
            liveTrustMode: .manual,
            actionsExecuted: 0
        )
        let context = ComputerUseCapabilityContext(
            entitlement: ComputerUseEntitlementSnapshot(isActive: true, allowsBrowser: true),
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: "2023-11-14"),
            session: session,
            concurrentSessionActive: false,
            killSwitch: false,
            accessibilityTrusted: true
        )
        let action = ComputerUseAction.browser(BrowserAction(kind: .screenshot))
        let gate = DefaultComputerUseCapabilityGate()

        XCTAssertEqual(
            gate.check(action: action, scopeOutcome: .denied(rule: ComputerUseScopeRuleID("deny")), accessibilityDeny: nil, context: context),
            .denied(.scopeDenied)
        )
        let killContext = ComputerUseCapabilityContext(
            entitlement: context.entitlement,
            envelope: context.envelope,
            usage: context.usage,
            session: context.session,
            concurrentSessionActive: false,
            killSwitch: true,
            accessibilityTrusted: true
        )
        XCTAssertEqual(
            gate.check(action: action, scopeOutcome: .allowed(rule: ComputerUseScopeRuleID("allow")), accessibilityDeny: nil, context: killContext),
            .denied(.killSwitch)
        )
    }

    func testSafetyHarnessBlocksPostPanicInputAndUnauthorisedTrustEscalation() {
        let trusted = ComputerUseSafetyInvariantHarness.SessionModel(
            phase: .activeTrusted,
            liveTrust: .trusted,
            grantActive: true
        )
        let halted = ComputerUseSafetyInvariantHarness.transition(trusted, stimulus: .panic)
        XCTAssertEqual(halted.model.phase, .panicHalted)
        XCTAssertFalse(halted.model.grantActive)

        let input = ComputerUseSafetyInvariantHarness.transition(halted.model, stimulus: .inputAction)
        XCTAssertFalse(input.inputAllowed)
        XCTAssertTrue(input.audit.contains(.inputDeniedPanic))

        let manual = ComputerUseSafetyInvariantHarness.SessionModel(phase: .activeManual, liveTrust: .manual)
        let escalation = ComputerUseSafetyInvariantHarness.transition(manual, stimulus: .trustEscalateWithoutApproval)
        XCTAssertEqual(escalation.model.liveTrust, .manual)
        XCTAssertTrue(escalation.audit.contains(.trustEscalationRejected))
        XCTAssertTrue(ComputerUseSafetyInvariantHarness.verifyExhaustiveInvariants(maxDepth: 5).isEmpty)
    }
}
#else
import XCTest

/// The package keeps this source in the target on Apple so the Linux-only
/// behavior suite does not alter the macOS test graph.
final class LinuxComputerUseCoreBehaviorTests: XCTestCase {
    func testLinuxSuiteIsPlatformGated() {
        XCTAssertFalse(ProcessInfo.processInfo.operatingSystemVersionString.isEmpty)
    }
}
#endif
