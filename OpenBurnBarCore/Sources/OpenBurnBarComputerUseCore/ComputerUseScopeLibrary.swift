import Foundation

/// Named, reusable bundles of `ComputerUseScopeRule`s. Phase 13.
///
/// A bundle is a saved configuration the user can apply at session
/// start ("GitHub PR triage", "Gmail archive sweep", etc.). Applying
/// a bundle creates a fresh copy of each rule with a new `id` and a
/// fresh `expiresAt` (so re-applying refreshes the 24 h / N-action
/// budget rather than re-using a stale expiry).
public struct ComputerUseScopeLibrary: Codable, Sendable {
    public var bundles: [ComputerUseScopeBundle]
    public let updatedAt: Date

    public init(bundles: [ComputerUseScopeBundle], updatedAt: Date = Date()) {
        self.bundles = bundles
        self.updatedAt = updatedAt
    }
}

public struct ComputerUseScopeBundle: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let rules: [ComputerUseScopeRule]
    public let defaultActionBudget: Int
    public let defaultExpiryHours: Double

    public init(
        id: String = UUID().uuidString,
        name: String,
        summary: String,
        rules: [ComputerUseScopeRule],
        defaultActionBudget: Int = 50,
        defaultExpiryHours: Double = 24
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.rules = rules
        self.defaultActionBudget = defaultActionBudget
        self.defaultExpiryHours = defaultExpiryHours
    }

    /// Return a freshly-stamped copy of the bundle's rules — new ids,
    /// new createdAt, new expiresAt — suitable for applying to a
    /// running session.
    public func freshlyStampedRules(now: Date = Date()) -> [ComputerUseScopeRule] {
        let expiresAt = now.addingTimeInterval(defaultExpiryHours * 3600)
        return rules.map { rule in
            ComputerUseScopeRule(
                id: .newRandom(),
                effect: rule.effect,
                origin: .imported,
                label: rule.label,
                urlPrefix: rule.urlPrefix,
                bundleId: rule.bundleId,
                windowTitleRegex: rule.windowTitleRegex,
                actionBudget: rule.actionBudget ?? defaultActionBudget,
                expiresAt: rule.expiresAt ?? expiresAt,
                createdAt: now
            )
        }
    }
}

/// Pre-baked starter bundles surfaced in the UI. Users can edit or
/// delete; new bundles can be created from the Save-as-bundle action
/// on `ComputerUseSessionPanel`.
public enum ComputerUseStarterBundles {
    public static let githubPRTriage = ComputerUseScopeBundle(
        id: "starter.github-pr-triage",
        name: "GitHub PR triage",
        summary: "Allow the agent to navigate and comment on PRs in a single repository, deny the OAuth authorize endpoint.",
        rules: [
            ComputerUseScopeRule(
                id: ComputerUseScopeRuleID("starter.github-pr-triage.allow-pulls"),
                effect: .allow,
                origin: .imported,
                label: "github.com/<owner>/<repo>/pulls/*",
                urlPrefix: "https://github.com"
            ),
            ComputerUseScopeRule(
                id: ComputerUseScopeRuleID("starter.github-pr-triage.deny-settings"),
                effect: .deny,
                origin: .imported,
                label: "github.com/settings (deny)",
                urlPrefix: "https://github.com/settings"
            )
        ],
        defaultActionBudget: 50,
        defaultExpiryHours: 24
    )

    public static let gmailArchive = ComputerUseScopeBundle(
        id: "starter.gmail-archive",
        name: "Gmail archive sweep",
        summary: "Allow the agent to triage Gmail (archive, label) but never delete or send.",
        rules: [
            ComputerUseScopeRule(
                id: ComputerUseScopeRuleID("starter.gmail.allow-mail"),
                effect: .allow,
                origin: .imported,
                label: "mail.google.com",
                urlPrefix: "https://mail.google.com"
            ),
            ComputerUseScopeRule(
                id: ComputerUseScopeRuleID("starter.gmail.deny-compose"),
                effect: .deny,
                origin: .imported,
                label: "mail.google.com Compose (deny send)",
                urlPrefix: "https://mail.google.com/mail/u/0/#inbox?compose"
            )
        ],
        defaultActionBudget: 100,
        defaultExpiryHours: 4
    )

    public static let calculator = ComputerUseScopeBundle(
        id: "starter.calculator",
        name: "Calculator",
        summary: "Smallest-blast-radius dry-run bundle: lets the agent click Calculator buttons only.",
        rules: [
            ComputerUseScopeRule(
                id: ComputerUseScopeRuleID("starter.calculator.allow"),
                effect: .allow,
                origin: .imported,
                label: "com.apple.Calculator",
                bundleId: "com.apple.Calculator"
            )
        ],
        defaultActionBudget: 30,
        defaultExpiryHours: 1
    )

    public static let all: [ComputerUseScopeBundle] = [
        githubPRTriage, gmailArchive, calculator
    ]
}
