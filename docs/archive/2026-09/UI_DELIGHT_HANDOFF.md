# UI Delight Handoff — Provider Quota Dashboard

## What we built (backend)

All 22 providers in `AgentProvider.swift` now have quota adapters. Every one returns a `ProviderQuotaSnapshot` with real data or a clean "not available" signal. **Zero estimates anywhere.**

### The data contract

Every adapter returns this shape:

```swift
struct ProviderQuotaSnapshot {
    let provider: AgentProvider          // which provider
    let fetchedAt: Date                  // when the data was grabbed
    let source: ProviderQuotaSourceKind  // .officialAPI | .localSession | .unavailable
    let confidence: ProviderQuotaConfidence  // .exact | .unavailable  (NO .estimated)
    let managementURL: String?           // link to vendor dashboard ("Open official quota")
    let statusMessage: String            // human-readable status line
    let buckets: [ProviderQuotaBucket]   // the actual numbers
}
```

### What "confidence" means

| Confidence | Meaning | Visual treatment |
|-----------|---------|-----------------|
| `.exact` | Real data from source-of-truth API or local DB | Show live numbers, full fidelity |
| `.unavailable` | No source exists or provider not installed | Show "Not available — [enable link]" |

There is NO `.estimated` anywhere. If data isn't real, we say so.

### The 15 providers returning `.exact`

| # | Provider | Source | What's in the buckets |
|---|----------|--------|----------------------|
| 1 | Cursor | `cursor.com/api/usage-summary` (JWT from SQLite) | Plan $, usage %, auto/composer/API breakdowns |
| 2 | Factory | Billing API + dashboard scrape + droid sessions | Token counts, plan limits, per-model stats |
| 3 | Claude Code | Bridge + `~/.claude/projects/*.jsonl` | Token usage per project |
| 4 | Codex | `~/.codex/rollout-*.jsonl` | Per-session token counts |
| 5 | Copilot | GitHub billing API | Usage, suggestions, seat info |
| 6 | Warp | `app.warp.dev/graphql/v2` | AI request count + limit |
| 7 | Ollama | Local daemon + `ollama.com/settings` scrape | Model list, cloud usage % |
| 8 | Z.ai | Monitor API | Token usage |
| 9 | MiniMax | Coding Plan API | Token usage |
| 10 | Aider | `~/.aider/analytics.jsonl` | Session token counts |
| 11 | Forge | `~/forge/.forge.db` SQLite | Conversation count, lines changed |
| 12 | Kimi | `kimi.com/.../GetUsages` API | Weekly tokens, rate limits |
| 13 | Hermes | `~/.hermes/state.db` SQLite | Sessions, tokens, per-model, cost |
| 14 | Kilo Code | VS Code extension `ui_messages.json` | Tasks, token counts |
| 15 | Anthropic/OpenAI/OpenRouter APIs | Official usage endpoints | Cost, tokens by model |

### The 7 providers returning `.unavailable`

Cline, Roo Code, Augment, Gemini CLI, Goose, OpenClaw, Windsurf — each detects whether installed and returns a helpful status message with an enable link.

### Key adapters to know about

- `KimiQuotaAdapter.swift` — moved from `.unavailable` to `.exact` (found real billing API)
- `ForgeQuotaAdapter.swift` — reads SQLite DB, very clean data
- `HermesQuotaAdapter.swift` — richest data of any adapter (tokens, cost, models, sessions)
- `KiloCodeQuotaAdapter.swift` — parses JSON from VS Code extension storage
- `StubQuotaAdapter.swift` — 7 adapters that detect install and return `.unavailable` with links
- `OllamaCloudScraper.swift` — OpenBurnBar login session + HTML scraping for Ollama Cloud usage %
- `FactoryDashboardScraper.swift` — same OpenBurnBar-owned session pattern for Factory personal accounts
- Provider login setup — explicit WKWebView connect buttons store OpenBurnBar-owned session credentials; quota refresh does not read browser Keychain items

### Existing UI to work with

The dashboard already has these components you should extend:

- `ProviderDashboardQuotaPanel.swift` — the main quota card per provider. Already shows header, buckets, freshness, and "Open official quota" link. Has `snapshotFreshness` computed property.
- `ProviderQuotaStripViews.swift` — `QuotaDualWindowStrip` for compact inline bars, `QuotaMicroBadge`, `QuotaSourceBadge`
- `ProviderQuotaBucketViews.swift` — `ProviderQuotaBucketRow` with progress bars, `QuotaSignalView`
- `ProviderDashboardView.swift` — `ProviderCard` for the overview lane
- `DashboardProviderLaneView.swift` — provider ranking lane
- `ProviderQuotaPopoverViews.swift` — popover detail views
- `ProviderQuotaCommandCenterViews.swift` — command center integration

Design tokens: `DesignSystem.Colors`, `DesignSystem.Typography`, `DesignSystem.Spacing`, `DesignSystem.Radius`
Per-provider theming: `ProviderTheme.theme(for: provider)` → `.primaryColor`, `.accentColor`, `.gradient`

### What the user wants for "visual delight"

The backend is rock solid. Now make it feel premium:

- "Live" / "Stale (last seen Xm ago)" / "Not available — connect [link]" states mapped from `confidence` and `fetchedAt`
- Animated transitions when data refreshes
- Empty states that don't look broken
- The new providers (Forge, Hermes, Kimi, Kilo Code) should feel as first-class as Cursor and Claude
- `.unavailable` providers shouldn't just disappear — show them with a clear path to enable
- Progress bars should breathe with the data
- Everything should use `ProviderTheme` for brand colors

### Files you'll likely touch

- `AgentLens/Views/Components/ProviderDashboardQuotaPanel.swift`
- `AgentLens/Views/Components/ProviderQuota/ProviderQuotaStripViews.swift`
- `AgentLens/Views/Components/ProviderQuota/ProviderQuotaBucketViews.swift`
- `AgentLens/Views/Dashboard/ProviderDashboardView.swift`
- `AgentLens/Views/Dashboard/DashboardProviderLaneView.swift`
- `AgentLens/Views/Components/ProviderQuotaViews.swift`
- Possibly new files in `AgentLens/Views/Components/ProviderQuota/`

### Before you start

1. Read `ProviderDashboardQuotaPanel.swift` — it's the main card per provider
2. Grep for `confidence` and `fetchedAt` in the views directory to see where they're already used
3. The `snapshotFreshness` computed property in the quota panel is your starting point for Live/Stale states
4. Provider logos are already handled by `ProviderLogoView`
5. The design system lives in `AgentLens/Theme/DesignSystem.swift`
