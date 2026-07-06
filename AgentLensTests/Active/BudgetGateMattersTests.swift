import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Locks in the fail-CLOSED contract hardened in `BudgetGate.evaluate`.
///
/// The gate used to read current spend with `(try? await ledger.currentSpend(...)) ?? 0`.
/// A failed ledger read (DB locked, decode fault, query error) was silently coerced to
/// `used = 0`, so `projected = 0 + estimatedCost`. A rule that was actually at/over its
/// limit then evaluated as well under budget and the request flowed through — a silent
/// fail-OPEN on the single decision this gate exists to make.
///
/// The hardened gate fails CLOSED: an unreadable ledger blocks block-capable rules and
/// surfaces a warning for the contractually non-blocking `.warnOnly` rule, never silently
/// allowing a possibly-over-budget request, and logs the read failure for observability.
@MainActor
final class BudgetGateMattersTests: XCTestCase {

    // MARK: - Fakes (injected through the gate's protocol seams)

    /// In-memory `BudgetRuleProviding` so the gate runs without a live SQLite-backed
    /// `BudgetSettings`. Filtering mirrors `BudgetSettings` exactly.
    @MainActor
    private final class FakeRuleProvider: BudgetRuleProviding {
        var allRules: [BudgetRule]
        init(rules: [BudgetRule]) { self.allRules = rules }

        var rules: [BudgetRule] { allRules }
        var globalRules: [BudgetRule] { allRules.filter { $0.scope == .global } }
        var organizationRules: [BudgetRule] { allRules.filter { $0.scope == .organization } }

        func rules(forCredential providerID: String, accountID: String?) -> [BudgetRule] {
            allRules.filter {
                guard $0.scope == .credential, $0.providerID == providerID else { return false }
                if let accountID {
                    return $0.accountID == accountID
                }
                return $0.accountID == nil || $0.accountID?.isEmpty == true
            }
        }

        func rules(forProject projectName: String) -> [BudgetRule] {
            allRules.filter { $0.scope == .project && $0.projectName == projectName }
        }
    }

    /// `BudgetLedgerReading` fake that either throws a configured error or returns a fixed
    /// spend, and records how many reads it served (so we can prove a subscription
    /// credential never touches the ledger). A per-rule override lets one rule read cleanly
    /// while another rule's read fails in the same evaluation.
    private actor StubLedger: BudgetLedgerReading {
        enum Mode {
            case throwsError
            case returns(Double)
        }

        struct ReadFault: Error {}

        private let defaultMode: Mode
        private let perRule: [String: Mode]
        private(set) var readCount = 0

        init(_ defaultMode: Mode, perRule: [String: Mode] = [:]) {
            self.defaultMode = defaultMode
            self.perRule = perRule
        }

        func currentSpend(forRule rule: BudgetRule, reference: Date) async throws -> Double {
            readCount += 1
            switch perRule[rule.id] ?? defaultMode {
            case .throwsError:
                throw ReadFault()
            case .returns(let value):
                return value
            }
        }

        func reads() -> Int { readCount }
    }

    // MARK: - Fixtures

    private func rule(
        scope: BudgetRuleScope = .credential,
        behavior: BudgetBehavior,
        amountUSD: Double = 50,
        providerID: String? = "openrouter",
        accountID: String? = "slot-1",
        projectName: String? = nil,
        fallbackCredentialIDs: [String] = [],
        identifier: String? = nil,
        label: String = "Test rule",
        isEnabled: Bool = true
    ) -> BudgetRule {
        BudgetRule(
            id: "rule-\(UUID().uuidString)",
            scope: scope,
            identifier: identifier,
            providerID: providerID,
            accountID: accountID,
            projectName: projectName,
            label: label,
            amountUSD: amountUSD,
            period: .month,
            behavior: behavior,
            fallbackCredentialIDs: fallbackCredentialIDs,
            isEnabled: isEnabled
        )
    }

    private func credential(
        billingMode: BudgetBillingMode = .perUsage,
        providerID: String = "openrouter",
        slotID: String = "slot-1",
        displayLabel: String = "Test credential",
        providerAccountID: String? = nil,
        providerAccountLabel: String? = nil
    ) -> BudgetCredentialIdentity {
        BudgetCredentialIdentity(
            providerID: providerID,
            slotID: slotID,
            displayLabel: displayLabel,
            providerAccountID: providerAccountID,
            providerAccountLabel: providerAccountLabel,
            billingMode: billingMode
        )
    }

    private func makeGate(rules: [BudgetRule], ledger: StubLedger) -> BudgetGate {
        BudgetGate(ruleProvider: FakeRuleProvider(rules: rules), ledger: ledger, warningThreshold: 0.8)
    }

    private func makeMigratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true)
        return queue
    }

    private func insertUsage(
        into queue: DatabaseQueue,
        cost: Double,
        at startTime: Date,
        providerAccountID: String? = nil,
        providerAccountLabel: String? = nil
    ) async throws {
        let store = UsageStore(dbQueue: queue)
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "budget-gate-\(UUID().uuidString)",
            projectName: "BudgetGateTest",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: cost,
            startTime: startTime,
            endTime: startTime,
            providerAccountID: providerAccountID,
            providerAccountLabel: providerAccountLabel
        )
        try await store.insert(usage)
    }

    // MARK: - Fail CLOSED: a failed ledger read must not let a request through

    func test_hardBlock_ledgerReadFails_failsClosedToBlock() async {
        let blocking = rule(behavior: .hardBlock)
        let gate = makeGate(rules: [blocking], ledger: StubLedger(.throwsError))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(let rule, let used, let limit, let fallback) = decision else {
            XCTFail("Expected .block on unreadable ledger, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, blocking.id)
        XCTAssertEqual(limit, blocking.amountUSD)
        // Fails closed at the limit (not at 0) so the surfaced error reads "$X of $X".
        XCTAssertEqual(used, blocking.amountUSD)
        XCTAssertNil(fallback)
    }

    func test_warnThenBlock_ledgerReadFails_failsClosedToBlock() async {
        let blocking = rule(behavior: .warnThenBlock)
        let gate = makeGate(rules: [blocking], ledger: StubLedger(.throwsError))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block = decision else {
            XCTFail("Expected .block on unreadable ledger, got \(decision)"); return
        }
    }

    func test_hardBlockWithFallback_ledgerReadFails_failsClosedToBlock() async {
        let fallbackRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "anthropic",
            accountID: "cheap-slot"
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: [fallbackRule.id]
        )
        let gate = makeGate(rules: [blocking, fallbackRule], ledger: StubLedger(.throwsError))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(_, _, _, let fallback) = decision else {
            XCTFail("Expected .block on unreadable ledger, got \(decision)"); return
        }
        XCTAssertNil(fallback, "Unreadable fallback spend must not be promoted")
    }

    // MARK: - Phase 4B: hard-block fallback resolution

    func test_hardBlockWithFallback_overBudget_resolvesConfiguredFallbackCredential() async {
        let fallbackRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "anthropic",
            accountID: "cheap-slot"
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            fallbackCredentialIDs: [fallbackRule.id]
        )
        let gate = makeGate(rules: [blocking, fallbackRule], ledger: StubLedger(.returns(50.0)))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(let rule, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with fallback, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, blocking.id)
        XCTAssertEqual(fallback.providerID, "anthropic")
        XCTAssertEqual(fallback.slotID, "cheap-slot")
        XCTAssertEqual(fallback.displayLabel, fallbackRule.displayLabel)
        XCTAssertEqual(fallback.billingMode, .unknown)
    }

    func test_hardBlockWithFallback_skipsMissingNonCredentialAndDisabledFallbacks() async {
        let projectRule = rule(
            scope: .project,
            behavior: .warnThenBlock,
            providerID: nil,
            accountID: nil,
            projectName: "demo"
        )
        let disabledRule = rule(
            behavior: .warnThenBlock,
            providerID: "xai",
            accountID: "disabled-slot",
            isEnabled: false
        )
        let viableRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "openai",
            accountID: "fallback-slot"
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            fallbackCredentialIDs: ["missing", projectRule.id, disabledRule.id, viableRule.id]
        )
        let gate = makeGate(
            rules: [blocking, projectRule, disabledRule, viableRule],
            ledger: StubLedger(.returns(50.0))
        )

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(_, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with resolved viable fallback, got \(decision)"); return
        }
        XCTAssertEqual(fallback.providerID, "openai")
        XCTAssertEqual(fallback.slotID, "fallback-slot")
    }

    func test_hardBlockWithFallback_skipsFallbackWhoseOwnCapWouldBlock() async {
        let exhaustedRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 25,
            providerID: "anthropic",
            accountID: "exhausted-slot"
        )
        let viableRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "openai",
            accountID: "fallback-slot"
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            fallbackCredentialIDs: [exhaustedRule.id, viableRule.id]
        )
        let ledger = StubLedger(
            .returns(0),
            perRule: [
                blocking.id: .returns(50.0),
                exhaustedRule.id: .returns(25.0),
                viableRule.id: .returns(2.0)
            ]
        )
        let gate = makeGate(rules: [blocking, exhaustedRule, viableRule], ledger: ledger)

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(_, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with viable fallback, got \(decision)"); return
        }
        XCTAssertEqual(fallback.providerID, "openai")
        XCTAssertEqual(fallback.slotID, "fallback-slot")
    }

    func test_hardBlockWithFallback_skipsFallbackBlockedByAnotherMatchingRule() async {
        let fallbackRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "anthropic",
            accountID: "shared-slot"
        )
        let siblingBlocker = rule(
            behavior: .hardBlock,
            amountUSD: 5,
            providerID: "anthropic",
            accountID: "shared-slot"
        )
        let viableRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "openai",
            accountID: "fallback-slot"
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            fallbackCredentialIDs: [fallbackRule.id, viableRule.id]
        )
        let ledger = StubLedger(
            .returns(0),
            perRule: [
                blocking.id: .returns(50.0),
                fallbackRule.id: .returns(1.0),
                siblingBlocker.id: .returns(5.0),
                viableRule.id: .returns(2.0)
            ]
        )
        let gate = makeGate(
            rules: [blocking, fallbackRule, siblingBlocker, viableRule],
            ledger: ledger
        )

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(_, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with viable fallback, got \(decision)"); return
        }
        XCTAssertEqual(fallback.providerID, "openai")
        XCTAssertEqual(fallback.slotID, "fallback-slot")
    }

    func test_hardBlockWithFallback_returnsNilWhenGlobalRuleBlocksFallback() async {
        let fallbackRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "anthropic",
            accountID: "cheap-slot"
        )
        let globalBlocker = rule(
            scope: .global,
            behavior: .hardBlock,
            amountUSD: 5,
            providerID: nil,
            accountID: nil
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            fallbackCredentialIDs: [fallbackRule.id]
        )
        let ledger = StubLedger(
            .returns(0),
            perRule: [
                blocking.id: .returns(50.0),
                fallbackRule.id: .returns(1.0),
                globalBlocker.id: .returns(5.0)
            ]
        )
        let gate = makeGate(rules: [blocking, fallbackRule, globalBlocker], ledger: ledger)

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(_, _, _, let fallback) = decision else {
            XCTFail("Expected .block without fallback, got \(decision)"); return
        }
        XCTAssertNil(fallback)
    }

    func test_fallbackWithExplicitAccountResolvesWhenBlockingRuleHasEmptyAccount() async {
        // The blocking rule targets the provider's default slot (empty accountID — synced
        // rules can carry "" where the editor stores nil). The self-exclusion comparison
        // normalizes BOTH sides to "default", so a candidate with an explicit, different
        // account must stay eligible as a fallback (audit wave 4, item 5).
        let fallbackRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "openrouter",
            accountID: "backup-slot"
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            providerID: "openrouter",
            accountID: "",
            fallbackCredentialIDs: [fallbackRule.id]
        )
        let ledger = StubLedger(
            .returns(0),
            perRule: [blocking.id: .returns(50.0)]
        )
        let gate = makeGate(rules: [blocking, fallbackRule], ledger: ledger)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openrouter",
                slotID: "",
                displayLabel: "OpenRouter default",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(let rule, _, _, let fallback?) = decision else {
            XCTFail("Expected .block with explicit-account fallback, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, blocking.id)
        XCTAssertEqual(fallback.providerID, "openrouter")
        XCTAssertEqual(fallback.slotID, "backup-slot")
    }

    func test_fallbackSelfExcludedWhenBothRulesTargetDefaultSlot() async {
        // Candidate carries a whitespace-only accountID, the blocking rule "" — after
        // trim+default normalization they are the SAME default slot, so the gate must
        // never offer the blocked credential as its own fallback (audit wave 4, item 5).
        let candidateRule = rule(
            behavior: .warnThenBlock,
            amountUSD: 100,
            providerID: "openrouter",
            accountID: "  "
        )
        let blocking = rule(
            behavior: .hardBlockWithFallback,
            amountUSD: 50,
            providerID: "openrouter",
            accountID: "",
            fallbackCredentialIDs: [candidateRule.id]
        )
        let ledger = StubLedger(
            .returns(0),
            perRule: [blocking.id: .returns(50.0)]
        )
        let gate = makeGate(rules: [blocking, candidateRule], ledger: ledger)

        let decision = await gate.evaluate(
            credential: BudgetCredentialIdentity(
                providerID: "openrouter",
                slotID: "",
                displayLabel: "OpenRouter default",
                billingMode: .perUsage
            ),
            estimatedCost: 1.0
        )

        guard case .block(let rule, _, _, let fallback) = decision else {
            XCTFail("Expected .block, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, blocking.id)
        XCTAssertNil(fallback, "A default-slot candidate must be excluded as its own fallback")
    }

    func test_matchingOrganizationRuleIsEvaluatedForCredentialLabel() async {
        let organization = rule(
            scope: .organization,
            behavior: .hardBlock,
            amountUSD: 50,
            providerID: nil,
            accountID: nil,
            identifier: "Acme Org",
            label: "Acme Org"
        )
        let gate = makeGate(rules: [organization], ledger: StubLedger(.returns(49)))

        let decision = await gate.evaluate(
            credential: credential(slotID: "acct-a", displayLabel: "Acme Org"),
            estimatedCost: 2
        )

        guard case .block(let rule, let used, let limit, _) = decision else {
            XCTFail("Expected matching organization rule to block, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, organization.id)
        XCTAssertEqual(used, 49)
        XCTAssertEqual(limit, 50)
    }

    func test_accountLabelOrganizationRuleBlocksWhenGatewayLabelIsHost() async throws {
        let now = Date()
        let queue = try makeMigratedQueue()
        try await insertUsage(
            into: queue,
            cost: 49,
            at: now,
            providerAccountID: "acct-a",
            providerAccountLabel: "Acme Org"
        )

        let organization = rule(
            scope: .organization,
            behavior: .hardBlock,
            amountUSD: 50,
            providerID: nil,
            accountID: nil,
            identifier: "Acme Org",
            label: "Acme Org"
        )
        let gate = BudgetGate(
            ruleProvider: FakeRuleProvider(rules: [organization]),
            ledger: BudgetLedger(dbQueue: queue),
            warningThreshold: 0.8
        )

        let decision = await gate.evaluate(
            credential: credential(slotID: "hashed-api-key", displayLabel: "api.openai.com"),
            estimatedCost: 2,
            reference: now.addingTimeInterval(60)
        )

        guard case .block(let rule, let used, let limit, _) = decision else {
            XCTFail("Expected account-label organization rule to block with host display label, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, organization.id)
        XCTAssertEqual(used, 49, accuracy: 0.0001)
        XCTAssertEqual(limit, 50, accuracy: 0.0001)
    }

    func test_nonMatchingOrganizationRuleIsIgnored() async {
        let organization = rule(
            scope: .organization,
            behavior: .hardBlock,
            amountUSD: 50,
            providerID: nil,
            accountID: nil,
            identifier: "Acme Org",
            label: "Acme Org"
        )
        let ledger = StubLedger(.throwsError)
        let gate = makeGate(rules: [organization], ledger: ledger)

        let decision = await gate.evaluate(
            credential: credential(
                slotID: "acct-other",
                displayLabel: "Other Org",
                providerAccountLabel: "Other Org"
            ),
            estimatedCost: 100
        )

        XCTAssertEqual(decision, .allow)
        let reads = await ledger.reads()
        XCTAssertEqual(reads, 0)
    }

    // MARK: - Fail CLOSED but honor the non-blocking contract for .warnOnly

    func test_warnOnly_ledgerReadFails_surfacesWarnNotAllowAndNeverBlocks() async {
        let observe = rule(behavior: .warnOnly)
        let gate = makeGate(rules: [observe], ledger: StubLedger(.throwsError))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        // .warnOnly is contractually non-blocking, so it must NOT fail to .block — but it
        // must also not silently .allow; a failed read is surfaced as a warning.
        guard case .warn(let rule, let usedPercent, _, let limit) = decision else {
            XCTFail("Expected .warn on unreadable warn-only ledger, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, observe.id)
        XCTAssertEqual(limit, observe.amountUSD)
        XCTAssertEqual(usedPercent, 1.0)
        if case .block = decision { XCTFail(".warnOnly must never block") }
    }

    // MARK: - A single failed read cannot be masked by another rule's healthy .allow

    func test_oneRuleReadsAllow_otherRuleReadFails_overallFailsClosed() async {
        // Both rules match the same credential. `healthy` reads cleanly and is well under
        // budget (would be .allow); `faulting`'s read throws. Most-restrictive must win =>
        // overall .block, proving a single failed read cannot be masked by another rule's
        // healthy .allow.
        let healthy = rule(behavior: .warnThenBlock, amountUSD: 100, accountID: "slot-1")
        let faulting = rule(behavior: .hardBlock, amountUSD: 50, accountID: "slot-1")

        let ledger = StubLedger(
            .returns(1.0),
            perRule: [faulting.id: .throwsError]
        )
        let gate = makeGate(rules: [healthy, faulting], ledger: ledger)
        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)
        guard case .block(let rule, _, _, _) = decision else {
            XCTFail("Expected overall .block when a matching block-capable read fails, got \(decision)"); return
        }
        XCTAssertEqual(rule.id, faulting.id, "The failed-read rule should drive the block")
    }

    // MARK: - Subscription credentials short-circuit BEFORE any ledger read

    func test_subscriptionCredential_neverReadsLedger_andAllows() async {
        let blocking = rule(behavior: .hardBlock)
        let ledger = StubLedger(.throwsError)
        let gate = makeGate(rules: [blocking], ledger: ledger)

        let decision = await gate.evaluate(
            credential: credential(billingMode: .subscription),
            estimatedCost: 1.0
        )

        XCTAssertEqual(decision, .allow)
        let reads = await ledger.reads()
        XCTAssertEqual(reads, 0, "Subscription credential must short-circuit before the ledger read")
    }

    // MARK: - No regression on the healthy read paths

    func test_healthyRead_underBudget_allows() async {
        let blocking = rule(behavior: .hardBlock, amountUSD: 50)
        let gate = makeGate(rules: [blocking], ledger: StubLedger(.returns(5.0)))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        XCTAssertEqual(decision, .allow)
    }

    func test_healthyRead_overBudget_blocks() async {
        let blocking = rule(behavior: .hardBlock, amountUSD: 50)
        // Already at the limit before this request — known over budget once projected.
        let gate = makeGate(rules: [blocking], ledger: StubLedger(.returns(50.0)))

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1.0)

        guard case .block(_, let used, let limit, _) = decision else {
            XCTFail("Expected .block when known spend is at/over limit, got \(decision)"); return
        }
        XCTAssertEqual(used, 50.0)
        XCTAssertEqual(limit, 50.0)
    }

    func test_noMatchingRules_allowsWithoutReadingLedger() async {
        let ledger = StubLedger(.throwsError)
        // Rule is for a different credential slot, so it never matches.
        let unrelated = rule(behavior: .hardBlock, accountID: "other-slot")
        let gate = makeGate(rules: [unrelated], ledger: ledger)

        let decision = await gate.evaluate(credential: credential(slotID: "slot-1"), estimatedCost: 1.0)

        XCTAssertEqual(decision, .allow)
        let reads = await ledger.reads()
        XCTAssertEqual(reads, 0, "No matching rule must short-circuit before any ledger read")
    }
}
