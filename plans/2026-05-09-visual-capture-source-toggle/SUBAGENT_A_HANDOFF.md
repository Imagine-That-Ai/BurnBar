# Subagent A — Research & Registry Handoff

**Date:** 2026-05-09
**Branch:** `perf/hot-paths-latency-wins`
**Owner:** Subagent A — Research & Registry

## 1) Exact `Both` list implemented (11 active)

Per audit-corrected table (`plans/2026-05-09-visual-capture-source-toggle/README.md` §1) — Both = CLI **and** Desktop visual surfaces, toggle-eligible:

| # | Provider (`AgentProvider`) | CLI surface | Desktop twin | `visualSurfaces` |
|---|----------------------------|-------------|--------------|------------------|
| 1 | **codex** | `codex-cli` (`~/.codex/sessions/rollout-*.jsonl`) | `codex-desktop` / ChatGPT Desktop | `["cli","desktop"]` |
| 2 | **claudeCode** | `claude-code` (`~/.claude/projects/**/*.jsonl`) | `Claude Desktop` (`/Applications/Claude.app`) | `["cli","desktop"]` — catalog `anthropic` |
| 3 | **cursor** (+ `cursorAgent`) | `cursor-agent` (`~/.cursor-agent/sessions/`) | Cursor IDE (`/Applications/Cursor.app`) | `["cli","desktop"]` — via `cursor-desktop` |
| 4 | **factory** | `factory-droid` (`droid` binary) | Factory Desktop (`factory.ai/product/desktop`) | `["cli","desktop"]` |
| 5 | **minimax** | `minimax-cli` | MiniMax Desktop / Agent (`agent.minimax.io/download`) | `["cli","desktop"]` |
| 6 | **zai** | `zai-cli` | ZCode Desktop (`zcode.z.ai`) | `["cli","desktop"]` — alias `zcode-desktop` |
| 7 | **devin** *(new)* | `devin-cli` (`devin` binary) | Devin Desktop (`devin.ai/desktop`, successor to Windsurf) | `["cli","desktop"]` |
| 8 | **hermes** | `hermes` CLI | Hermes Dashboard TUI | `["cli","desktop"]` — `hermes-desktop` |
| 9 | **warp** | `warp` CLI (GraphQL) | Warp Terminal (`/Applications/Warp.app`) | `["cli","desktop"]` |
| 10 | **openCode** | `opencode` CLI (`~/.local/share/opencode/opencode.db`) | OpenCode TUI | `["cli","desktop"]` |
| 11 | **ollama** | `ollama` service (`localhost:11434`) | Ollama Desktop (`/Applications/Ollama.app`) | `["cli","desktop"]` — plus `ollama-local` |

**Legacy:** `windsurf` → deprecated 2026-06-02, now `devin-desktop`. No toggle; existing rows migrate via `devin` aliases; `AgentProvider.windsurf` retained for backward compat, `ProviderStatus` still shows `windsurf` as `.unavailable` legacy row, `devin` as canonical.

**Plugin-only (NO toggle):** `cline`, `kiloCode`, `rooCode`, `augment`, `junie` — VS Code/JetBrains host window, not standalone `.app`. All get `["cli"]` or omitted; toggle ineligible.

**CLI-only (NO toggle):** `antigravity`, `geminiCLI`, `kimi`, `copilot`, `aider`, `goose`, `openClaw`, `openClaude`, `omp`, `xAI`, `mimo`, `piAgent`, `forgeDev`, `primeAgent`, `muse`, plus routing-only catalog providers (`openai`, `google`, `deepseek`, `mistral`, `meta`, `cohere`, `amazon`, `alibaba`, `moonshot`, `misc`, `mlx`) → `["cli"]`.

Toggle eligibility rule: `catalog.json` → `visualSurfaces` contains both `cli` **and** `desktop`.

## 2) New `AgentProvider` cases added

- **`case devin = "Devin"`** — inserted after `.windsurf` in `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AgentProvider.swift`
  - `CaseIterable` auto-included; order preserved for `swarmGlyphProviders` (inserted after `.windsurf`, before `.warp`)
  - `persistedToken` → `"devin"` (lowercased, space-stripped)
  - `providerID` → `ProviderID(rawValue: "devin")` via default `persistedToken` fallback (explicit `case "devin"` in `fromProviderID`)
  - `fromCatalogProviderID` handles aliases: `"devin"`, `"devin-desktop"`, `"devin_desktop"`, `"devin-cli"`, `"devin_cli"`, `"devin.ai"`, `"devinai"` → `.devin`
  - `bundledLogoName` → `"DevinLogo"`
  - `iconName` → `"desktopcomputer"`
  - `DesignSystem.Colors.primary(for: .devin)` → `#0A84FF`, `accent` → `#1E293B`; `DesignSystemTokens.providerHex` → `0A84FF`
  - Exhaustive switches patched where adding a case forces build failure: `SwarmColorDriver`, `ThemePrimitives`, `AgentProvider+LogoBackdrop`, `SwarmCanvasView+ShapeData` (new `.devin` shape = copy of `.windsurf`), `BurnBarResumeService` (two sites: displayName + hintDirectory), `AgentHarnessImportJobListener`, `OpenBurnBarChatWorkspaceConfigurator`, `CLIAgentResumePresentation`, `AgentLens/Models/AgentProvider` (`supportLevel`/etc), `SmartHubBridgeController`, `G2ParserParity`, plus `ProviderBrand` below.

No other `AgentProvider` cases added; `windsurf` retained as LEGACY.

**Regenerated:** `OpenBurnBarCore/Sources/OpenBurnBarParserSupport/AgentProviderIngestionCatalog.generated.swift` via `node scripts/generate-provider-ingestion-catalog.mjs` — adds `devin` entry (`providerID: "devin"`, aliases `["devin-desktop","devin-cli","windsurf"]`, paths `~/.config/Devin/sessions` / `~/Library/Application Support/Devin/sessions`, `ingestion: .localParser`, `quotaSignal: false`). `contracts/provider-ingestion-catalog.json` updated as source of truth.

## 3) `catalog.json` snippet

`OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json` now carries `visualSurfaces` per provider; validates via `python3 -m json.tool`. Added `devin` catalog provider (routing+accounting, `openai_compat`, one public model) to represent Both list in routing catalog.

```json
// Both example (9 of 22 providers):
{
  "id": "anthropic",
  "displayName": "Anthropic",
  "visualSurfaces": ["cli", "desktop"],
  ...
},
{
  "id": "factory",
  "visualSurfaces": ["cli", "desktop"]
},
{
  "id": "codex",
  "visualSurfaces": ["cli", "desktop"]
},
{
  "id": "zai",
  "visualSurfaces": ["cli", "desktop"]
},
{
  "id": "devin",
  "displayName": "Devin",
  "baseURL": "devin://local",
  "visualSurfaces": ["cli", "desktop"],
  "models": [{
    "id": "devin-default-family",
    "displayName": "Devin Default"
  }]
}

// CLI-only example (13 of 22):
{
  "id": "openai",
  "visualSurfaces": ["cli"]
},
{
  "id": "google",
  "visualSurfaces": ["cli"]
}
```

Full counts: `Both` = ['anthropic', 'factory', 'codex', 'opencode', 'zai', 'minimax', 'ollama', 'ollama-local', 'devin'] → 9 catalog entries (`anthropic`, `factory`, `codex`, `opencode`, `zai`, `minimax`, `ollama`, `ollama-local`, `devin`). `CLI-only` = ['openai', 'google', 'mimo', 'xai', 'deepseek', 'mistral', 'meta', 'cohere', 'amazon', 'alibaba', 'moonshot', 'misc', 'mlx'] → 13 entries. Plugin-only not in routing catalog (represented in `AgentProvider` + `TokenUsage` + `PROVIDERS.md`).

`BurnBarCatalogProvider` (`OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarCatalog.swift`) extended: `bundledLogoName(forProviderID:)` now handles `"devin"`, `"factory-desktop"`, `"claude-desktop"`, `"warp-desktop"`, `"ollama-desktop"`, `"zcode*"` , `"minimax-desktop"`, `"codex-desktop"`, `"cursor-desktop"` → appropriate logo keys, so `visualSurfaces` addition does not break decoding (unknown keys ignored).

## 4) `TokenUsage` alias additions

`OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TokenUsage.swift` — `UsageExecutionSourceResolver`:

**`fromClientMarker` alias table** — specific before generic, ordered to avoid shadowing:

```swift
let aliases: [(needles: [String], source: UsageExecutionSource)] = [
    (["codex desktop", "codex-desktop", "chatgpt desktop"], known("codex-desktop", "Codex Desktop", .desktopApp)),
    (["codex vscode", ...], known("codex-vscode", ...)),
    (["codex web", ...], known("codex-cloud", ...)),
    (["claude desktop", "claude-desktop"], known("claude-desktop", "Claude Desktop", .desktopApp)),
    (["cursor desktop", "cursor-desktop", "cursor ide", "cursor-ide"], known("cursor-desktop", "Cursor Desktop", .ide)),
    (["factory desktop", "factory-desktop"], known("factory-desktop", "Factory Desktop", .desktopApp)),
    (["minimax desktop", "minimax-desktop", "minimax agent", "minimax-agent"], known("minimax-desktop", "MiniMax Desktop", .desktopApp)),
    (["zcode desktop", "zcode-desktop", "z.ai desktop", "z.ai-desktop", "zai desktop", "zai-desktop"], known("zcode-desktop", "ZCode Desktop", .desktopApp)),
    (["devin desktop", "devin-desktop"], known("devin-desktop", "Devin Desktop", .desktopApp)),
    (["devin cli", "devin-cli", "devin"], known("devin-cli", "Devin CLI", .cli)),
    (["warp desktop", "warp-desktop", "warp terminal", "warp-terminal"], known("warp-desktop", "Warp Desktop", .desktopApp)),
    (["ollama desktop", "ollama-desktop"], known("ollama-desktop", "Ollama Desktop", .desktopApp)),
    (["hermes dashboard", "hermes-desktop", "hermes dashboard tui"], known("hermes-desktop", "Hermes Dashboard", .desktopApp)),
    // ... generic fallbacks after specific ...
    (["cursor"], known("cursor", "Cursor", .ide)),
    (["factory-droid", "factory droid", "factory"], known("factory-droid", ...)),
    (["codex"], known("codex-cli", ...)),
    // ... windsurf, warp (cli), gemini-cli, openburnbar etc unchanged ...
]
```

**`knownSource(matching:)`** — now includes all new IDs for `explicitID` resolution:
`codex-cli`, `codex-desktop`, `codex-vscode`, `codex-cloud`, `cursor`, `cursor-desktop`, `grok-build`, `claude-code`, `claude-desktop`, `factory-droid`, `factory-desktop`, `minimax-cli`, `minimax-desktop`, `zai-cli`, `zcode-desktop`, `devin-cli`, `devin-desktop`, `warp`, `warp-desktop`, `ollama`, `ollama-desktop`, `hermes`, `hermes-desktop`, `opencode`, `openburnbar`, `windsurf`, `cline`, `kilo-code`, `roo-code`.

**`providerLogSource(for:)`** — added:
```swift
case .devin: return known("devin-cli", "Devin CLI", .cli, .derivedExact)
```
(`.codex` stays `nil` — rollout `session_meta` distinguishes CLI vs Desktop; `.devin` currently defaults to CLI, desktop via explicitID/client marker.)

## 5) `ProviderBrand` + assets

`AgentLens/Models/ProviderBrand.swift`:
- `logoAssetCandidates(for:)` — new cases:
  - `"zcode"`, `"zcode-desktop"` → `["ZCodeLogo","ZCodeDesktopLogo","ZaiLogo", ...]`
  - `"minimax-desktop"` → `["MiniMaxDesktopLogo","MiniMaxLogo"]`
  - `"factory-desktop"` → `["FactoryDesktopLogo","FactoryLogo"]`
  - `"devin"`, `"devin-desktop"`/`"devin-cli"` → `["DevinLogo","DevinDesktopLogo"]`
  - `"claude-desktop"` → `["ClaudeDesktopLogo","ClaudeCodeLogo","AnthropicLogo"]`
  - `"warp-desktop"` → `["WarpDesktopLogo","WarpLogo"]`
  - `"ollama-desktop"` → `["OllamaDesktopLogo","OllamaLogo"]`
  - `"codex-desktop"` → `["CodexDesktopLogo","CodexLogo","OpenAILogo"]`
  - `"cursor-desktop"` → `["CursorDesktopLogo","CursorLogo"]`
  - `"hermes-desktop"` → `["HermesDesktopLogo","HermesLogo"]`
- `colorForProviderID` — distinct colors for `zcode*` (`#7C3AED`), `factory-desktop` (`#8B5CF6`), `devin*` (`#0A84FF`), `claude-desktop` (`#CC785C`), etc., mirroring `FactoryDesktop→purple`, `Devin→blue`.
- `iconForProviderID` — matching SF Symbols (`zcode`→`bolt.fill`, `factory-desktop`→`cpu.fill`, `devin*`→`desktopcomputer`, etc.)

**Assets created** (`AgentLens/Resources/Assets.xcassets/` — each `*.imageset` with `Contents.json` + SVG, cloned from existing brand SVGs to avoid missing-asset build warnings, preserves-vector, template `original`):
- `DevinLogo.imageset/` + `DevinDesktopLogo.imageset/` (from `PrimeAgentLogo.svg`)
- `FactoryDesktopLogo.imageset/` (from `FactoryLogo.svg`)
- `MiniMaxDesktopLogo.imageset/` (from `MiniMaxLogo.svg`)
- `ZCodeLogo.imageset/` + `ZCodeDesktopLogo.imageset/` (from `ZaiLogo.svg`)
- `ClaudeDesktopLogo.imageset/` (from `ClaudeCodeLogo.svg`)
- `WarpDesktopLogo.imageset/` (from `WarpLogo.svg`)
- `OllamaDesktopLogo.imageset/` (from `OllamaLogo.svg`)
- `CodexDesktopLogo.imageset/` (from `CodexLogo.svg`)
- `CursorDesktopLogo.imageset/` (from `CursorLogo.svg`)
- `HermesDesktopLogo.imageset/` (from `HermesLogo.svg`)

`AgentLens/Theme/DesignSystem.swift` + `OpenBurnBarCore/Sources/OpenBurnBarUI/SharedModels/DesignSystemTokens.swift` + `ThemePrimitives.swift` patched for `.devin` primary/accent.

## 6) `docs/PROVIDERS.md`

- **Provider Status Table:** new row after Windsurf:
  `| **Devin** | _none_ / Local scans | `.exact` | `devin` CLI + `/Applications/Devin.app` (Devin Desktop — successor to Windsurf per devin.ai/blog/windsurf-is-now-devin-desktop) + `~/.config/Devin/sessions/*.jsonl` | Local CLI + Desktop (Both: `devin-cli` / `devin-desktop` toggle) — legacy `windsurf` rows migrate to `devin-desktop` |`
- **Execution-Source Attribution:** expanded paragraph into full “Known Execution Sources” table (27 rows) with `Both` vs `CLI-only` vs `Plugin-only` vs `LEGACY` and note `Audit-corrected 2026-05-09: Both = 11 active`.

## 7) Validation

```bash
python3 -m json.tool OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json > /dev/null
# → rc 0 (valid JSON, 22 providers, visualSurfaces present on all)

bash scripts/ci/check-no-suppressions.sh
# → ✓ check-no-suppressions: no unjustified suppressions or baselines. (allowlist 19 artifact paths, 25 scoped source file(s))

# No TODO/FIXME left in owned files (grep TODO|FIXME → clean on 6 owned files)

xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
# → ** BUILD SUCCEEDED ** (warnings only; after fixing exhaustive switches for new .devin case in SwarmColorDriver, ThemePrimitives, AgentProvider+LogoBackdrop, SwarmCanvasView+ShapeData, BurnBarResumeService, etc.)

# TokenUsage resolver smoke (manual):
# fromClientMarker("Factory Desktop") → factory-desktop (.desktopApp) ✓
# fromClientMarker("claude-desktop") → claude-desktop ✓
# fromClientMarker("devin desktop") → devin-desktop ✓ ; "devin" → devin-cli ✓
# fromClientMarker("warp desktop") → warp-desktop ✓
# resolve(provider: .devin, usageSource: .providerLog) → devin-cli (.cli, .derivedExact) ✓
```

## 8) File list

**Owned (required):**
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json` (added `visualSurfaces` + `devin` provider)
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/TokenUsage.swift` (alias table, `knownSource`, `providerLogSource`)
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AgentProvider.swift` (`case devin`, `swarmGlyphProviders`, `fromProviderID`, `fromCatalogProviderID`, `bundledLogoName`, `iconName`)
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarCatalog.swift` (`bundledLogoName` for desktop variants)
- `AgentLens/Models/ProviderBrand.swift` (logo/color/icon for desktop variants)
- `AgentLens/Resources/Assets.xcassets/DevinLogo.imageset/` + `DevinDesktopLogo` + `FactoryDesktopLogo` + `MiniMaxDesktopLogo` + `ZCodeLogo` + `ZCodeDesktopLogo` + `ClaudeDesktopLogo` + `WarpDesktopLogo` + `OllamaDesktopLogo` + `CodexDesktopLogo` + `CursorDesktopLogo` + `HermesDesktopLogo` (12 new imagesets, via `PrimeAgentLogo` pattern)
- `docs/PROVIDERS.md` (Devin row + execution-source table)

**Ancillary (exhaustive-switch fixes to keep build green after adding `.devin`):**
- `AgentLens/Theme/DesignSystem.swift`, `OpenBurnBarCore/Sources/OpenBurnBarUI/SharedModels/DesignSystemTokens.swift`, `ThemePrimitives.swift`, `SwarmColorDriver.swift`, `SwarmCanvasView+ShapeData.swift`, `AgentProvider+LogoBackdrop.swift`, `AgentLens/Models/AgentProvider.swift` (`supportLevel`/`dataConfidence`), `OpenBurnBarDaemon/.../BurnBarResumeService.swift`, `AgentLens/Services/CloudSync/AgentHarnessImportJobListener.swift`, `OpenBurnBarChatWorkspaceConfigurator.swift`, `CLIAgentResumePresentation.swift`, etc. (each adds `.devin` alongside `.windsurf` where exhaustive)

**Generated (regen):**
- `OpenBurnBarCore/Sources/OpenBurnBarParserSupport/AgentProviderIngestionCatalog.generated.swift`
- `contracts/provider-ingestion-catalog.json` (source for above)

## 9) Notes for B–E

- Toggle eligibility = `visualSurfaces.contains("desktop") && contains("cli")` in `catalog.json` **or** `AgentProvider` in Both list. Future B/C will read this + `UsageExecutionSourceResolver` aliases.
- Existing `windsurf` rows: `fromClientMarker("windsurf")` still → `windsurf` (legacy). Migration to `devin-desktop` should be done at query/display time (e.g., `SELECT CASE WHEN executionSourceID='windsurf' THEN 'devin-desktop' ELSE executionSourceID END`) per audit correction; ingestion keeps legacy ID for audit trail.
- No `UserDefaults`/UI/capture/telemetry touched — B handles prefs, C engine, D UI, E QA.
