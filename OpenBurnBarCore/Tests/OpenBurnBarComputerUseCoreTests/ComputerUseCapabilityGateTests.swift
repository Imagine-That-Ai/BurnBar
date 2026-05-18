import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseCapabilityGateTests: XCTestCase {
    private let gate = DefaultComputerUseCapabilityGate()

    private func makeSession(
        trust: ComputerUseTrustMode = .manual,
        executed: Int = 0,
        actionCap: Int = 50
    ) -> ComputerUseSessionState {
        let manifest = ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID("s1"),
            mode: .browser,
            trustMode: trust,
            startedAt: Date(),
            userId: "user",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: actionCap,
            sessionTimeoutSeconds: 1800
        )
        return ComputerUseSessionState(
            sessionId: manifest.sessionId,
            manifest: manifest,
            liveTrustMode: trust,
            actionsExecuted: executed
        )
    }

    private func makeContext(
        entitlement: ComputerUseEntitlementSnapshot = ComputerUseEntitlementSnapshot(
            isActive: true,
            allowsBrowser: true,
            allowsSystem: true,
            allowsPhoneControl: true
        ),
        envelope: ComputerUseBudgetEnvelope = .initialNormal,
        usage: ComputerUseQuotaUsage = ComputerUseQuotaUsage(dayKey: "2026-05-17"),
        session: ComputerUseSessionState? = nil,
        concurrent: Bool = false,
        kill: Bool = false,
        accessibility: Bool = true,
        originatedFromPhone: Bool = false
    ) -> ComputerUseCapabilityContext {
        ComputerUseCapabilityContext(
            entitlement: entitlement,
            envelope: envelope,
            usage: usage,
            session: session ?? makeSession(),
            concurrentSessionActive: concurrent,
            killSwitch: kill,
            accessibilityTrusted: accessibility,
            originatedFromPhone: originatedFromPhone
        )
    }

    private let browserAction: ComputerUseAction = .browser(
        BrowserAction(kind: .click, selector: "button[type=submit]")
    )
    private let macAction: ComputerUseAction = .macInput(
        MacInputAction(kind: .click, displayX: 100, displayY: 200)
    )

    func testKillSwitchDeniesFirst() {
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(kill: true)),
            .denied(.killSwitch)
        )
    }

    func testEntitlementMissingDenies() {
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(entitlement: .inactive)),
            .denied(.entitlement)
        )
    }

    func testBrowserGatedByBrowserEntitlement() {
        let ent = ComputerUseEntitlementSnapshot(isActive: true, allowsBrowser: false, allowsSystem: true)
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(entitlement: ent)),
            .denied(.entitlement)
        )
    }

    func testPhoneOriginatedMacInputRequiresPhoneControlEntitlement() {
        let entitlement = ComputerUseEntitlementSnapshot(
            isActive: true,
            allowsBrowser: true,
            allowsSystem: true,
            allowsPhoneControl: false
        )
        let context = ComputerUseCapabilityContext(
            entitlement: entitlement,
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
            session: makeSession(),
            concurrentSessionActive: false,
            killSwitch: false,
            accessibilityTrusted: true,
            originatedFromPhone: true
        )
        XCTAssertEqual(
            gate.check(action: macAction, scopeOutcome: .notMatched, accessibilityDeny: nil, context: context),
            .denied(.entitlement)
        )
    }

    func testMacRequiresAccessibilityTrusted() {
        XCTAssertEqual(
            gate.check(action: macAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(accessibility: false)),
            .denied(.accessibilityRevoked)
        )
    }

    func testConcurrentSessionDenied() {
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(concurrent: true)),
            .denied(.concurrentSession)
        )
    }

    func testHardCapDenies() {
        let envelope = ComputerUseBudgetEnvelope.hardCapEnvelope(
            projectedMonthEndUSD: 3000, monthToDateUSD: 2700, updatedAt: Date()
        )
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(envelope: envelope)),
            .denied(.hardCap)
        )
    }

    func testDailyLimitHit() {
        let envelope = ComputerUseBudgetEnvelope.initialNormal
        let usage = ComputerUseQuotaUsage(
            dayKey: "2026-05-17",
            browserActionsExecuted: envelope.activeActionsPerDay
        )
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(envelope: envelope, usage: usage)),
            .denied(.dailyLimit)
        )
    }

    func testDailySpendCeilingHit() {
        let envelope = ComputerUseBudgetEnvelope.initialNormal
        let usage = ComputerUseQuotaUsage(
            dayKey: "2026-05-17",
            visionModelSpendUSD: envelope.perUserDailySpendCeilingUSD
        )
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(envelope: envelope, usage: usage)),
            .denied(.dailySpendCeiling)
        )
    }

    func testSessionCapHit() {
        let session = makeSession(executed: 50, actionCap: 50)
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(session: session)),
            .denied(.sessionLimit)
        )
    }

    func testAccessibilityDenyBeatsAllowRule() {
        let outcome = gate.check(
            action: macAction,
            scopeOutcome: .allowed(rule: ComputerUseScopeRuleID("allow")),
            accessibilityDeny: .secureTextField,
            context: makeContext()
        )
        XCTAssertEqual(outcome, .denied(.denyRegion))
    }

    func testScopeDenyReported() {
        XCTAssertEqual(
            gate.check(
                action: browserAction,
                scopeOutcome: .denied(rule: ComputerUseScopeRuleID("deny")),
                accessibilityDeny: nil,
                context: makeContext()
            ),
            .denied(.scopeDenied)
        )
    }

    func testTrustedScopeAllowsWithoutMacApproval() {
        let session = makeSession(trust: .trusted)
        let outcome = gate.check(
            action: browserAction,
            scopeOutcome: .allowed(rule: ComputerUseScopeRuleID("allow")),
            accessibilityDeny: nil,
            context: makeContext(session: session)
        )
        XCTAssertEqual(outcome, .allowed(approvedBy: .trustedScope))
    }

    func testManualScopeAllowedStillNeedsApproval() {
        let outcome = gate.check(
            action: browserAction,
            scopeOutcome: .allowed(rule: ComputerUseScopeRuleID("allow")),
            accessibilityDeny: nil,
            context: makeContext()
        )
        XCTAssertEqual(outcome, .allowed(approvedBy: .mac),
            "Manual mode never grants automatic dispatch; gate returns approvedBy: .mac so the dispatcher knows to raise an approval sheet.")
    }

    func testPhoneOriginatedMacInputIsPhoneApprovedAfterTrustChecksPass() {
        let outcome = gate.check(
            action: macAction,
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            context: makeContext(originatedFromPhone: true)
        )
        XCTAssertEqual(outcome, .allowed(approvedBy: .phone),
            "A verified phone-control intent is already the operator action; the Mac coordinator should audit it as phone-approved without raising a second Mac approval sheet.")
    }

    func testNoScopeMatchFallsBackToMacApproval() {
        XCTAssertEqual(
            gate.check(
                action: browserAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext()
            ),
            .allowed(approvedBy: .mac)
        )
    }
}

final class ComputerUseBudgetEnvelopeTests: XCTestCase {
    func testNormalRange() {
        let env = ComputerUseBudgetProjector.envelope(forProjectedMonthEnd: 500, monthToDate: 100)
        XCTAssertEqual(env.level, .normal)
        XCTAssertEqual(env.activeActionsPerDay, 200)
        XCTAssertEqual(env.activeActionsPerRun, 50)
    }

    func testSoftCapTightens() {
        let env = ComputerUseBudgetProjector.envelope(forProjectedMonthEnd: 1500, monthToDate: 500)
        XCTAssertEqual(env.level, .softCap)
        XCTAssertEqual(env.activeActionsPerDay, 100)
        XCTAssertEqual(env.activeActionsPerRun, 25)
        XCTAssertEqual(env.activeSessionsPerDay, 2)
        XCTAssertEqual(env.perUserDailySpendCeilingUSD, 2.5)
    }

    func testHardCapZeroes() {
        let env = ComputerUseBudgetProjector.envelope(forProjectedMonthEnd: 2500, monthToDate: 2000)
        XCTAssertEqual(env.level, .hardCap)
        XCTAssertEqual(env.activeActionsPerDay, 0)
    }

    func testProjectMonthEndLinear() {
        let p = ComputerUseBudgetProjector.projectMonthEnd(
            monthToDateUSD: 300, daysElapsed: 10, daysInMonth: 30
        )
        XCTAssertEqual(p, 900, accuracy: 0.001)
    }

    func testProjectMonthEndClampsZeroDaysElapsed() {
        let p = ComputerUseBudgetProjector.projectMonthEnd(
            monthToDateUSD: 100, daysElapsed: 0, daysInMonth: 30
        )
        XCTAssertGreaterThan(p, 0)
    }
}
