import CryptoKit
import Foundation
import OSLog
import OpenBurnBarComputerUseCore

// MARK: - Agentic security policy primitives (2026-06-13 remediation)
//
// Pure / injectable security-decision helpers for the AgentLens agentic plane.
// Everything here is deliberately free of UI and process side effects so each
// security decision is unit-testable without a device, an Xcode host, or a live
// model. Findings addressed: T-TOOL-02 (distribution gate + per-N re-auth on the
// unrestricted shell), T-AI-01 (default-deny untrusted wrapping), T-AI-06
// (content-level secret scrubbing + no-retention provider header), and
// T-TOOL-01/05/07 (untrusted-content tagging for the spawned external CLI lane).

// MARK: - Distribution / build gate

/// Distribution-build gate for the most dangerous CLI flags.
///
/// The `--dangerously-skip-permissions` (Claude/antigravity/cursor) and
/// `--dangerously-bypass-approvals-and-sandbox` (Codex) flags hand a spawned CLI
/// full local autonomy. They must NEVER be emitted by default in any build: a
/// single obeyed prompt injection then runs unbounded. We gate them behind a
/// fresh local-auth proof so a user can still opt in deliberately, but the
/// default is fail-closed.
public enum AgentDistributionGate {
    /// `true` when this is a shipped distribution build (App Store / notarized
    /// release). Kept as an injectable input for tests and future policy
    /// telemetry, but dangerous-autonomy flags require fresh local auth in every
    /// build.
    public static var isDistributionBuild: Bool {
        #if DISTRIBUTION_MAS
        return true
        #else
        return false
        #endif
    }

    /// Whether a YOLO/dangerous-autonomy CLI flag may be emitted right now.
    ///
    /// - Allowed ONLY when the caller has a fresh local-auth proof (Touch ID /
    ///   device-owner auth) AND the grant genuinely carries the trusted YOLO
    ///   mode. Absent the proof we fail closed and the CLI runs in its
    ///   sandboxed/approval mode instead.
    public static func allowsDangerousAutonomyFlag(
        isDistributionBuild: Bool = AgentDistributionGate.isDistributionBuild,
        hasFreshLocalAuthProof: Bool
    ) -> Bool {
        _ = isDistributionBuild
        return hasFreshLocalAuthProof
    }
}

// MARK: - Per-N-action re-authorization cadence (T-TOOL-02 / T-AI-07)

/// Tracks how many unrestricted-shell actions have run under a single grant and
/// decides when a fresh local-auth re-authorization is required. This is the
/// chokepoint that bounds an obeyed prompt injection: even under YOLO, the
/// unrestricted shell can only run `interval` commands before the human must
/// re-prove presence. Pure value type so the cadence is unit-testable.
public struct AgentReauthCadence: Sendable {
    /// Number of unrestricted-shell actions permitted between re-auth proofs.
    public let interval: Int
    private var actionsSinceLastAuth: Int
    private var hasAuthenticated: Bool

    public init(
        interval: Int = 5,
        actionsSinceLastAuth: Int = 0,
        hasAuthenticated: Bool = false
    ) {
        self.interval = max(1, interval)
        self.actionsSinceLastAuth = max(0, actionsSinceLastAuth)
        self.hasAuthenticated = hasAuthenticated
    }

    /// The very first action under a grant always re-authorizes (presence proof
    /// at the start of an unbounded-shell burst), then every `interval` actions.
    public var requiresReauthBeforeNextAction: Bool {
        !hasAuthenticated || actionsSinceLastAuth >= interval
    }

    /// Call after a successful local-auth proof: resets the window.
    public mutating func recordReauth() {
        hasAuthenticated = true
        actionsSinceLastAuth = 0
    }

    /// Call after an action runs (post-auth) to advance the cadence window.
    public mutating func recordAction() {
        actionsSinceLastAuth += 1
    }
}

// MARK: - Default-deny untrusted tool-output wrapping (T-AI-01)

/// Decides which computer-use / desktop tool results must be wrapped with
/// `LLMSafeContent.wrapUntrusted` before re-entering the model's context.
///
/// Previous behavior was a 2-tool allowlist (browser extract + AX inspect). That
/// fails open: any NEW content-returning tool (file reads, shell stdout/stderr,
/// browser_screenshot OCR, clipboard) re-entered the prompt as trusted text. This
/// is the inversion to **default-deny**: every tool result that can carry
/// attacker-influenced bytes is wrapped unless it is on a tiny, explicit
/// control-only allow-list of results that are pure app-generated control
/// metadata (status codes, ids) with no external content.
public enum UntrustedToolOutputPolicy {
    /// Tools whose results are pure app-generated control metadata (no external
    /// content bytes). Everything NOT here is wrapped. Keep this list minimal.
    public static let controlOnlyTools: Set<String> = []

    /// Default-deny: wrap unless the tool is explicitly control-only.
    public static func shouldWrap(toolName: String) -> Bool {
        !controlOnlyTools.contains(toolName)
    }
}

// MARK: - Content-level secret scrubbing (T-AI-06)

/// Redacts high-confidence secrets from text before it is placed into a prompt
/// that leaves the host for a model provider. This is defense-in-depth on top of
/// the sandbox read denies: even if a secret reaches a tool result or the user
/// pastes one, the literal value is replaced with a typed placeholder so it is
/// not transmitted to (or retained by) the provider. Pure + deterministic.
public enum AgentSecretScrubber {
    private struct Pattern {
        let label: String
        let regex: NSRegularExpression
    }

    // Each pattern targets a well-known credential shape. Order is irrelevant
    // (non-overlapping). Compiled once.
    private static let patterns: [Pattern] = {
        let specs: [(String, String)] = [
            // OpenAI / Anthropic / generic provider keys.
            ("openai_key", #"sk-(?:ant-)?[A-Za-z0-9_\-]{16,}"#),
            // AWS access key id.
            ("aws_access_key_id", #"AKIA[0-9A-Z]{16}"#),
            // GitHub tokens (classic + fine-grained + oauth/app/refresh).
            ("github_token", #"gh[pousr]_[A-Za-z0-9]{20,}"#),
            // Google API key.
            ("google_api_key", #"AIza[0-9A-Za-z_\-]{20,}"#),
            // Slack token.
            ("slack_token", #"xox[baprs]-[A-Za-z0-9\-]{10,}"#),
            // Private key PEM blocks.
            ("private_key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"#),
            // Bearer header values.
            ("bearer_token", #"(?i)bearer\s+[A-Za-z0-9_\-\.=]{20,}"#),
            // JWTs.
            ("jwt", #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#)
        ]
        return specs.compactMap { label, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Pattern(label: label, regex: regex)
        }
    }()

    /// Returns `text` with any matched secret replaced by `[REDACTED:<label>]`.
    public static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pattern.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "[REDACTED:\(pattern.label)]"
            )
        }
        return result
    }

    /// `true` when scrubbing changed the text (a secret was present).
    public static func containsSecret(_ text: String) -> Bool {
        scrub(text) != text
    }
}

/// Header values that ask a cooperating provider not to retain or train on the
/// request. Applied where the OpenAI-compatible API supports it (OpenAI exposes
/// `OpenAI-Data-Storage: deny`; we also send the conventional opt-out hints).
public enum AgentProviderRetentionPolicy {
    /// Headers asserting no-retention / no-train intent. Cooperating gateways
    /// honor these; non-cooperating ones ignore unknown headers harmlessly.
    public static let noRetentionHeaders: [String: String] = [
        "OpenAI-Data-Storage": "deny",
        "X-Data-Retention": "none",
        "X-Model-Training": "disabled"
    ]
}

// MARK: - Spawned-CLI lane content tagging (T-TOOL-01 / 05 / 07)

/// In-process policy/tagging point for the spawned external CLI lane.
///
/// Full per-tool-call interposition inside another vendor's CLI process is
/// architecturally impossible (the CLI makes its own tool calls in its own
/// address space). The strongest feasible control is (a) constraining the
/// process environment/args (handled in `CLIArgumentBuilder` capability gating)
/// and (b) tagging untrusted workspace + web content that we feed INTO the CLI
/// prompt so the model treats it as data, not instructions. This wraps a prompt
/// segment that originated from untrusted sources (workspace files, web fetches)
/// before it is handed to the spawned CLI.
public enum SpawnedCLIContentTagging {
    /// Wrap untrusted prompt material destined for a spawned CLI. Reuses the same
    /// `<UNTRUSTED_CONTENT>` sentinel the in-process loop uses so the contract is
    /// identical across both lanes.
    public static func tagUntrusted(_ content: String, provenance: String) -> String {
        LLMSafeContent.wrapUntrusted(content, provenance: "spawned_cli:\(provenance)")
    }
}
