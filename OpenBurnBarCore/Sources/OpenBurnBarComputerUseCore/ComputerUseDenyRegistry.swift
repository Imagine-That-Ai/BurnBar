import Foundation

/// Hard-coded deny defaults that every Computer Use session inherits.
/// These cannot be removed via the scope-rule editor (Decision 1
/// enforcement at the matcher layer) — the editor refuses a save that
/// would overlap with any of these. Sourced from the threat model in
/// `plans/2026-05-16-computer-use-master-plan.md` § F.1.
///
/// The registry lives in `OpenBurnBarComputerUseCore` so both the Mac
/// dispatcher and the Mac UI editor see byte-identical defaults. The
/// list is exposed as a `Sendable` constant so test code can pin it.
public enum ComputerUseDenyRegistry {
    public static let builtInRules: [ComputerUseScopeRule] = [
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.loginwindow"),
            effect: .deny,
            origin: .builtIn,
            label: "macOS lock screen (loginwindow)",
            bundleId: "com.apple.loginwindow"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.securityagent"),
            effect: .deny,
            origin: .builtIn,
            label: "macOS auth prompt (SecurityAgent)",
            bundleId: "com.apple.SecurityAgent"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.security_agent_helper"),
            effect: .deny,
            origin: .builtIn,
            label: "macOS auth prompt helper (SecurityAgentHelper)",
            bundleId: "com.apple.SecurityAgentHelper"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.keychain"),
            effect: .deny,
            origin: .builtIn,
            label: "Keychain Access",
            bundleId: "com.apple.keychainaccess"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.privacy_pane"),
            effect: .deny,
            origin: .builtIn,
            label: "System Settings → Privacy & Security",
            bundleId: "com.apple.systempreferences",
            windowTitleRegex: ".*Privacy.*Security.*"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.fde_recovery"),
            effect: .deny,
            origin: .builtIn,
            label: "FileVault recovery",
            bundleId: "com.apple.FileVaultRecoveryUtility"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.terminal_root"),
            effect: .deny,
            origin: .builtIn,
            label: "Terminal session running as root",
            bundleId: "com.apple.Terminal",
            windowTitleRegex: ".*root@.*"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.bank_login_default"),
            effect: .deny,
            origin: .builtIn,
            label: "Mail \"Send\" (until per-app review)",
            bundleId: "com.apple.mail",
            windowTitleRegex: ".*Send.*"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.oauth_authorize"),
            effect: .deny,
            origin: .builtIn,
            label: "OAuth authorize endpoint",
            urlPrefix: "https://accounts.google.com/o/oauth2"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.github_oauth"),
            effect: .deny,
            origin: .builtIn,
            label: "GitHub OAuth authorize endpoint",
            urlPrefix: "https://github.com/login/oauth/authorize"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.admin_paths"),
            effect: .deny,
            origin: .builtIn,
            label: "URLs containing /admin",
            windowTitleRegex: ".*/admin.*"
        ),
        ComputerUseScopeRule(
            id: ComputerUseScopeRuleID("builtin.billing_paths"),
            effect: .deny,
            origin: .builtIn,
            label: "URLs containing /billing",
            windowTitleRegex: ".*/billing.*"
        )
    ]

    /// Whether the supplied rule id is built-in and therefore not
    /// editable / removable through the Mac UI.
    public static func isBuiltIn(_ id: ComputerUseScopeRuleID) -> Bool {
        builtInRules.contains { $0.id == id }
    }

    /// Sample contexts used by `ComputerUseScopeMatcher.overlapsBuiltInDeny`
    /// to refuse a user-defined allow that would otherwise unmask a
    /// built-in deny. Hand-curated; not exhaustive.
    public static let editorOverlapProbes: [ComputerUseScopeContext] = [
        ComputerUseScopeContext(bundleId: "com.apple.loginwindow", windowTitle: "Login"),
        ComputerUseScopeContext(bundleId: "com.apple.SecurityAgent", windowTitle: "Authenticate"),
        ComputerUseScopeContext(bundleId: "com.apple.keychainaccess", windowTitle: "Keychain Access"),
        ComputerUseScopeContext(
            bundleId: "com.apple.systempreferences",
            windowTitle: "Privacy & Security"
        ),
        ComputerUseScopeContext(
            url: "https://accounts.google.com/o/oauth2/v2/auth?...",
            bundleId: "com.google.Chrome"
        )
    ]
}

/// Result type for `axRoleAtPoint`-style fast-reject probes that flag a
/// CGEvent target as a secure text field, a system sheet, or an Apple
/// auth dialog — even when the rule set itself would have allowed the
/// host bundle.
public enum ComputerUseAccessibilityDenyReason: String, Codable, Sendable, Hashable {
    case secureTextField = "secure_text_field"
    case systemAuthSheet = "system_auth_sheet"
    case keychainPrompt = "keychain_prompt"
    case unknown
}
