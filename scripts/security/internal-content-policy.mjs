// Confidentiality policy for the OpenBurnBar PUBLIC repository.
//
// The repo is public (github.com/Imagine-That-Ai/BurnBar). Secrets are already
// covered by gitleaks / trufflehog / detect-secrets. This policy covers the
// gap those tools cannot see: content that is *not a secret* but is still
// commercially or operationally sensitive and must never live in the public
// tree — pricing/COGS/margins, go-to-market strategy, and working notes that
// map currently-open or in-progress security vulnerabilities.
//
// Design goals: declarative, extendable (add a rule = one entry), and
// self-service (any file can opt itself out of publication with a banner, no
// policy edit required — see SELF_DECLARE_MARKERS).
//
// The engine that consumes this policy is scan-internal-content.mjs.

// Where relocated internal material should live. This directory is gitignored,
// so files moved here stay on disk and in any private mirror but never enter the
// public tree. See internal/README.md for the private-repo migration path.
export const PRIVATE_HOME = "internal/";

// ── Self-declared confidentiality ─────────────────────────────────────────
// Any text file containing one of these markers is treated as internal,
// regardless of its path. This is the extensible escape hatch: a new doc can
// gate itself out of publication just by carrying the banner — no policy edit.
// Markers are deliberately distinctive so they do not appear incidentally.
export const SELF_DECLARE_MARKERS = [
  /BurnBar-Confidential:\s*internal/i,
  /<!--\s*burnbar:confidential\s*-->/i,
  /CONFIDENTIAL\s*[—-]\s*DO NOT PUBLISH/i,
  /INTERNAL ONLY\s*[—-]\s*NOT FOR PUBLIC RELEASE/i,
];

// The canonical banner authors should paste into a new internal doc.
export const CANONICAL_BANNER =
  "<!-- burnbar:confidential -->\n> **BurnBar-Confidential: internal.** Do not publish to the public repo.";

// Files that legitimately *mention* the markers (this policy, its engine, its
// tests, and the docs that explain the system) are exempt from the content
// scan so they don't flag themselves.
export const CONTENT_SCAN_EXEMPT = [
  /^scripts\/security\/internal-content-policy\.mjs$/,
  /^scripts\/security\/scan-internal-content\.mjs$/,
  /^scripts\/security\/__tests__\/scan-internal-content\.test\.mjs$/,
  /^docs\/security\/CONFIDENTIALITY_POLICY\.md$/,
  /^docs\/security\/PUBLIC_REPO_HISTORY_PURGE_RUNBOOK\.md$/,
  /^internal\/README\.md$/,
  /^\.pre-commit-config\.yaml$/,
  /^\.github\/workflows\/confidentiality-guard\.yml$/,
];

// Extensions/paths we never read for content (binary or noisy). Path-rule
// matching still applies to these.
export const BINARY_OR_SKIP_CONTENT = [
  /\.(png|jpe?g|gif|ico|svg|pdf|zip|gz|tgz|dmg|ipa|xcframework|woff2?|ttf|otf|mp4|mov|webp|webm|wasm|bin|dat|keystore|jks|p12|p8|mobileprovision|class|jar|so|dylib|a|o)$/i,
  /\.xcassets\//,
  /(^|\/)Package\.resolved$/,
  /package-lock\.json$/,
  /pnpm-lock\.yaml$/,
];

// Max bytes to read when content-scanning a single file.
export const MAX_CONTENT_BYTES = 512 * 1024;

// ── Path-based internal rules ─────────────────────────────────────────────
// `paths` are matched against the repo-relative path (forward slashes).
// severity: "block" fails the guard; "warn" reports but does not fail (unless
// the engine is run with --strict).
export const INTERNAL_RULES = [
  {
    id: "pricing-financials",
    severity: "block",
    reason:
      "Pricing, COGS, unit economics, and margin model — competitively sensitive financials.",
    remediation:
      "Move under internal/ (e.g. internal/docs/pricing/). Keep only customer-facing prices on the website.",
    paths: [/^docs\/pricing\//],
  },
  {
    id: "gtm-strategy",
    severity: "block",
    reason:
      "Go-to-market master plan: margin targets, kill-switch spend budgets, tier/SKU strategy.",
    remediation: "Move under internal/ (e.g. internal/GTMMasterPlan.MD).",
    paths: [/^GTMMasterPlan\.MD$/i, /(^|\/)GTM[-_ ]?Master[-_ ]?Plan.*\.md$/i],
  },
  {
    id: "open-vuln-working-notes",
    severity: "block",
    reason:
      "Working notes / evidence that map in-progress or unpatched vulnerabilities (recon → remediation). Public before the fix ships is free reconnaissance for an attacker.",
    remediation:
      "Move under internal/. Publish a sanitized advisory only after the fix ships. Keep abstract threat models public.",
    paths: [
      // Agent run ledgers that are explicitly leak/remediation/audit evidence.
      /^\.agent\/runs\/[^/]*(leak|remediation|adversarial|exploit|vuln)[^/]*\//i,
      /^\.agent\/runs\/[^/]*\/evidence\/.*(leak|remediation|adversarial|exploit|vuln|recon|audit)/i,
      // Named remediation / leakage / audit-report docs.
      /^docs\/.*leakage.*\.md$/i,
      /^docs\/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN\.md$/,
      /^docs\/SOTA_REMEDIATION_(PLAN|PROGRESS)\.md$/,
      /^docs\/AUDIT_CLOSURE_.*\.md$/i,
      /^docs\/IPADOS_AUDIT_REPORT.*\.md$/i,
      /^docs\/PROVIDER_DATA_AUDIT\.md$/,
      /^docs\/privacy-wave2-migration-spec\.md$/,
      /^docs\/security\/DETECTION_MATRIX\.md$/,
      /^docs\/plans\/HOSTED_REMOTE_MCP_.*AUDIT.*\.md$/i,
      /^OpenBurnBar SOTA Remediation Plan\.md$/,
      /^plans\/.*(security-remediation|10-security|sota-security).*\.md$/i,
    ],
  },
  {
    id: "agent-working-memory",
    severity: "block",
    reason:
      "Agent working ledgers / internal run notes — internal status, methodology, evidence, and unshipped plans. Not for the public repo.",
    remediation:
      "Move under internal/ (e.g. internal/.agent/runs/…). Publish only sanitized, finalized docs.",
    paths: [/^\.agent\/runs\//, /^\.factory\/goals\//],
  },
];

// ── Public allowlist (overrides internal rules) ───────────────────────────
// A file matching one of these is treated as PUBLIC even if an internal rule
// would otherwise catch it. Use for transparency assets: abstract threat
// models, the privacy policy, the security policy, and OSS migration docs that
// describe *design*, not open holes.
export const PUBLIC_ALLOWLIST = [
  { id: "threat-models", reason: "Abstract threat models — transparency, no open holes disclosed.", paths: [
    /^docs\/THREAT_MODEL\.md$/,
    /^docs\/REMOTE_MCP_THREAT_MODEL\.md$/,
    /^docs\/security\/LLM_GENAI_AGENT_THREAT_MODEL\.md$/,
    /^docs\/security\/PRIVILEGED_INPUT_THREAT_MODEL\.md$/,
    /^docs\/security\/PRIVILEGED_SOCKET_AUTH\.md$/,
  ]},
  { id: "assurance-docs", reason: "Public assurance / supply-chain transparency.", paths: [
    /^docs\/security\/SUPPLY_CHAIN_PROVENANCE\.md$/,
    /^docs\/security\/SOTA_10_10_SIGNOFF\.md$/,
  ]},
  { id: "policy-and-privacy", reason: "Public-facing policy documents.", paths: [
    /^docs\/PRIVACY\.md$/,
    /^\.github\/SECURITY\.md$/,
  ]},
  { id: "oss-migration", reason: "OSS libsignal migration docs — design, public by intent.", paths: [
    /^docs\/signalification\//,
  ]},
  { id: "deepsec-context", reason: "Curated security-architecture context (mirrors public code).", paths: [
    /^\.deepsec\/data\/BurnBar\/INFO\.md$/,
    /^\.deepsec\/data\/BurnBar\/SETUP\.md$/,
  ]},
];
