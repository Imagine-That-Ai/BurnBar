import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseCapabilityGateTests: XCTestCase {
    private let gate = DefaultComputerUseCapabilityGate()

    private func makeSession(
        trust: ComputerUseTrustMode = .manual,
        executed: Int = 0,
        actionCap: Int = 50,
        startedAt: Date = Date(),
        sessionTimeoutSeconds: Int = 1800,
        phoneViewerNodeId: String? = nil
    ) -> ComputerUseSessionState {
        let manifest = ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID("s1"),
            mode: phoneViewerNodeId == nil ? .browser : .system,
            trustMode: trust,
            startedAt: startedAt,
            userId: "user",
            phoneViewerNodeId: phoneViewerNodeId,
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: actionCap,
            sessionTimeoutSeconds: sessionTimeoutSeconds
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
        originatedFromPhone: Bool = false,
        phoneControlRespectsDenyRegions: Bool = true,
        phoneSessionFirstActionConfirmed: Bool = false,
        clipboardConsentGranted: Bool = false
    ) -> ComputerUseCapabilityContext {
        ComputerUseCapabilityContext(
            entitlement: entitlement,
            envelope: envelope,
            usage: usage,
            session: session ?? makeSession(phoneViewerNodeId: originatedFromPhone ? "phone-peer" : nil),
            concurrentSessionActive: concurrent,
            killSwitch: kill,
            accessibilityTrusted: accessibility,
            originatedFromPhone: originatedFromPhone,
            phoneControlRespectsDenyRegions: phoneControlRespectsDenyRegions,
            phoneSessionFirstActionConfirmed: phoneSessionFirstActionConfirmed,
            clipboardConsentGranted: clipboardConsentGranted
        )
    }

    private let browserAction: ComputerUseAction = .browser(
        BrowserAction(kind: .click, selector: "button[type=submit]")
    )
    private let macAction: ComputerUseAction = .macInput(
        MacInputAction(kind: .click, displayX: 100, displayY: 200)
    )
    private let clipboardAction: ComputerUseAction = .remoteClipboard(
        RemoteClipboardActionDescriptor(kind: .pasteToMac, requestId: "r1", contentType: "text/plain", maxBytes: 65_536)
    )

    func testClipboardDeniedWithoutConsentEvenWithAllowsSystem() {
        XCTAssertEqual(
            gate.check(action: clipboardAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(originatedFromPhone: true, clipboardConsentGranted: false)),
            .denied(.clipboardConsentRequired)
        )
    }

    func testClipboardAllowedWithDedicatedConsent() {
        XCTAssertEqual(
            gate.check(action: clipboardAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(originatedFromPhone: true,
                                            phoneSessionFirstActionConfirmed: true,
                                            clipboardConsentGranted: true)),
            .allowed(approvedBy: .phone)
        )
    }

    func testMacInputStillAllowedWhenClipboardConsentOff() {
        XCTAssertEqual(
            gate.check(action: macAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(originatedFromPhone: true,
                                            phoneSessionFirstActionConfirmed: true,
                                            clipboardConsentGranted: false)),
            .allowed(approvedBy: .phone)
        )
    }

    func testKillSwitchDeniesFirst() {
        XCTAssertEqual(
            gate.check(action: browserAction, scopeOutcome: .notMatched, accessibilityDeny: nil,
                       context: makeContext(kill: true)),
            .denied(.killSwitch)
        )
    }

    func testKillSwitchStillDeniesPhoneOriginatedMacInput() {
        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext(kill: true, originatedFromPhone: true)
            ),
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

    func testDirectPhoneControlDoesNotRequireHostedComputerUseSubscription() {
        let entitlement = ComputerUseEntitlementSnapshot(
            isActive: false,
            allowsBrowser: true,
            allowsSystem: true,
            allowsPhoneControl: true
        )

        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext(entitlement: entitlement,
                                     originatedFromPhone: true,
                                     phoneSessionFirstActionConfirmed: true)
            ),
            .allowed(approvedBy: .phone)
        )
    }

    // F3: by default a verified phone intent now respects AX deny-regions — a
    // remote controller cannot silently type into a secure text field / auth
    // sheet. (Previously this short-circuited to `.allowed(.phone)`.)
    func testDirectPhoneControlRespectsAgentDenyRegionByDefault() {
        let entitlement = ComputerUseEntitlementSnapshot(
            isActive: false, allowsBrowser: true, allowsSystem: true, allowsPhoneControl: true
        )
        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .denied(rule: ComputerUseScopeRuleID("login-window")),
                accessibilityDeny: .secureTextField,
                context: makeContext(entitlement: entitlement, originatedFromPhone: true)
            ),
            .denied(.denyRegion),
            "Default secure posture: a phone-controlled click/type into a password field is refused."
        )
    }

    // F3: even the explicit legacy opt-out cannot bypass secure deny regions.
    // The locked-login case now belongs to the dedicated Remote Unlock path.
    func testDirectPhoneControlLegacyOptOutStillRespectsDenyRegion() {
        let entitlement = ComputerUseEntitlementSnapshot(
            isActive: false, allowsBrowser: true, allowsSystem: true, allowsPhoneControl: true
        )
        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .denied(rule: ComputerUseScopeRuleID("login-window")),
                accessibilityDeny: .secureTextField,
                context: makeContext(entitlement: entitlement,
                                     originatedFromPhone: true,
                                     phoneControlRespectsDenyRegions: false)
            ),
            .denied(.denyRegion),
            "Explicit opt-out cannot re-open password field / auth sheet / locked-screen input."
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

    func testPhoneOriginatedMacInputSkipsMeteredComputerUseCaps() {
        let hardCapEnvelope = ComputerUseBudgetEnvelope.hardCapEnvelope(
            projectedMonthEndUSD: 3_000,
            monthToDateUSD: 2_700,
            updatedAt: Date()
        )
        let session = makeSession(executed: 49, actionCap: 50, phoneViewerNodeId: "phone-peer")
        let usage = ComputerUseQuotaUsage(
            dayKey: "2026-05-17",
            browserActionsExecuted: ComputerUseBudgetEnvelope.initialNormal.activeActionsPerDay,
            visionModelSpendUSD: ComputerUseBudgetEnvelope.initialNormal.perUserDailySpendCeilingUSD
        )

        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext(
                    envelope: hardCapEnvelope,
                    usage: usage,
                    session: session,
                    originatedFromPhone: true,
                    phoneSessionFirstActionConfirmed: true
                )
            ),
            .allowed(approvedBy: .phone)
        )
    }

    func testPhoneOriginatedMacInputHonorsSessionActionCap() {
        let session = makeSession(executed: 50, actionCap: 50, phoneViewerNodeId: "phone-peer")

        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext(session: session, originatedFromPhone: true)
            ),
            .denied(.sessionLimit)
        )
    }

    func testPhoneOriginatedMacInputHonorsSessionTimeout() {
        let session = makeSession(
            startedAt: Date(timeIntervalSinceNow: -1810),
            sessionTimeoutSeconds: 1800,
            phoneViewerNodeId: "phone-peer"
        )

        XCTAssertEqual(
            gate.check(
                action: macAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext(session: session, originatedFromPhone: true)
            ),
            .denied(.sessionLimit)
        )
    }

    func testPhoneOriginatedBrowserActionStillHonorsBudgetCaps() {
        let hardCapEnvelope = ComputerUseBudgetEnvelope.hardCapEnvelope(
            projectedMonthEndUSD: 3_000,
            monthToDateUSD: 2_700,
            updatedAt: Date()
        )

        XCTAssertEqual(
            gate.check(
                action: browserAction,
                scopeOutcome: .notMatched,
                accessibilityDeny: nil,
                context: makeContext(envelope: hardCapEnvelope, originatedFromPhone: true)
            ),
            .denied(.hardCap)
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

    // F3: the FIRST input of a phone session raises the on-Mac/overlay approval
    // sheet (gate returns `.mac`), restoring "approval is the only ground truth".
    func testFirstPhoneInputRequiresApproval() {
        let outcome = gate.check(
            action: macAction,
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            context: makeContext(originatedFromPhone: true, phoneSessionFirstActionConfirmed: false)
        )
        XCTAssertEqual(outcome, .allowed(approvedBy: .mac),
            "The first phone-control input of a session must raise the approval sheet (gate returns .mac).")
    }

    // F3: once the operator confirms the session, later inputs flow as `.phone`
    // so the live mirror stays responsive (no per-tap sheet).
    func testConfirmedPhoneSessionInputIsPhoneApproved() {
        let outcome = gate.check(
            action: macAction,
            scopeOutcome: .notMatched,
            accessibilityDeny: nil,
            context: makeContext(originatedFromPhone: true, phoneSessionFirstActionConfirmed: true)
        )
        XCTAssertEqual(outcome, .allowed(approvedBy: .phone),
            "After the one-time per-session confirmation, the Mac audits phone input as phone-approved without a second sheet.")
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
