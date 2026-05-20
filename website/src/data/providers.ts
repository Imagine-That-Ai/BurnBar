/* Provider support matrix — mirrors docs/PROVIDERS.md + adapter registry
 * Source: dossiers compiled 2026-05-12
 * If docs disagree with code, this file follows code + adapter registry.
 */

export type Confidence = "exact" | "estimated" | "unavailable";

export interface ProviderRow {
  id: string;
  name: string;
  blurb: string;
  source: string; // where the data comes from
  cost: Confidence;
  quota: "yes" | "partial" | "no";
  cred: string; // credential requirement
  notes?: string;
  category: "agent" | "api" | "editor" | "router" | "local";
  shippedToday: boolean; // exposed in app today (vs experimental/stub)
}

export const PROVIDERS_PRIMARY: ProviderRow[] = [
  {
    id: "claude-code",
    name: "Claude Code",
    blurb: "Anthropic's CLI agent — reads ~/.claude/projects/**/*.jsonl",
    source: "Local JSONL + statusline bridge",
    cost: "exact",
    quota: "yes",
    cred: "none (local)",
    notes: "Self-hosted only. Hosted credential collection is not offered.",
    category: "agent",
    shippedToday: true
  },
  {
    id: "codex",
    name: "Codex (OpenAI CLI)",
    blurb: "ChatGPT's coding CLI — reads ~/.codex/sessions/rollout-*.jsonl",
    source: "Local rollout JSONL",
    cost: "exact",
    quota: "yes",
    cred: "none (local) or ~/.codex/auth.json for hosted refresh",
    notes:
      "Primary 5h + secondary 7d quota windows. Hosted runner path is paid-tier and Codex-only.",
    category: "agent",
    shippedToday: true
  },
  {
    id: "openai",
    name: "OpenAI",
    blurb: "Organization-wide usage from the admin API",
    source: "/v1/organization/usage/completions",
    cost: "exact",
    quota: "partial",
    cred: "Org admin key (sk-…)",
    notes:
      "Cost is computed locally from a pricing table (the API returns tokens, not dollars). Hard quota limits are not exposed by OpenAI; runtime 429s feed account health.",
    category: "api",
    shippedToday: true
  },
  {
    id: "copilot",
    name: "GitHub Copilot",
    blurb: "Per-seat premium-interaction + chat limits",
    source: "api.github.com/copilot_internal/user",
    cost: "estimated",
    quota: "yes",
    cred: "GitHub OAuth or PAT (read:user)",
    notes:
      "Token counts come from a token-volume estimate, not raw input/output split. Per-seat billing, not per-token.",
    category: "editor",
    shippedToday: true
  },
  {
    id: "cursor",
    name: "Cursor",
    blurb: "Plan usage in USD straight from Cursor's web API",
    source: "cursor.com/api/usage-summary",
    cost: "exact",
    quota: "yes",
    cred: "Workos session token (auto-extracted)",
    notes:
      "Unofficial endpoint. Enterprise plans fall back to per-line breakdown when plan-limit is 0.",
    category: "editor",
    shippedToday: true
  },
  {
    id: "factory",
    name: "Factory (Droid)",
    blurb: "Plan tier + rolling 5h/7d/30d windows, lane-aware",
    source: "factory.ai org subscription + local session settings",
    cost: "exact",
    quota: "partial",
    cred: "WorkOS browser session captured by FactoryLoginHelper",
    notes:
      "Personal-account billing API returns 403 — partial coverage there. Lane-aware (Spec / Code / Other).",
    category: "agent",
    shippedToday: true
  },
  {
    id: "minimax",
    name: "MiniMax",
    blurb: "Coding Plan remaining quota per model",
    source: "minimax.io coding-plan endpoint",
    cost: "exact",
    quota: "yes",
    cred: "Coding Plan key sk-cp-…",
    notes: "Standard sk-api-… keys do not work — Coding Plan keys only.",
    category: "api",
    shippedToday: true
  },
  {
    id: "zai",
    name: "Z.ai (GLM)",
    blurb: "Token + MCP limits from BigModel monitor API",
    source: "api.z.ai monitor/usage/quota/limit",
    cost: "exact",
    quota: "yes",
    cred: "API key",
    notes: "Endpoint is undocumented — works today, vendor reserves the right to break it.",
    category: "api",
    shippedToday: true
  },
  {
    id: "warp",
    name: "Warp",
    blurb: "Request credits, refresh windows, bonus grants",
    source: "app.warp.dev GraphQL",
    cost: "exact",
    quota: "yes",
    cred: "wk-… API key",
    notes: "Spoofed User-Agent required upstream.",
    category: "editor",
    shippedToday: true
  },
  {
    id: "ollama",
    name: "Ollama",
    blurb: "Local models cost zero; Cloud routing optional",
    source: "localhost:11434 + ollama.com (cloud)",
    cost: "exact",
    quota: "partial",
    cred: "none (local); Ollama Cloud API key (cloud)",
    notes:
      "Token counts come from per-response prompt_eval / eval counts; cloud quota needs explicit login.",
    category: "local",
    shippedToday: true
  },
  {
    id: "kimi",
    name: "Kimi (Moonshot)",
    blurb: "Weekly tokens + requests from kimi.com billing service",
    source: "kimi.com BillingService",
    cost: "exact",
    quota: "yes",
    cred: "JWT bearer from kimi.com session or KIMI_AUTH_TOKEN",
    notes: "Public PROVIDERS.md is stale on Kimi — adapter ships in v0.66+.",
    category: "agent",
    shippedToday: true
  },
  {
    id: "openrouter",
    name: "OpenRouter",
    blurb: "Per-call cost in USD straight from the vendor",
    source: "openrouter.ai /v1/activity",
    cost: "exact",
    quota: "no",
    cred: "API key sk-or-…",
    notes:
      "The only provider that returns actual cost in dollars. Usage-only path — no quota signal.",
    category: "router",
    shippedToday: true
  },
  {
    id: "anthropic",
    name: "Anthropic Console",
    blurb: "Org-wide messages usage report",
    source: "api.anthropic.com /v1/organizations/usage_report/messages",
    cost: "estimated",
    quota: "partial",
    cred: "sk-ant-admin-… (org admin)",
    notes:
      "Regular sk-ant-api03-… keys are rejected. Daily granularity, ~24h lag. Cost computed from pricing table.",
    category: "api",
    shippedToday: true
  },
  {
    id: "aider",
    name: "Aider",
    blurb: "Local analytics — tokens only, no vendor quota",
    source: "~/.aider/analytics.jsonl",
    cost: "exact",
    quota: "no",
    cred: "none",
    notes: "Spend tracking only — Aider has no vendor-side quota concept.",
    category: "agent",
    shippedToday: true
  },
  {
    id: "forge",
    name: "Forge",
    blurb: "Counts from ~/forge/.forge.db; routes through local gateway",
    source: "Local SQLite",
    cost: "estimated",
    quota: "no",
    cred: "none",
    notes:
      "Forge routes through OpenBurnBar's local gateway at 127.0.0.1:8317, so vendor cost is $0; counts are conversation/file/active-model.",
    category: "agent",
    shippedToday: true
  }
];

export const PROVIDERS_DETECTED: ProviderRow[] = [
  {
    id: "gemini-cli",
    name: "Gemini CLI",
    blurb: "Per-session disk tokens exist, but Google AI Studio has no quota API.",
    source: "Local session files only",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    notes: "Shown as Installed / Not installed only.",
    category: "agent",
    shippedToday: true
  },
  {
    id: "cline",
    name: "Cline",
    blurb: "Detection only; no usage API exposed",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "editor",
    shippedToday: true
  },
  {
    id: "roo-code",
    name: "Roo Code",
    blurb: "Detection only",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "editor",
    shippedToday: true
  },
  {
    id: "kilo-code",
    name: "Kilo Code",
    blurb: "Detection only",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "editor",
    shippedToday: true
  },
  {
    id: "augment",
    name: "Augment",
    blurb: "Detection only",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "editor",
    shippedToday: true
  },
  {
    id: "windsurf",
    name: "Windsurf",
    blurb: "Detection only",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "editor",
    shippedToday: true
  },
  {
    id: "goose",
    name: "Goose",
    blurb: "Detection only",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "agent",
    shippedToday: true
  },
  {
    id: "openclaw",
    name: "OpenClaw",
    blurb: "Detection only",
    source: "Install detection",
    cost: "unavailable",
    quota: "no",
    cred: "—",
    category: "agent",
    shippedToday: true
  }
];

export const PROVIDERS_ALL = [...PROVIDERS_PRIMARY, ...PROVIDERS_DETECTED];

export const CONFIDENCE_LABEL: Record<Confidence, string> = {
  exact: "Exact",
  estimated: "Estimated",
  unavailable: "Unavailable"
};

export const CONFIDENCE_BLURB: Record<Confidence, string> = {
  exact: "Numbers come from the vendor's own API or local logs — counted, not guessed.",
  estimated:
    "Numbers come from a local pricing table or a token estimate. Good for trends. Bad for tax audits.",
  unavailable: "The vendor doesn't expose this. We mark it so, instead of pretending."
};
