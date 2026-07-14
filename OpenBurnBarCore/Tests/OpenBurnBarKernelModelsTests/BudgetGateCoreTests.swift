import XCTest
@testable import OpenBurnBarKernelModels

/// Direct Core-package coverage for `BudgetGate` — the single shared implementation both
/// apps consume after the de-fork. The full behavioral matrices stay in the app suites
/// (`BudgetGateMattersTests` on macOS, `BudgetGateTests` on iOS); these tests make
/// `swift test` in OpenBurnBarCore a cheap cross-platform parity harness for the gate's
/// three load-bearing contracts: fail-closed on unreadable ledgers, warn-only staying
/// non-blocking, and subscription credentials never touching the ledger.
@MainActor
final class BudgetGateCoreTests: XCTestCase {

    // MARK: - Fakes (injected through the gate's protocol seams)

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

    private actor StubLedger: BudgetLedgerReading {
        struct ReadFault: Error {}

        private let spend: Double?
        private(set) var readCount = 0

        /// `spend == nil` makes every read throw; otherwise every read returns `spend`.
        init(spend: Double?) {
            self.spend = spend
        }

        func currentSpend(forRule rule: BudgetRule, reference: Date) async throws -> Double {
            readCount += 1
            guard let spend else { throw ReadFault() }
            return spend
        }
    }

    // MARK: - Builders

    private func rule(
        scope: BudgetRuleScope = .global,
        behavior: BudgetBehavior,
        amountUSD: Double = 100
    ) -> BudgetRule {
        BudgetRule(
            scope: scope,
            amountUSD: amountUSD,
            period: .month,
            behavior: behavior
        )
    }

    private func credential(billingMode: BudgetBillingMode = .perUsage) -> BudgetCredentialIdentity {
        BudgetCredentialIdentity(
            providerID: "openrouter",
            slotID: "slot-1",
            displayLabel: "Core test credential",
            providerAccountID: nil,
            providerAccountLabel: nil,
            billingMode: billingMode
        )
    }

    // MARK: - Tests

    func test_unreadableLedgerFailsClosedToBlockForBlockCapableRule() async {
        let blocking = rule(behavior: .hardBlock, amountUSD: 50)
        let gate = BudgetGate(
            ruleProvider: FakeRuleProvider(rules: [blocking]),
            ledger: StubLedger(spend: nil)
        )

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1)

        guard case .block(let blockedRule, let used, let limit, let fallback) = decision else {
            XCTFail("Expected fail-closed .block when the ledger read throws, got \(decision)")
            return
        }
        XCTAssertEqual(blockedRule.id, blocking.id)
        XCTAssertEqual(used, 50, accuracy: 0.0001, "fail-closed treats unknown spend as at-limit")
        XCTAssertEqual(limit, 50, accuracy: 0.0001)
        XCTAssertNil(fallback)
    }

    func test_unreadableLedgerFailsToWarnForWarnOnlyRule() async {
        let warnOnly = rule(behavior: .warnOnly, amountUSD: 50)
        let gate = BudgetGate(
            ruleProvider: FakeRuleProvider(rules: [warnOnly]),
            ledger: StubLedger(spend: nil)
        )

        let decision = await gate.evaluate(credential: credential(), estimatedCost: 1)

        guard case .warn(let warnedRule, let usedPercent, let used, let limit) = decision else {
            XCTFail("warnOnly is contractually non-blocking: expected .warn on a failed read, got \(decision)")
            return
        }
        XCTAssertEqual(warnedRule.id, warnOnly.id)
        XCTAssertEqual(usedPercent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(used, 50, accuracy: 0.0001)
        XCTAssertEqual(limit, 50, accuracy: 0.0001)
    }

    func test_subscriptionCredentialShortCircuitsToAllowWithoutLedgerRead() async {
        let ledger = StubLedger(spend: nil)
        let gate = BudgetGate(
            ruleProvider: FakeRuleProvider(rules: [rule(behavior: .hardBlock, amountUSD: 1)]),
            ledger: ledger
        )

        let decision = await gate.evaluate(
            credential: credential(billingMode: .subscription),
            estimatedCost: 10_000
        )

        XCTAssertEqual(decision, .allow, "subscription credentials must never be gated")
        let reads = await ledger.readCount
        XCTAssertEqual(reads, 0, "subscription short-circuit must happen before any ledger read")
    }
}
