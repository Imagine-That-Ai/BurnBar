import Foundation

/// Stable identifier for a user-defined scope rule. The id is used in
/// audit entries so a dispute investigation can map a rejected/approved
/// action back to the rule that allowed it without re-evaluating the
/// matcher against the live frontmost window.
public struct ComputerUseScopeRuleID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static func newRandom() -> Self {
        Self(rawValue: UUID().uuidString)
    }

    public var description: String { rawValue }
}

/// Composable scope predicate. A rule is the conjunction of its three
/// optional sub-predicates (URL prefix AND bundle id AND window title)
/// against the live action context. The set of all rules in the session
/// is evaluated as a disjunction, with `deny` rules taking precedence
/// over any `allow` rule that would otherwise match.
public struct ComputerUseScopeRule: Codable, Hashable, Sendable, Identifiable {
    public enum Effect: String, Codable, Sendable, Hashable, CaseIterable {
        case allow
        case deny
    }

    /// Origin tracker for forensic audit. User-defined rules can be
    /// edited / deleted; built-in deny defaults cannot. `imported` is
    /// reserved for Phase 13's named scope-bundle library.
    public enum Origin: String, Codable, Sendable, Hashable, CaseIterable {
        case builtIn = "built_in"
        case user
        case imported
    }

    public let id: ComputerUseScopeRuleID
    public let effect: Effect
    public let origin: Origin
    public let label: String
    /// URL prefix matched against the live frontmost browser tab's URL,
    /// case-insensitive. `nil` means "do not constrain on URL".
    public let urlPrefix: String?
    /// macOS bundle id matched against the frontmost application. `nil`
    /// means "do not constrain on bundle id". Wildcards: trailing `*` is
    /// treated as a prefix match (`com.apple.*`).
    public let bundleId: String?
    /// Regex matched against the frontmost window title. `nil` means
    /// "do not constrain on window title". Anchored with `^` ... `$` by
    /// the matcher unless the rule already contains explicit anchors.
    public let windowTitleRegex: String?
    /// Action ceiling for this rule when applied to a Trusted-mode
    /// session (Decision 9, threat A7). `nil` means inherit the session
    /// envelope.
    public let actionBudget: Int?
    /// Wall-clock expiry. Trusted-mode rules expire after 24 h or 50
    /// actions, whichever first; the manifest tracks both.
    public let expiresAt: Date?
    public let createdAt: Date

    public init(
        id: ComputerUseScopeRuleID = .newRandom(),
        effect: Effect,
        origin: Origin,
        label: String,
        urlPrefix: String? = nil,
        bundleId: String? = nil,
        windowTitleRegex: String? = nil,
        actionBudget: Int? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.effect = effect
        self.origin = origin
        self.label = label
        self.urlPrefix = urlPrefix
        self.bundleId = bundleId
        self.windowTitleRegex = windowTitleRegex
        self.actionBudget = actionBudget
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// Live action context evaluated against the rule set. Pure-data struct
/// so test code can fixture an arbitrary frontmost window without
/// driving an actual Mac.
public struct ComputerUseScopeContext: Sendable, Equatable {
    public var url: String?
    public var bundleId: String?
    public var windowTitle: String?

    public init(url: String? = nil, bundleId: String? = nil, windowTitle: String? = nil) {
        self.url = url
        self.bundleId = bundleId
        self.windowTitle = windowTitle
    }
}

/// Outcome of evaluating the live scope rule set against a context. A
/// `denied(rule:)` outcome always wins over any allow; an empty rule set
/// yields `.notMatched` and falls back to Manual approval in the
/// dispatcher.
public enum ComputerUseScopeOutcome: Equatable, Sendable {
    case allowed(rule: ComputerUseScopeRuleID)
    case denied(rule: ComputerUseScopeRuleID)
    case notMatched
}

/// Pure matcher. Lives in `OpenBurnBarComputerUseCore` so iOS and Mac
/// share the same evaluator and the test target can prove deny-precedence
/// independent of any Mac runtime.
public struct ComputerUseScopeMatcher: Sendable {
    public init() {}

    /// Evaluate `rules` against `context`. Deny rules always preempt
    /// allow rules. Among rules of the same effect, the most-recently
    /// created rule wins so a freshly added user rule supersedes an
    /// older built-in default of the same effect.
    public func evaluate(
        rules: [ComputerUseScopeRule],
        context: ComputerUseScopeContext,
        budgetStates: [ComputerUseScopeRuleID: ComputerUseScopeBudgetState] = [:],
        at now: Date = Date()
    ) -> ComputerUseScopeOutcome {
        var activeRules: [ComputerUseScopeRule] = []
        for rule in rules {
            if let expiry = rule.expiresAt, expiry <= now { continue }
            if budgetStates[rule.id]?.isExhausted(by: rule, at: now) == true { continue }
            if matches(rule: rule, context: context) {
                activeRules.append(rule)
            }
        }
        guard !activeRules.isEmpty else { return .notMatched }

        // Sort: deny effect first; within same effect, newest createdAt
        // wins. Stable insertion via filter preserves caller order for
        // ties.
        let denies = activeRules.filter { $0.effect == .deny }
        if let mostRecentDeny = denies.max(by: { $0.createdAt < $1.createdAt }) {
            return .denied(rule: mostRecentDeny.id)
        }
        let allows = activeRules.filter { $0.effect == .allow }
        if let mostRecentAllow = allows.max(by: { $0.createdAt < $1.createdAt }) {
            return .allowed(rule: mostRecentAllow.id)
        }
        return .notMatched
    }

    /// Convenience: does the supplied user-defined allow rule actually
    /// *weaken* a built-in deny? An allow rule only weakens a deny when
    /// — for at least one of the supplied sample contexts — both rules
    /// match: in that case the matcher's deny-precedence will still
    /// reject, but the editor warns the user that their proposed allow
    /// is overlapping a defended bundle/url. Probing each rule alone
    /// against the context (rather than evaluating the combined set)
    /// avoids the bug where every allow trivially overlaps because a
    /// different built-in deny matched the sample.
    public func overlapsBuiltInDeny(
        proposed: ComputerUseScopeRule,
        builtInDenies: [ComputerUseScopeRule],
        sampleContexts: [ComputerUseScopeContext]
    ) -> Bool {
        guard proposed.effect == .allow else { return false }
        for context in sampleContexts {
            guard matches(rule: proposed, context: context) else { continue }
            for deny in builtInDenies where deny.effect == .deny {
                if matches(rule: deny, context: context) { return true }
            }
        }
        return false
    }

    func matches(rule: ComputerUseScopeRule, context: ComputerUseScopeContext) -> Bool {
        if let prefix = rule.urlPrefix {
            guard let url = context.url else { return false }
            if !url.lowercased().hasPrefix(prefix.lowercased()) { return false }
        }
        if let bundleId = rule.bundleId {
            guard let liveBundle = context.bundleId else { return false }
            if bundleId.hasSuffix("*") {
                let prefix = String(bundleId.dropLast())
                if !liveBundle.hasPrefix(prefix) { return false }
            } else {
                if liveBundle != bundleId { return false }
            }
        }
        if let regex = rule.windowTitleRegex {
            guard let title = context.windowTitle else { return false }
            // Unanchored regex match. `firstMatch` finds the pattern
            // anywhere in the title — natural interpretation for a
            // user-provided window-title regex. Users who *want* an
            // exact match anchor the pattern themselves with `^...$`.
            guard let compiled = try? NSRegularExpression(pattern: regex, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            if compiled.firstMatch(in: title, options: [], range: range) == nil {
                return false
            }
        }
        return true
    }
}

/// Live counts attached to a scope rule that limits its activity budget
/// (Decision 9 / threat A7). The session coordinator increments
/// `actionsConsumed` and downgrades the rule to expired once budget or
/// wall-clock expires.
public struct ComputerUseScopeBudgetState: Codable, Hashable, Sendable {
    public var ruleId: ComputerUseScopeRuleID
    public var actionsConsumed: Int
    public var firstActionAt: Date?

    public init(
        ruleId: ComputerUseScopeRuleID,
        actionsConsumed: Int = 0,
        firstActionAt: Date? = nil
    ) {
        self.ruleId = ruleId
        self.actionsConsumed = actionsConsumed
        self.firstActionAt = firstActionAt
    }

    public func isExhausted(by rule: ComputerUseScopeRule, at now: Date = Date()) -> Bool {
        if let expiresAt = rule.expiresAt, expiresAt <= now { return true }
        if let budget = rule.actionBudget, actionsConsumed >= budget { return true }
        return false
    }
}
