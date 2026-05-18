import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseScopeMatcherTests: XCTestCase {
    private let matcher = ComputerUseScopeMatcher()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: deny precedence

    func testDenyAlwaysWinsOverAllow() {
        let allow = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.example"),
            effect: .allow,
            origin: .user,
            label: "Allow github.com",
            urlPrefix: "https://github.com"
        )
        let deny = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("deny.oauth"),
            effect: .deny,
            origin: .builtIn,
            label: "Deny github oauth",
            urlPrefix: "https://github.com/login/oauth"
        )
        let context = ComputerUseScopeContext(
            url: "https://github.com/login/oauth/authorize?client_id=abc"
        )
        let outcome = matcher.evaluate(rules: [allow, deny], context: context)
        XCTAssertEqual(outcome, .denied(rule: deny.id))
    }

    // MARK: url prefix matching is case-insensitive

    func testURLPrefixCaseInsensitive() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.upper"),
            effect: .allow,
            origin: .user,
            label: "Allow github.com",
            urlPrefix: "HTTPS://GITHUB.COM/owner/repo"
        )
        let context = ComputerUseScopeContext(url: "https://github.com/owner/repo/pulls/1")
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: context), .allowed(rule: rule.id))
    }

    // MARK: bundle id wildcard

    func testBundleIdWildcardPrefix() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.apple"),
            effect: .allow,
            origin: .user,
            label: "Allow com.apple.*",
            bundleId: "com.apple.*"
        )
        let context = ComputerUseScopeContext(bundleId: "com.apple.Calculator")
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: context), .allowed(rule: rule.id))

        let nonMatch = ComputerUseScopeContext(bundleId: "com.openburnbar.AgentLens")
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: nonMatch), .notMatched)
    }

    // MARK: regex match against window title

    func testWindowTitleRegexMatches() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.pr-title"),
            effect: .allow,
            origin: .user,
            label: "Allow PR window",
            windowTitleRegex: "PR #\\d+"
        )
        let context = ComputerUseScopeContext(windowTitle: "PR #1234")
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: context), .allowed(rule: rule.id))
    }

    func testWindowTitleRegexAnchoredOnRequest() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.anchored"),
            effect: .allow,
            origin: .user,
            label: "Anchored",
            windowTitleRegex: "^Calculator$"
        )
        XCTAssertEqual(
            matcher.evaluate(rules: [rule], context: ComputerUseScopeContext(windowTitle: "Calculator")),
            .allowed(rule: rule.id)
        )
        XCTAssertEqual(
            matcher.evaluate(rules: [rule], context: ComputerUseScopeContext(windowTitle: "Calculator helper")),
            .notMatched
        )
    }

    func testWindowTitleRegexUnanchoredFindsSubstring() {
        // Confirms the matcher uses `firstMatch` semantics — a regex
        // like `PR #\d+` finds the pattern anywhere in the title, not
        // only when it exactly equals the whole string.
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.unanchored"),
            effect: .allow,
            origin: .user,
            label: "Unanchored",
            windowTitleRegex: "PR #\\d+"
        )
        XCTAssertEqual(
            matcher.evaluate(
                rules: [rule],
                context: ComputerUseScopeContext(windowTitle: "PR #1234 — burnbar/agentlens")
            ),
            .allowed(rule: rule.id)
        )
    }

    func testInvalidRegexFallsThroughAsNoMatch() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.invalid"),
            effect: .allow,
            origin: .user,
            label: "Bad regex",
            windowTitleRegex: "[unterminated"
        )
        XCTAssertEqual(
            matcher.evaluate(rules: [rule], context: ComputerUseScopeContext(windowTitle: "any")),
            .notMatched
        )
    }

    // MARK: expiry

    func testExpiredRuleIgnored() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("expired"),
            effect: .allow,
            origin: .user,
            label: "Expired",
            urlPrefix: "https://github.com",
            expiresAt: now.addingTimeInterval(-1)
        )
        XCTAssertEqual(
            matcher.evaluate(
                rules: [rule],
                context: ComputerUseScopeContext(url: "https://github.com/owner"),
                at: now
            ),
            .notMatched
        )
    }

    // MARK: conjunction across multiple predicates

    func testConjunctionAllPredicatesRequired() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("conj"),
            effect: .allow,
            origin: .user,
            label: "Allow GH in Safari",
            urlPrefix: "https://github.com",
            bundleId: "com.apple.Safari"
        )
        let match = ComputerUseScopeContext(url: "https://github.com/x", bundleId: "com.apple.Safari")
        let urlOnly = ComputerUseScopeContext(url: "https://github.com/x", bundleId: "com.brave.Browser")
        let bundleOnly = ComputerUseScopeContext(url: "https://example.com", bundleId: "com.apple.Safari")
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: match), .allowed(rule: rule.id))
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: urlOnly), .notMatched)
        XCTAssertEqual(matcher.evaluate(rules: [rule], context: bundleOnly), .notMatched)
    }

    // MARK: editor overlap detection

    func testEditorOverlapDetection() {
        let weakAllow = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("user.allow.apple"),
            effect: .allow,
            origin: .user,
            label: "Allow com.apple.*",
            bundleId: "com.apple.*"
        )
        let overlapsLoginWindow = matcher.overlapsBuiltInDeny(
            proposed: weakAllow,
            builtInDenies: ComputerUseDenyRegistry.builtInRules,
            sampleContexts: ComputerUseDenyRegistry.editorOverlapProbes
        )
        XCTAssertTrue(overlapsLoginWindow,
            "User-defined allow of com.apple.* must overlap built-in loginwindow deny")
    }

    func testEditorDoesNotFlagBenignAllow() {
        let benign = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("user.allow.calc"),
            effect: .allow,
            origin: .user,
            label: "Allow Calculator",
            bundleId: "com.apple.Calculator"
        )
        let overlap = matcher.overlapsBuiltInDeny(
            proposed: benign,
            builtInDenies: ComputerUseDenyRegistry.builtInRules,
            sampleContexts: ComputerUseDenyRegistry.editorOverlapProbes
        )
        XCTAssertFalse(overlap)
    }

    // MARK: most-recent rule wins among same effect

    func testMostRecentRuleWinsAmongSameEffect() {
        let older = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.older"),
            effect: .allow,
            origin: .user,
            label: "Older",
            urlPrefix: "https://github.com",
            createdAt: now
        )
        let newer = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("allow.newer"),
            effect: .allow,
            origin: .user,
            label: "Newer",
            urlPrefix: "https://github.com",
            createdAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            matcher.evaluate(
                rules: [older, newer],
                context: ComputerUseScopeContext(url: "https://github.com/x")
            ),
            .allowed(rule: newer.id)
        )
    }

    // MARK: scope budget state

    func testScopeBudgetExhaustsByCount() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("budget"),
            effect: .allow,
            origin: .user,
            label: "Allow",
            urlPrefix: "https://github.com",
            actionBudget: 5
        )
        var state = ComputerUseScopeBudgetState(ruleId: rule.id, actionsConsumed: 5)
        XCTAssertTrue(state.isExhausted(by: rule))
        state.actionsConsumed = 4
        XCTAssertFalse(state.isExhausted(by: rule))
    }

    func testScopeBudgetExhaustsByExpiry() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("budget-time"),
            effect: .allow,
            origin: .user,
            label: "Allow",
            urlPrefix: "https://github.com",
            expiresAt: now.addingTimeInterval(-1)
        )
        let state = ComputerUseScopeBudgetState(ruleId: rule.id, actionsConsumed: 0)
        XCTAssertTrue(state.isExhausted(by: rule, at: now))
    }

    func testMatcherIgnoresExhaustedAllowRuleBudget() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("budgeted-allow"),
            effect: .allow,
            origin: .user,
            label: "Budgeted GitHub",
            urlPrefix: "https://github.com/openburnbar",
            actionBudget: 5
        )
        let exhausted = ComputerUseScopeBudgetState(ruleId: rule.id, actionsConsumed: 5)

        XCTAssertEqual(
            matcher.evaluate(
                rules: [rule],
                context: ComputerUseScopeContext(url: "https://github.com/openburnbar/pr/1"),
                budgetStates: [rule.id: exhausted],
                at: now
            ),
            .notMatched
        )
    }

    func testMatcherAllowsBudgetedRuleBeforeBudgetIsExhausted() {
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("budgeted-allow"),
            effect: .allow,
            origin: .user,
            label: "Budgeted GitHub",
            urlPrefix: "https://github.com/openburnbar",
            actionBudget: 5
        )
        let remaining = ComputerUseScopeBudgetState(ruleId: rule.id, actionsConsumed: 4)

        XCTAssertEqual(
            matcher.evaluate(
                rules: [rule],
                context: ComputerUseScopeContext(url: "https://github.com/openburnbar/pr/1"),
                budgetStates: [rule.id: remaining],
                at: now
            ),
            .allowed(rule: rule.id)
        )
    }
}
