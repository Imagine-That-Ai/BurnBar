# The Castle — Master Implementation Plan (v2, hardened)

> **Status:** Ready to build. Grounded in the **shipped** Ministry + empirical smoke tests of 11 agent CLIs + a design-system inventory, then **adversarially verified** (one loophole-hunt round, 18 findings, all fixes folded below). New file — builds **on top of** `docs/THE_MINISTRY.md`; changes neither.
> **Canonical repo root:** `/Users/albertonunez/Documents/Developer/BurnBar` (branch `security/run-09-privacy-invariants-hardening`).
> **One-line:** The Ministry is the **brain** that picks `(model)`; the Castle widens that to `(runtime, model)` across every supported agent CLI — and dresses the fan-out in a **House** for each runtime. Two co-equal pillars: **A) the runtime adapter layer**, **B) the Houses visual-delight layer.**
> **What v2 fixed:** commit-pollution from plugin/hook-injected files (`git add -A` → scoped add + worktree exclude); `runtime` candidate stamping (default-droid no longer filters out the live universe); catalog-rank canonicalization so flagship ids don't score 0; runtime-aware dedup; the Core/AgentLens layering inversion for `House`; and the honest reclassification of Pillar B's macOS work as **build-a-view + a Python→Swift bridge**, not "assemble." Plus the verified upgrade: **the Castle resolves the Ministry's capability ceiling.**

---

## How this builds on the Ministry

The Ministry ships: `tools/openburnbar-mcp/ministry.py` (1,211 lines) + 12 `ministry_*` tools, verified. Its launch layer is **hardwired to `droid exec`** (`smoke_probe`:974, `build_droid_command`:1078, `disabled_tools_arg`:757, candidate source `~/.factory/settings.json customModels[]`). The Castle generalizes that launch step behind a `RuntimeAdapter` protocol and **leaves the Ministry brain untouched**. The trustworthy signal — `is_error==false AND HEAD != BASE_SHA` (`collect_result`:1137) — is runtime-independent and carries over verbatim. **The injection seam already exists and is verified:** `select_model_for_wand`(:810)/`select_models_for_wand`(:884) take `probe_runner`, with `runner = probe_runner or smoke_probe` (:856/:920). The Castle passes `adapter.smoke_probe` there — the selection brain needs zero change to drive a new runtime.

---

## Live proofs (this session) — including the ceiling resolution

| Proof | Result |
|---|---|
| Authenticated gateway read | `GET 127.0.0.1:8317/v1/models` Bearer → 200, 24 rows `data[]` |
| **House Claude @ flagship** | `claude -p --permission-mode bypassPermissions --model opus` → commit `3b40336`, `modelUsage: claude-opus-4-8` (**catalog rank 110**) |
| **House Codex @ flagship** | `codex exec -s danger-full-access` @ **gpt-5.5** (rank 90) → real commit landed |
| **House Gemini @ flagship** | `gemini -p -o json --approval-mode yolo` @ **gemini-3.1-pro-preview** → real commit landed |
| droid / opencode / cursor-agent / kimi / pi | all landed commits headless (see roster) |

**The capability ceiling is RESOLVED.** The Ministry's "mid-tier headless ceiling" was specific to routing claude *through the OBB gateway* (a TUI bridge). The Castle drives **flagship models headless via each vendor's own CLI** across **≥3 Houses** — claude-opus-4-8 (110), gpt-5.5 (90), gemini-3.1-pro. The Castle's Council Wand can finally reach the top tier.

---

## Empirical runtime roster (smoke-tested; PASS iff `HEAD != base`)

| House | Headless recipe | Autonomy-for-commit | Completion parse | Verdict |
|---|---|---|---|---|
| **droid** | `droid exec --auto <lvl> -m <arg> -o json -f p` | `--auto medium\|high` | JSON `is_error` | PASS |
| **codex** | `codex exec -C <cwd> -m <m> -s danger-full-access --json -o last.json <p> </dev/null` | `-s danger-full-access` | JSONL terminal `turn.completed` (vs `thread.error`) | PASS |
| **claude** (direct) | `claude -p --output-format stream-json --permission-mode bypassPermissions --model <full-id> [--mcp-config <f> --strict-mcp-config]` | `bypassPermissions` | JSON `is_error` | PASS |
| **gemini** | `gemini -p "<p>" -m <m> -o json --approval-mode yolo --skip-trust </dev/null` | `--approval-mode yolo` | **empty/invalid stdout OR exit≠0 → fail; else `error==null`** | PASS |
| **opencode** | `opencode run --prompt "<p>" -m <provider/model> --format json --dangerously-skip-permissions` | `--dangerously-skip-permissions` | JSONL event stream (no single envelope) | PASS |
| **cursor-agent** | `cursor-agent -p --model <m> --output-format json --force` | `-p --force` | JSON | PASS (native worktree) |
| **kimi** | `kimi -p "<p>" -m <alias> --output-format stream-json` | default `-p` commits | stream-json | PASS |
| **pi** | `pi -p "<p>" --provider <prov> --model <id> --mode json` | implicit in `-p` | `--mode json` | PASS (needs provider key) |
| forge | `forge -p "<p>"` | tools on | text / `forge data` | FLAKY (timeouts) |
| agy (antigravity) | `agy --print … --dangerously-skip-permissions` | — | text only | FAIL (mis-parses, no commit) |
| continue / goose / grok | — | — | — | ABSENT |

**8 Houses drivable headless today.** The #1 law (proven across 11 CLIs): **advertised ≠ drivable** — every `(runtime, model)` must pass a real landed-commit smoke-probe before joining the launchable universe.

---

# PILLAR A — The Runtime Layer

## A1. Architecture

Castle = multi-runtime **execution** (the houses); Ministry = the **selection** brain (unchanged). `wand → selector ranks (runtime,model) pairs across allowed Houses (Ministry brain) → adapter.smoke_probe (Castle, gated by the unchanged landed-commit rule) → adapter.build_command (Castle) → spawn into worktree+cmux (unchanged runbook) → collect_result via adapter.parse + the unchanged gate`. New `castle.py` holds the `RuntimeAdapter` protocol + `REGISTRY` + adapters; MCP surface adds `castle_list_runtimes`, `castle_list_launchable(runtime?)`, `castle_smoke_probe(runtime, arg, autonomy)`, `castle_build_command(runtime, …)`.

## A2. The `RuntimeAdapter` protocol (9 methods + 2 v2 corrections)

| Method | Contract | Per-runtime variance |
|---|---|---|
| `enumerate_launchable_models()` → `[Candidate]` | the House's candidate set; **each candidate carries `runtime` AND a `catalog_id` canonicalized to the joinable form** (see A4) | droid: `customModels[]`+allowlist; **codex: parse `~/.codex/config.toml` `model_providers[]`+`profiles` in Python** (do not depend on inherited runtime config); claude: alias→full-id map; gemini/opencode/kimi/pi: `<cli> models`/`--list-models` |
| `resolve_model_arg(candidate)` → `str` | the `-m` string actually passed | droid bare/`custom:`; opencode/pi `provider/model`; codex `model`(+`-c model_provider=`); **claude FULL id, never the bare `opus` alias** |
| `build_command(...)` → `{argv}` | headless invocation; reuses the Ministry done-marker wrapper **with a per-runtime stdin/redirect override** (codex needs `</dev/null`; gemini stderr-captured separately) | the main thing that differs |
| `required_autonomy_for_commit(autonomy)` | abstract `{low,med,high}` → the runtime's write+commit flag | droid `--auto`; codex `-s danger-full-access`; claude `bypassPermissions`; gemini `yolo`; kimi `-p`; cursor `--force` |
| `parse_completion(stdout, stderr, exit_code)` → `{is_error}` | feeds the same gate; **gemini keys on empty/invalid stdout OR exit≠0** | droid/claude/cursor have `is_error`; gemini `error==null`+exit; codex/opencode/kimi parse the stream's terminal event |
| `auth_precondition()` | checked before the probe | droid `auth.v2.file` (NO `FACTORY_API_KEY`); codex `auth.json`; claude OAuth; gemini google; … |
| **`worktree_isolation(worktree)`** *(renamed from `mcp_scope` — v2)* | **isolate the worker from BOTH inherited MCP servers AND plugin/hook-injected scratch dirs** | droid disables 3 MCP servers (namespaced); claude `--mcp-config --strict-mcp-config`; **all adapters seed `.git/info/exclude` with `.serena/` + tool scratch dirs at launch** (see A3) |
| `smoke_probe(model_arg, autonomy, ttl)` → `{landsCommit}` | the Ministry's disposable-temp-repo recipe; **uses the scoped commit (A3)** | identical gate |
| `launch_id()` / `completion_signal()` | runtime id + done-marker | all use the done-marker |

**`DroidAdapter` ships first by extraction** — wraps existing `ministry.py` functions verbatim **except it now stamps `runtime="droid"` on every candidate** (the one required change; see A4-H1). codex/claude/gemini/opencode/cursor-agent/kimi/pi slot in as siblings.

## A3. Commit hygiene (v2 blocker fix — the most important correction)

The plan must **NOT** use `git add -A`. The Ministry's *shipped, proven-safe* pattern is a **scoped** add (`git add ministry_probe.txt`, ministry.py:1010). Reason, empirically proven: codex (via a `[plugins.serena]` + `session_start` **hook**, not an MCP server) and droid both write a `.serena/` dir into the worker cwd; `-A` commits `.serena/.gitignore`+`project.yml` into the worker's commit, and **the landed-commit gate does not catch it** (a polluted commit still moves HEAD). No `mcp_scope` flag suppresses the codex hook; `--ignore-user-config` would, but it also drops the `model_providers[]` the codex adapter needs.

**Rule (every adapter):** (1) worker/probe prompt instructs a **scoped** `git add <task-files>` (or `git add -u` for edits), never `-A`; (2) `worktree_isolation` seeds `.git/info/exclude` with `.serena/`, `.codex/`, and tool scratch dirs at launch; (3) the codex adapter reads `model_providers[]`/`profiles` by **parsing config.toml in Python** so enumeration never depends on the inherited runtime config; (4) a test asserts the landed commit's tree contains **only** intended files.

## A4. Wands extend to `(runtime, model)` — with the v2 selector fixes

- Wand gains **`allowRuntimes: list[str]`** + optional `runtimePreference` (sanitizer mirrors the `BACKENDS` guard at ministry.py:40 with a `RUNTIMES` set — confirmed clean).
- **H1 (blocker fix):** every candidate must carry a `runtime` key. `DroidAdapter.enumerate` stamps `runtime="droid"`; the `allowRuntimes` filter treats a **missing** runtime as `droid` so the 49 live candidates and the existing 12+62 tests stay green. Default `allowRuntimes` absent → `["droid"]`, but the filter is membership-OR-missing, so nothing is dropped.
- **H2 (major fix):** **runtime-aware dedup.** The existing `_dedupe_candidates` keys on `(backend, arg)` — extend to `(runtime, backend, arg)` so the same model from two Houses keeps its `(runtime, model)` identity; define precedence (proven-headless runtime wins, then `runtimePreference`).
- **H3 (major fix):** **catalog canonicalization + rank backfill.** `enumerate` emits a `catalog_id` (claude `opus`→`claude-opus-4-8` rank 110; gemini `gemini-3.1-pro-preview` under provider `google` has `capabilityClassRank:null`). Reuse the existing `KNOWN_CAPABILITY_RANK_FALLBACKS` + `test_glm_52` pattern to backfill direct-CLI flagship ranks; add a test exercising the real catalog join for a direct-CLI provider. Without this, a Council floor ≥50 silently excludes the very flagships that land commits.
- Selector sort key gains `runtime_pref_tier` **after** capability/cost/quota, **before** the `arg` tie-break (confirmed it composes): `best → (qtier, -rank, costUnknownTier, price, runtime_pref_tier, arg)`. Provider-diversity extends to runtime-diversity via a `used_runtimes` set.
- **Subscription quota (verified-correct, keep):** codex/claude/gemini run on the user's own ChatGPT/claude.ai-Max/Google subscriptions, not the gateway → `quota="unavailable"`, `qtier=0` (not penalized), surfaced as the B4 dashed-ring "quota unknown". There is genuinely no quota signal for subscription Houses, and the plan tells that truth.

## A5. The 9 gotcha classes (each a smoke-probe assertion)

A Autonomy-default · B Commit-only-if-instructed · C Completion-signal shape (never trust exit code — **except gemini, whose only captured failure signal is exit≠0**) · D Model-resolution (`provider/model`; **codex tier-gated** — gpt-5.3-codex rejected by a ChatGPT login while gpt-5.5 works; rely on the smoke gate + fallback chain; droid `custom:` renumbers every 60s) · E Auth (OBB-gateway claude = TUI bridge, fails headless — the key carry-over; setting `FACTORY_API_KEY` breaks droid) · F MCP-inheritance · G Sandbox-blocks-git · H Broken-CLI · **I (v2) Worktree-pollution** — plugins/hooks (codex serena) write scratch dirs the model didn't create; scoped add + `.git/info/exclude` are the only defense, and the landed-commit gate does NOT catch pollution.

## A6. Registry fixes

Add `SwitcherCLIProfileType` cases for **gemini, kimi, pi** (installed, drivable, absent from the 8-case enum). Fix the **cursor-agent auth bug** (`CLIAuthDiscovery.swift:218` falls back to `~/.cursor-agent`, which is absent; real dirs `~/.cursor` + `~/.local/share/cursor-agent`). Keep `hermes`/`openClaw`/relay-`pi` out of the *worker* set (chat relays). Note: `pi`-the-CLI ≠ `AssistantRuntimeID.pi`-the-relay-assistant; keep that rawValue stable.

---

# PILLAR B — The Houses (UI / visual delight)

**v2 honest reclassification:** on macOS this is **build a new surface + a Python→Swift bridge, then dress it** — *not* "assemble." The crest *primitives* and the *iOS* fan-out card exist; the macOS Great Hall and the honesty-gate plumbing do not.

## B1. The metaphor (unchanged) + what actually exists

House = an `AgentProvider` runtime (crest+color+emblem); Worker = a spawned exec in its own pane+worktree; Fan-out = the Castle waking; Wand = the policy (shown, with honest demotion). "House of …" in chrome, neutral ids in plumbing (`castleNaming` pref). **What exists:** the crest primitives `HolographicCrestAura`/`HoloSheenSweep`/`HoloSparksOverlay`/`holoStops` (in `OpenBurnBarMobile/Views/Components/Pro/FeatureUnlockExperience.swift`) + `CloudTierCard`/`TierCrestEmblem` (`…/Store/CloudTierComponents.swift`) — **iOS-only but pure SwiftUI, confirmed hoistable to Core**; the iOS `MissionFanOutGroupCard` (`OpenBurnBarCore/.../Views/MissionControl/MissionFanOutGroup.swift`, instantiated only on iOS, fed by Firestore); `SwarmCanvasView`/`SwarmColorDriver`; `AgentProvider.bundledLogoName`(:282)/`iconName`(:318). **What does NOT exist:** a macOS Great Hall view in AgentLens; any Python→Swift channel for the `HEAD!=BASE` gate.

## B2. Three concrete macOS build items (v2)

1. **Hoist the crest primitives** (`HolographicCrestAura`, `HoloSheenSweep`, `HoloSparksOverlay`, `TierCrestEmblem`, `holoStops`) from `OpenBurnBarMobile` into a shared **`OpenBurnBarCore`** location (pure SwiftUI, verified macOS-compatible) so both platforms use one source. Build `HouseCrest` from them.
2. **Fix the layering inversion.** `House` is a **data-only** value type in Core (`provider`, `name`, `crestAsset = provider.bundledLogoName`, `sigil = provider.iconName`); **color resolution lives in the View layer** — the crest View in AgentLens uses `DesignSystem.Colors.primary(for:)/accent(for:)` (AgentLens-only). Add the minimal tokens Core needs (or hoist `primary(for:)`/`accent(for:)` + `LLMModelBrand.emblemColor` + a `Color.lightened(_:)` helper into Core). The two-band model wax-seal needs `emblemColor` in Core.
3. **Build the macOS Great Hall in AgentLens** — port/adapt the iOS `MissionFanOutGroupCard` into a macOS view (it is iOS-instantiated today), wired to the **Castle bridge** (B3), not the Firestore mobile mission lifecycle.

## B3. The honesty bridge (v2 — the load-bearing new plumbing)

The whole point is that **green/the "ting"/the "3 of 4 landed" tally are driven ONLY by the real `HEAD!=BASE_SHA ∧ is_error==false ∧ .done exists` gate** — which lives in Python (`ministry.py`/`castle.py`), with no path to Swift today. Build a **Castle status channel:** the runbook/`castle.py` writes a per-worker status record (runtime, model, House, Phase, `landsCommit` verdict, sha) to a surface the macOS UI reads — the simplest being the **`result.json`/`.done` sentinels the runbook already writes per worker**, tailed by a small `CastleStatusReader` in AgentLens that emits `CastleMoment`s. The macOS tile's `.completed`/green is bound to **that** verdict, never to a decoupled mission lifecycle. (A test pins it: a no-op'd worker — `.done` present, `HEAD==BASE` — never resolves to green.)

## B4. Choreography + honesty + manifesto (unchanged from v1, now bound to B3)

Six gated `CastleMoment`s (fan-out wakes / House lights / **banner raised** on commit-land / failing-dimmed-not-scolded / completing / demotion), each fired once per `Phase` edge (Hermes-throttle law), reusing the hoisted primitives + Swarm. Honesty states: **quota-unknown = dashed ring**, **route-demoted = down-chevron pennant**, **no-op'd = banner raised but blank** (counts as not-landed), **quota-pressure = the House visibly tires**. The 7-rule taste manifesto stands (dress-don't-rebuild; one earned glint per state change; honesty outranks delight — never fake-green; one loop per House; color = identity+truth; failure dimmed not scolded; every joy degrades to a calm truth).

---

## v1 scope · tasks · tests · risks

**IN:** `castle.py` (`RuntimeAdapter` + `REGISTRY`); `DroidAdapter` (extraction + `runtime` stamp); adapters for the 7 proven new Houses; `worktree_isolation` (MCP + `.git/info/exclude` scratch); commit hygiene (scoped add); `allowRuntimes`/runtime-dedup/catalog-canonicalization+fallbacks/`runtime_pref_tier`; `castle_*` tools; the mandatory per-`(runtime,model)` smoke gate; registry fixes (gemini/kimi/pi enum, cursor auth). **B:** hoist crest primitives to Core; `House` data type (Core) + crest View (AgentLens, colors resolved there); the **Castle status bridge** (B3); the macOS Great Hall; `CastleMoment` + honesty states + the green-only-on-real-commit test.

**OUT/deferred:** forge (flaky — only behind a passing probe + reliability gate); agy/antigravity (undrivable — revisit); grok/goose/continue (absent); numeric-quota daemon endpoint (Ministry deferred).

**Ordered tasks:** 1) `DroidAdapter` by extraction + `runtime` stamp; prove the 12+62 tests stay green. 2) Wire the registry through the `probe_runner` seam; `allowRuntimes` (membership-OR-missing). 3) **Commit hygiene + `worktree_isolation`** (scoped add, `.git/info/exclude`) — close the `.serena/` blocker first since it affects every adapter. 4) Catalog canonicalization + rank backfill + the direct-CLI-provider join test. 5) Runtime-aware dedup. 6) Codex + Claude adapters (config.toml parse; full-id resolve; the gotchas). 7) Gemini/opencode/cursor-agent/kimi/pi adapters (gemini parse keys on stdout-empty/exit≠0). 8) `castle_*` tools + auth-precondition fail-fast. 9) Hoist crest primitives to Core; `House` + crest View; fix the layering. 10) **Castle status bridge** (B3) + macOS Great Hall + `CastleMoment` + honesty states. 11) **Verification:** a live N=3 fan-out across ≥3 Houses (codex + claude + gemini at flagship), asserting each lands a commit *through the selector* (not bare `-m`), the committed trees are clean (no `.serena/`), and the UI tally is driven by the real gate.

**Tests:** DroidAdapter byte-identical (12+62 green) with `runtime` stamped; `allowRuntimes` drops nothing for legacy candidates; runtime-aware dedup keeps `(runtime,model)` identity; catalog join ranks `opus`→110 and a `google` flagship via fallback (not 0); **commit-hygiene: a `.serena/`-polluted worktree commits only intended files**; gemini parse fails on empty-stdout/exit≠0; the **UI no-op test** (HEAD==BASE never green); per-adapter `parse_completion` fixtures.

**Risks (verified):** C1 advertised≠drivable → mandatory probe. C2 worker leaks prod-mem0 → `worktree_isolation`. **C3 worktree pollution (.serena/) → scoped add + exclude (the gate does NOT catch it).** C4 catalog rank 0 hides flagships → canonicalize + backfill. C5 dedup collapses (runtime,model) → runtime-keyed dedup. C6 macOS UI honesty decoupled from the real gate → the Castle status bridge. C7 codex tier-gated models → smoke gate + fallback.

## Honest confidence

**Verified-real foundations:** the `probe_runner` seam, every cited `ministry.py` function, the `BACKENDS`→`allowRuntimes` pattern, the 8-case launch enum, the cursor auth bug — all confirmed in the *shipped* code. **8 Houses land commits headless**, and the **capability ceiling is genuinely resolved** (Opus 4.8/110, GPT-5.5/90, Gemini-3.1-pro flagship all landed commits via their own CLIs) — Pillar A is a well-bounded generalization, not a leap, and the v2 fixes (commit hygiene, runtime stamping, catalog canonicalization, dedup) are each one-to-a-few lines with a precedent in the repo.

**The honest residual is Pillar B's macOS reality (`needs-implementation-to-prove`):** the Great Hall view and the **Python→Swift honesty bridge** do not exist yet — that's real engineering (a new AgentLens view + a status channel from the Python gate), not "assemble." v2 states this plainly and scopes it as task 10 with the no-op green-gate test as its acceptance criterion. Build Pillar A adapter-by-adapter behind the smoke gate (DroidAdapter-by-extraction first, then commit-hygiene, then Codex+Claude), and build Pillar B as a real macOS surface bound to the real gate — with the live N=3 multi-House flagship fan-out as the acceptance gate for the whole Castle.

*Builds on `docs/THE_MINISTRY.md` (shipped). Evidence: 11-CLI smoke matrix + design-system inventory + one adversarial hunt (18 findings), this session.*
