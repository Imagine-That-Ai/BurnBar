// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import OpenBurnBarCore

/// Drives the shared `BudgetGate` engine (macOS + iOS) through the platform-neutral
/// contract vectors at `tests/fixtures/budget-enforcement/budget-enforcement-vectors.json`
/// (Wave-5 WS3). The same fixture is consumed byte-for-byte by the Android JUnit gate, so
/// a divergence between platforms fails a build instead of an audit months later. This is
/// the Apple leg of that tripwire; the vectors themselves are the source of truth and the
/// coverage matrix is enforced by `scripts/ci/check-budget-enforcement-fixture.mjs`.
@MainActor
final class BudgetGateContractVectorTests: XCTestCase {

    // MARK: - Fixture model

    private struct Suite: Decodable {
        let schemaVersion: Int
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let id: String
        let description: String
        let rules: [RuleSpec]
        let request: RequestSpec
        let ledger: LedgerSpec
        let expected: Expected
    }

    private struct RuleSpec: Decodable {
        let id: String
        let scope: BudgetRuleScope
        let identifier: String?
        let providerID: String?
        let accountID: String?
        let projectName: String?
        let label: String?
        let amountUSD: Double
        let period: BudgetPeriod
        let behavior: BudgetBehavior
        let isEnabled: Bool
        let fallbackCredentialIDs: [String]
        let pausedUntil: Date?
    }

    private struct RequestSpec: Decodable {
        let providerID: String
        let slotID: String
        let displayLabel: String
        let providerAccountID: String?
        let providerAccountLabel: String?
        let billingMode: BudgetBillingMode
        let projectName: String?
        let estimatedCost: Double
    }

    private struct LedgerSpec: Decodable {
        let reference: Date
        let spend: [String: Double]
        let unreadable: [String]
    }

    private struct Expected: Decodable {
        let decision: String
        let ruleID: String?
        let fallbackCredentialID: String?
        let used: Double?
        let limit: Double?
        let usedPercent: Double?
        let resumeAt: Date?
        let noLedgerReads: Bool?
    }

    // MARK: - Fakes (match the real BudgetSettings / BudgetLedger provider semantics)

    @MainActor
    private final class VectorRuleProvider: BudgetRuleProviding {
        let allRules: [BudgetRule]
        init(_ rules: [BudgetRule]) { allRules = rules }

        var rules: [BudgetRule] { allRules }
        var globalRules: [BudgetRule] { allRules.filter { $0.scope == .global } }
        var organizationRules: [BudgetRule] { allRules.filter { $0.scope == .organization } }

        func rules(forCredential providerID: String, accountID: String?) -> [BudgetRule] {
            allRules.filter {
                guard $0.scope == .credential, $0.providerID == providerID else { return false }
                if let accountID { return $0.accountID == accountID }
                return $0.accountID == nil || $0.accountID?.isEmpty == true
            }
        }

        func rules(forProject projectName: String) -> [BudgetRule] {
            allRules.filter { $0.scope == .project && $0.projectName == projectName }
        }
    }

    /// A per-rule ledger. A rule id in `unreadable` — or absent from `spend` — throws, so
    /// the fixture must declare a spend for every rule it expects to be read (this is what
    /// makes the fail-closed vectors meaningful and forbids accidental "absent == $0").
    private actor VectorLedger: BudgetLedgerReading {
        struct ReadFault: Error {}
        private let spend: [String: Double]
        private let unreadable: Set<String>
        private(set) var readCount = 0
        private var undeclaredReadFaults: [String] = []

        init(spend: [String: Double], unreadable: Set<String>) {
            self.spend = spend
            self.unreadable = unreadable
        }

        func reads() -> Int { readCount }
        func undeclaredReads() -> [String] { undeclaredReadFaults }

        func currentSpend(forRule rule: BudgetRule, reference: Date) async throws -> Double {
            readCount += 1
            if unreadable.contains(rule.id) { throw ReadFault() }
            guard let value = spend[rule.id] else {
                undeclaredReadFaults.append(rule.id)
                throw ReadFault()
            }
            return value
        }
    }

    // MARK: - Loading

    private func loadSuite() throws -> Suite {
        guard let url = Bundle.module.url(forResource: "budget-enforcement-vectors", withExtension: "json") else {
            throw XCTSkip("budget-enforcement-vectors.json missing from OpenBurnBarCoreTests Fixtures bundle")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            guard let date = iso.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad ISO date \(raw)"))
            }
            return date
        }
        return try decoder.decode(Suite.self, from: Data(contentsOf: url))
    }

    private func makeRule(_ spec: RuleSpec) -> BudgetRule {
        BudgetRule(
            id: spec.id,
            scope: spec.scope,
            identifier: spec.identifier,
            providerID: spec.providerID,
            accountID: spec.accountID,
            projectName: spec.projectName,
            label: spec.label,
            amountUSD: spec.amountUSD,
            period: spec.period,
            behavior: spec.behavior,
            fallbackCredentialIDs: spec.fallbackCredentialIDs,
            pausedUntil: spec.pausedUntil,
            isEnabled: spec.isEnabled
        )
    }

    // MARK: - The contract test

    func testAllContractVectors() async throws {
        let suite = try loadSuite()
        XCTAssertEqual(suite.schemaVersion, 1)
        XCTAssertGreaterThan(suite.vectors.count, 0, "no vectors loaded")

        var ids = Set<String>()
        var scopesExercised = Set<BudgetRuleScope>()

        for v in suite.vectors {
            XCTAssertTrue(ids.insert(v.id).inserted, "duplicate vector id \(v.id)")
            v.rules.forEach { scopesExercised.insert($0.scope) }

            let provider = VectorRuleProvider(v.rules.map(makeRule))
            let ledger = VectorLedger(spend: v.ledger.spend, unreadable: Set(v.ledger.unreadable))
            let gate = BudgetGate(ruleProvider: provider, ledger: ledger)

            let credential = BudgetCredentialIdentity(
                providerID: v.request.providerID,
                slotID: v.request.slotID,
                displayLabel: v.request.displayLabel,
                providerAccountID: v.request.providerAccountID,
                providerAccountLabel: v.request.providerAccountLabel,
                billingMode: v.request.billingMode
            )

            let decision = await gate.evaluate(
                credential: credential,
                projectName: v.request.projectName,
                estimatedCost: v.request.estimatedCost,
                reference: v.ledger.reference
            )

            assert(decision, matches: v.expected, vector: v, rules: v.rules)

            if v.expected.noLedgerReads == true {
                let reads = await ledger.reads()
                XCTAssertEqual(reads, 0, "[\(v.id)] expected no ledger reads but observed \(reads)")
            }
            let undeclaredReads = await ledger.undeclaredReads()
            XCTAssertTrue(
                undeclaredReads.isEmpty,
                "[\(v.id)] ledger reads missing fixture spend entries for rule ids: \(undeclaredReads.joined(separator: ", "))"
            )
        }

        // Anti-vacuous: the suite must exercise every budget scope, or a platform could
        // silently drop a scope and still pass.
        for scope in BudgetRuleScope.allCases {
            XCTAssertTrue(scopesExercised.contains(scope), "no vector exercises the \(scope.rawValue) scope")
        }
    }

    private func assert(
        _ decision: BudgetGateDecision,
        matches expected: Expected,
        vector v: Vector,
        rules: [RuleSpec]
    ) {
        let ctx = "[\(v.id)]"
        switch (decision, expected.decision) {
        case (.allow, "allow"):
            break

        case let (.warn(rule, usedPercent, used, limit), "warn"):
            if let expectedRuleID = expected.ruleID { XCTAssertEqual(rule.id, expectedRuleID, "\(ctx) warn rule id") }
            if let e = expected.used { XCTAssertEqual(used, e, accuracy: 0.0001, "\(ctx) warn used") }
            if let e = expected.limit { XCTAssertEqual(limit, e, accuracy: 0.0001, "\(ctx) warn limit") }
            if let e = expected.usedPercent { XCTAssertEqual(usedPercent, e, accuracy: 0.0001, "\(ctx) warn usedPercent") }

        case let (.block(rule, used, limit, fallback), "block"):
            if let expectedRuleID = expected.ruleID { XCTAssertEqual(rule.id, expectedRuleID, "\(ctx) block rule id") }
            if let e = expected.used { XCTAssertEqual(used, e, accuracy: 0.0001, "\(ctx) block used") }
            if let e = expected.limit { XCTAssertEqual(limit, e, accuracy: 0.0001, "\(ctx) block limit") }
            if let expectedFallbackRuleID = expected.fallbackCredentialID {
                // The fixture names the fallback by its RULE id; the gate returns a credential
                // identity, so match on the candidate rule's providerID (+ slot).
                guard let fallback else {
                    XCTFail("\(ctx) expected fallback \(expectedFallbackRuleID) but decision carried none")
                    return
                }
                guard let candidate = rules.first(where: { $0.id == expectedFallbackRuleID }) else {
                    XCTFail("\(ctx) fixture names fallback rule \(expectedFallbackRuleID) that isn't in rules[]")
                    return
                }
                XCTAssertEqual(fallback.providerID, candidate.providerID, "\(ctx) fallback providerID")
                XCTAssertEqual(fallback.slotID, candidate.accountID ?? "default", "\(ctx) fallback slotID")
                XCTAssertEqual(fallback.billingMode, .unknown, "\(ctx) fallback billingMode")
            } else {
                XCTAssertNil(fallback, "\(ctx) expected no fallback but got one")
            }

        case let (.paused(rule, resumeAt), "paused"):
            if let expectedRuleID = expected.ruleID { XCTAssertEqual(rule.id, expectedRuleID, "\(ctx) paused rule id") }
            if let e = expected.resumeAt { XCTAssertEqual(resumeAt.timeIntervalSince1970, e.timeIntervalSince1970, accuracy: 1, "\(ctx) paused resumeAt") }

        default:
            XCTFail("\(ctx) decision \(decision) does not match expected \(expected.decision)")
        }
    }
}
