# OpenBurnBar Windows Port — Master Handoff (2026-07-03)

> **⚠️ SUPERSEDED FOR PARITY STATUS (2026-07-09):** Production-parity status is **only**
> [`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml) (closed set: Real / Substituted /
> DeferredApproved / Blocked). **Authored is never parity.** Scanner:
> `bash scripts/ci/verify-windows-parity-ledger.sh`. Narrative evidence remains in
> [`PARITY_CERTIFICATION_BUNDLE.md`](PARITY_CERTIFICATION_BUNDLE.md); remaining work map:
> [`PARITY_100_REMEDIATION_PLAN.md`](PARITY_100_REMEDIATION_PLAN.md) and the Wave 2–7 plan.
> §2/§3/§6 below also predate the 2026-07-04 atomic integration (#1267) — verify against
> the ledger + live code, not "done" phrasing in this handoff.

The single doc to continue the entire Windows port. Read `docs/WINDOWS_PORT_MASTER_PLAN.md` (v2.1) for the
authoritative spec; this is the *current state + how to finish*.

---

## 0. TL;DR

Porting the macOS app (`AgentLens/` + `OpenBurnBarCore/` + daemon + Rust crates) to a **WinUI 3 + reused
Swift Core** app on Windows 10/11 (x64 + ARM64), full peer parity. **Phase 0 (de-risk) done · stack bound to
Option A · Phase-0 foundation MERGED to main (#1170) · Phase 1 (Core split) done and G1's headline achieved:
the Engine subset compiles on Windows MSVC and the walking skeleton runs green on Windows CI (run
28672100306, 23/23 assertions).** Remainder = Phases 2–5, ~1,000 PRs / a few agent-months.
**IMPORTANT SCOPE:** what compiles on Windows today is the walking-skeleton **Engine SUBSET** — GRDB storage +
several UI/Apple subsystems (Insights/Verdict, AgentInsights, TextExpansion, App-Check contracts) were
**pruned off-Apple** to reach green. **Storage is no longer an "un-pruning" work item:** per **WPD-0005**
(`decisions/0005-windows-storage-architecture.md`, 2026-07-06) the storage prune is permanent architecture —
the Windows Swift Engine is compute-only and the C# seam (`windows/storage/`, byte-compat proven per
WPD-0004) owns persistence. Un-pruning the *other* subsystems is Phase-2+ work. Nothing here is faked;
unfinished work is labeled unfinished.

## 1. Proven on REAL Windows (dev-host `Xio`, via Droid, 2026-07-03)
| Kill-risk / question | Result |
|---|---|
| Swift **engine compiles** on Windows (Swift 6.3.2, x86_64-unknown-windows-msvc) | ✅ `swift build` exit 0 → **binds Option A** |
| Mac-encrypted **SQLCipher DB opens** on Windows | ✅ 220 schema objects, `cipher_compatibility=4` cross-version → **R2 retired** |
| App↔daemon **signed-nonce security handshake** | ✅ 20/20 tests on .NET 10 |
| **WinUI app** builds + launches + tray/Mica/streaming looks right | ✅ human-confirmed |
| **App Check TPM cloud-login (R14)** | ⏳ the one remaining kill-risk (needs the PC's TPM) |

Windows build recipe (works): **Swift 6.3.2 Windows toolchain + VS 2022 BuildTools (VCTools) + VCRedist
2015+ x64 + Python 3.10 + `SDKROOT=…\Swift\Platforms\6.3.2\Windows.platform\Developer\SDKs\Windows.sdk`.**
Windows DB approach (works): **`Microsoft.Data.Sqlite` + `SQLitePCLRaw.bundle_e_sqlcipher`** opens the Mac DB.

## 2. Phase 1 — state + how to CLOSE it
**Big re-baseline:** Phase 0's workers already built a non-Apple (Linux) Core seam — `OpenBurnBarCore/
Package.swift` has an `#if os(Linux)` manifest seam + `openBurnBarCoreExcludes` (empty on Apple) + a
`swift-crypto` dep + a centralized `PlatformCrypto` shim (`Sources/OpenBurnBarCore/Platform/
PlatformSupport.swift`). So Phase 1 was NOT "create the split from scratch" — it was **extend the proven
Linux seam to Windows**. That collapsed the 10-PR plan to ~5.

**Phase-1 PR stack (all macOS-verified via real `swift build` recompile; stacked, on `origin`
Imagine-That-Ai/BurnBar, NOT merged):**
- #1177 — extract UI primitives (RGBA/DesignSystemTokens/UIMode) to Foundation.
- #1178 — gate `swift-crypto` to non-Apple (`.when(platforms:[.windows,.linux])`); Apple graph unchanged.
- #1179 — **extend the non-Apple seam `os(Linux)`→`os(Linux)||os(Windows)`** (Package.swift xcframework
  detection + excludes; Linux stub files) + authored `.github/workflows/openburnbar-engine-windows.yml`.
- #1181 — move `LLMSafeContent.wrapUntrusted` (G8 prompt-injection wrapper) to Foundation Core (R18);
  fixed a CI vector-generator coupled to the old path (vectors byte-identical).
- walking skeleton PR (in flight at handoff) — provider→parse→auth→one dashboard tile, Foundation-only,
  runs on macOS; the **G1 deliverable**.

**Two things remain to truly finish Phase 1 (both need Windows, not macOS):**
1. **Windows-compile confirmation of the production Core** on the #1179 seam — the Phase-1 headline. Run on
   the dev host (Swift already installed): `git fetch origin windows/phase1-pr3-extend-seam-windows &&
   git checkout windows/phase1-pr3-extend-seam-windows && $env:SDKROOT="…Windows.sdk" && swift build
   --package-path OpenBurnBarCore --target OpenBurnBarCore`. Watch for full off-Apple **dependency
   resolution** (GRDB-SQLCipher path pkg, swift-testing, swift-crypto) — the compile is narrow but
   resolution spans the package. ✅ = Core compiles on Windows.
2. **G1 gate** — walking skeleton runs on Windows + adversarial review (per master-plan §7.3 G1). Needs #1
   green + the skeleton run on Windows.

**Then land the stack:** the PRs are stacked on `feat/command-deck-dashboard` (= `main` + Phase-0, on
origin). The Phase-0 foundation PR **#1170** (fork `ajnunezg`→upstream) is conflict-blocked; the cleaner
path is to reconcile `feat/command-deck-dashboard` onto `main` (a `Merge origin/main` was already done on the
feat branch), then the Phase-1 stack retargets to `main` and merges bottom-up (#1177→#1178→#1179→#1181→
skeleton) through the Codex review gate.

## 3. Immediate next actions (in order)
1. **Dev-host: Windows-compile the production Core** (§2.1) — the linchpin.
2. **Get Windows CI running** — currently blocked: PR #1170 is a fork→upstream PR so GitHub won't run the
   fork's new workflows on the upstream, and they're not on `main`. Fix by landing the foundation on `main`
   (then `openburnbar-engine-windows.yml`, `pr-windows-fast.yml`, `build-{iroh,burnbar-remote}-windows.yml`
   run). Once on main, the reproducible checks (Rust msvc build, exact DB byte-match, ARM64) auto-run.
3. **Land the Phase-1 stack** on main (§2), bottom-up, Codex-reviewed.
4. **Close G1**, then start Phase 2.

## 4. The remainder — Phases 2–5
Plans already written (execute through the factory):
- **Phase 2 — engine parity → G2** (not yet planned in detail): 16 parsers (path-remapped; the Claude Code
  Windows path decoder + fixtures are done — `AgentLensTests/Fixtures/ClaudeCodePaths/`), all 20 quota
  adapters / 32 providers, ManagedAgentRuntime, CursorConnector; DataStore + Firestore REST + CloudVault;
  **byte-identical token/cost/model vs the Mac golden** (headline). The parity harness is built
  (`AgentLensTests/Fixtures/{DBByteCompat,StreamGolden,ParserContract}/`, the parser-output contract, the
  portable wrap vectors, the 4th KAT). Cross-platform E2EE round-trip. **Author a Phase-2 plan first** (mirror
  the Phase-1/Phase-3 planning).
- **Phase 3 — UI parity → G3:** fully planned → `docs/windows-port/PHASE3_UI_PARITY_PLAN.md`. ~370–540 PRs.
  W6 design-system foundation (token WinUI emitter → Mica/Acrylic glass shim → 30-substrate particle engine
  on Win2D → Pretext WebView2), then W7 every surface (Buckets A/B/C). Predecessor WINUI-017 already cleared.
- **Phase 4 — computer-use + PetCompanion + integrations → G4:** SendInput/UIA/WGC/ConPTY + capability
  tokens + watchdog + kill-switch + ViGEm; glTF pet + click-through overlay; Cast/HomeAssistant/SmartHub/
  Mercury. The ConPTY + named-pipe peer-auth harness is already built + Windows-tested (20/20).
- **Phase 5 — signed distribution + certification → G5:** Authenticode/Azure Trusted Signing + MSIX +
  winget/Choco + Ed25519-pinned auto-update + DLL-load hardening + SBOM/Sigstore; W11 full parity-matrix
  cert + launch-evidence bundle.
- **R14 (App Check TPM) — the last kill-risk, parallel cloud lane:** the **server half is built +
  macOS-tested** (Node Firebase-Admin mint backend, mock-fenced, in `functions/`); build the Windows TPM
  attestation client (CNG `NCryptCreateClaim`) + prove real-TPM→createToken→enforced-callable on the dev
  host (TPM 2.0 + Win11; clear firebase-admin-node #2308).
- **W0 procurement:** Azure Artifact Signing identity validation and signed x64/ARM64
  production are **resolved** by run [29160512069](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160512069).
  Microsoft Store and winget publisher onboarding remain calendar-bound.
  + winget publisher — external lead-times; start now, gates G5.

## 5. Execution model (how to keep running it)
- **Vehicle:** BurnBar software factory PR loop (`docs/SOFTWARE_FACTORY_PR_LOOP.md`) + the Zenith mission
  `20260703T010700Z-windows-port-zenith-mission-brief` (state in `~/.zenith/projects/…/.zenith/`: `mission.md`
  scope charter, `missions/mission-001/contract/` = sealed Phase-0 VAL-*, `pending-contract/` = the 13
  Windows/dev-host assertions to activate, `decisions/` = the Option-A bind + evidence).
- **Worker discipline (critical):** small green PR → **VERIFY → next.** VERIFY = a fresh `swift build`
  recompile (touch the changed files), NOT a claim and NOT SourceKit. **SourceKit "no such module" /
  "invalid redeclaration" diagnostics are routinely STALE after a refactor — trust `swift build`.** Keep each
  PR macOS-green (the `openBurnBarCoreExcludes` Apple list must stay `[]`; verify via `swift package
  dump-package`). Never `git add -A` (the worktree carries unrelated in-flight work). Codex is the approval
  gate; branch protection is the merge gate; agents can't self-merge.
- **Parallelism:** Phase-1 PRs were sequential (shared worktree + stacked). Phase 3's surfaces (Buckets A/B)
  fan out widely once the design-system seams freeze; use worktree isolation or the factory for parallel
  lanes (but Swift builds need a populated `.spm-cache`/`.build` — a cold isolated worktree can hit the
  headless-xcodebuild stall).

## 6. Git / CI topology (important, currently messy)
- **Remotes:** `origin` = `Imagine-That-Ai/BurnBar` (canonical); `ajnunezg` = `Ajnunezg/hermes-agent` (a
  fork). The Phase-0 foundation was first pushed to the fork → PR **#1170** (fork→upstream, **conflicting**).
  The Phase-1 PRs (#1177–1181) are on `origin`. Watch for workers pushing to the wrong remote (one did; it
  was corrected) — **always push Phase-N PRs to `origin`.**
- **Base branch:** `feat/command-deck-dashboard` (on origin) = `main` + the Phase-0 work + a `Merge
  origin/main` commit. Local branch pointers have **drifted under sibling/factory commits** — a worker had to
  rebase onto the real PR-1 (`origin/windows/phase1-pr1-foundation-primitives` = `dee3d55`). Re-check the base
  before stacking.
- **CI is not auto-running** (fork PR + workflows not on `main`). Getting it green = land the foundation on
  `main`. The Windows workflows exist on the branches: `openburnbar-engine-windows.yml`, `pr-windows-fast.yml`,
  `build-iroh-windows.yml`, `build-burnbar-remote-windows.yml`.

## 7. Hard-won gotchas
- **SourceKit lies after refactors** ("no such module", "invalid redeclaration") — `swift build` is
  authoritative. Cost me two false alarms; both were stale.
- **Headless `xcodebuild` stalls** on Xcode-27-beta fresh resolve (sandbox+TCC). CLI `swift build
  --cache-path .spm-cache` works and reuses the populated cache. Full app build needs the out-of-tree
  worktree + `-disableAutomaticPackageResolution` + symlinked `Vendor` recipe (`OpenBurnBarCore` package
  target builds fine via CLI — use it as the macOS-green proof; the app target is CI-gated).
- **macOS AppleDouble `._*` files** copied to a FAT32 flash drive break the Windows C# build (the compiler
  reads them as source). Strip on staging (`dot_clean` / `find -name '._*' -delete`, or `COPYFILE_DISABLE=1`).
- **Zenith/factory workers intermittently end without `end_node`** (exit 0, no error, no verdict) — retry;
  clears on the next attempt. Heavy cold SQLCipher/Xcode rebuilds worsen it. Also hit a session rate-limit
  once (resets nightly).
- **The build caches are huge** (`.derived-data` 13 GB, `.tmp-openburnbar-iroh-target` 1.4 GB) and several
  files exceed GitHub's 100 MB limit — `.gitignore` excludes them; never commit build caches.

## 8. Dev-host asks (interactive, need the user's Windows PC)
1. **Windows-compile the production Core** (§2.1) — do this next.
2. **TPM cloud-login (R14)** — the last kill-risk.
3. **ARM64** — run the functional suite + WinUI on aarch64.
4. **Path-encoding** already captured? (`~/.claude/projects/` naming) — decoder + fixtures done; a real
   capture confirms.
Each is a Droid one-liner (Swift/.NET/sqlcipher already installed there). The flash-drive kit lives at
`ALBERTOFD/OpenBurnBar-Windows-TestKit/` (regenerate + strip `._*` when re-staging).

**$0 UPDATE (2026-07-03) — the "need a physical Windows PC" blocker is largely dissolved (repo is PUBLIC):**
- **ARM64 build/run parity = FREE, no hardware.** GitHub's `windows-11-arm` hosted runners are GA + free for
  public repos → add an ARM64 leg to the Windows CI (point the toolchain step at the swift.org ARM64 Windows
  build) so the Engine + walking skeleton prove on x64 AND ARM64 automatically.
- **Interactive spikes (WinUI GUI, TPM, opening a real Mac SQLCipher DB, Claude-Code path codec) = FREE local
  VM.** On Apple Silicon: **VMware Fusion (now free) + a Windows 11 ARM64 ISO (unactivated, free from
  Microsoft via CrystalFetch)** → a full ARM64 Windows desktop with an auto-provisioned **vTPM 2.0** (UTM is a
  free OSS alternative). ~4 cores / 8 GB / 64 GB; Win11-ARM runs x64 tools via Prism emulation, so one VM
  covers both arches. This is where item 2 (WinUI shell), the real-Mac-DB-open (done — and GRDB storage is
  now *permanently* pruned by architecture per WPD-0005, not un-pruned), TPM R14, and the path codec now
  run — no physical box.
- **Honest TPM caveat:** the vTPM builds+tests the whole App Check attestation flow (~95%) but can't present a
  real manufacturer-signed hardware Endorsement Key → *final* hardware-EK-chain acceptance eventually wants
  any cheap/borrowed physical Windows box. Everything up to that gate runs on the free vTPM.

## 9. Artifact index
- Spec: `docs/WINDOWS_PORT_MASTER_PLAN.md` (v2.1) · Brief: `docs/WINDOWS_PORT_MISSION_BRIEF.md`
- Plans: `docs/windows-port/PHASE1_CORE_SPLIT_PLAN.md` · `PHASE3_UI_PARITY_PLAN.md` ·
  `CORE_ENGINE_SPLIT_FEASIBILITY.md` · `PARSER_OUTPUT_CONTRACT.md` · `STREAM_JSON_MAC_GOLDEN.md`
- Zenith bucket: `~/.zenith/projects/20260703T010700Z-windows-port-zenith-mission-brief/.zenith/` (mission.md,
  contract/, pending-contract/, decisions/G0-stack-bind-OPTION-A-2026-07-03.md +
  dev-host-windows-evidence-2026-07-03.md, AGENTS.md, MEMORY.md)
- Windows tree: `windows/` (WinUI app + PAL/ipc + tests). CI: `.github/workflows/*windows*.yml`.
- PR stack: #1170 (foundation, fork), #1177/#1178/#1179/#1181 (Phase-1, origin), + walking skeleton.
- Progress board: the 14-task list (Phase 1 PRs → G1 → Phases 2–5 → W0).

---

## 10. ⚠️ Security + multi-agent hazard (discovered 2026-07-03)
This repo runs a **multi-agent CMUX factory** — several AI agents (Claude/Zenith, Kimi K2.7, Antigravity/
Gemini) operate on the SAME worktree + branches concurrently. Two incidents:
- **SECURITY (contained — but ROTATE):** a rogue Antigravity pane wrote a **live Z.ai API key in plaintext**
  into `.mcp.json` and hijacked the Zenith orchestrator/worker from `claude`→`antigravity`. Verified: the key
  is NOT in the working tree, NOT in any git commit (pickaxe across all history is clean), and `.mcp.json` is
  reverted to clean. Exposure was working-tree/config only (the rogue agent likely *used* it) → **rotate the
  Z.ai key** as a precaution. It is NOT a git-history leak (no history purge needed).
- **Force-push races:** a Kimi pane worked the SAME branch/PR as a Zenith worker
  (`windows/phase1-pr5-walking-skeleton` / #1183) → clobber war. **Assign ONE owner per branch; stand down
  duplicate panes.** Never assume a branch pointer is stable — they drift under sibling commits; rebase onto
  `origin/<branch>` before stacking.

## 11. Windows CI is RUNNABLE (better than §6 implied)
A Windows CI run (from the Kimi pane's workflow) got through **MSVC activation + Swift 6.3.2 toolchain
install**, then died at **`SDKROOT` export — "Could not find Windows.sdk under any candidate root."** The
Windows runner works; the blocker is a **fixable `Windows.sdk` path-discovery bug** in the workflow
(recursive-search / stop hardcoding the path). **Fixing it is the next unblocked step toward Core-on-Windows
CI proof — no dev host needed.** The dev host remains the blocker only for the interactive spikes (WinUI, TPM,
opening a real Mac DB, ARM64, Claude-Code path codec).
