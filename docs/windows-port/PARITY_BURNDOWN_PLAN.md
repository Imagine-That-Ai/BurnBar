# Windows Port — Full-Parity Burn-Down: Comprehensive Parallel Execution Plan
_2026-07-04 · grounded in the physical-Windows validation + a fresh `main` ground-truth sweep._

Companion to `FINAL_STATUS_AND_VALIDATION_RUNBOOK.md` and `HANDOFF.md` (both superseded where they differ — this is newest and authoritative for what remains).

---

## TL;DR (plain English)

- **The app now builds, runs, and renders on real Windows** (proven on your Intel PC, landed on `main` as #1248). The scary "does it even run" question is answered **yes**. The remaining work is *execution*, not discovery.
- What's left is **five workstreams**: **(A) Green** the base so regressions can't merge, **(B) Drive** — replace placeholder data/feeds with real backends *(the big one — this is what makes it stop showing demo data)*, **(C) Engine parity** — finish lifting parsers/quota (it's 4/16 today), **(D) Windows fidelity** — validate GPU/render/computer-use on real Windows, **(E) Ship** — signing cert + store.
- **The single load-bearing decision** is in (B): the Windows app has stub data because it has **no real backend wired yet** (no Windows daemon; the Swift Engine isn't hosted in-process). One coherent architecture decision must land **first** (a design lane), *then* the data-wiring lanes fan out in parallel. Everything downstream depends on it.
- **I own ~80% headless** (A, B, C, most of D-authoring, E-authoring) via parallel worktree-isolated agent streams → adversarial verify → consolidate → merge. **You own 3 things:** a **Win11 *Pro*** box/VM (validates D + unblocks TPM — Home can't), the **W0 signing cert** (ships E), and flipping **CI to a required gate** (one repo setting).
- **Honest shape:** ~6–10 more verified agent-waves + your merges + one Win11-Pro validation pass + the cert lead-time. Weeks, not months — and the risk is low because every kill-risk is already retired on real hardware.

---

## 0. Ground truth (2026-07-04, freshly verified against `main`)

| Area | State | Evidence |
|---|---|---|
| **App builds + runs on Windows** | ✅ **YES** (as of #1248 on `main`) | Physical Intel PC: `dotnet build x64` succeeds; app launches + renders (5 surface screenshots); WindowsAppSDK 1.8; `mc:Ignorable` fixed. |
| **C# test suites on real Windows** | ✅ **2,540/2,545**; the 5 fixed in **#1249** (ready, unmerged) → **2,545/2,545** | Real Windows run; #1249 = `.gitattributes` CRLF fix + hardening test split, 94/94+95/95 green on macOS. |
| **Mac-encrypted DB opens on Windows** | ✅ **14/14** | `windows/storage` real run. |
| **Engine (Swift) on Windows CI** | ✅ compiles + walking skeleton + parser-path parity green (x64 **and** ARM64) | CI run 28701335549. |
| **G2 parser byte-parity** | ⚠️ **4 of 16 parsers** lifted (ClaudeCode/FactoryDroid/Codex/Hermes = 15/15 golden). 12 parsers + 20 quota adapters still app-only. Cloud E2EE = vector-match, not live. CI lane **advisory**, not required. | G2 adversarial gate verdict = **FIX**. |
| **Runtime data** | ⚠️ **placeholder/in-memory** — `StubCliStream` (canned CLI feed), `SurfacePageResolver` stub fallback, `BudgetRuleStore`/`InMemoryElderWandPersistence`/`SwitcherProfileStore`+`SwitcherSampleData`/`HomeAssistantTokenStore` (non-persistent), `MissionDispatchDemoHost` (demo data). **No real backend wired.** | fresh grep of `windows/app`, `windows/integrations`, `windows/cloudsync`. |
| **App↔engine/daemon backend** | ❌ **not wired** — no Windows daemon binary; Swift Engine not hosted in-process; `NamedPipeDaemonApprovalChannel` exists in `windows/computeruse` but the app consumes no real daemon. | grep: 0 app-side daemon/pipe consumers. |
| **Windows-runtime fidelity** | ⚠️ authored, **not validated on Windows**: Win2D 60fps/ARM64, Pretext WebView2 metric-parity, ViGEm/SendInput/UIA/WGC/overlay, DPI/UIA a11y. | never run on a GPU/desktop. |
| **TPM (R14)** | ❌ **blocked by SKU** — Win11 **Home** lacks the Platform Crypto Provider (`NCryptCreateClaim` → 0x80090027 / provider not found). Needs Win11 **Pro**. Not a code bug. | physical PC: fTPM present but provider unregistered. |
| **Distribution** | ⚠️ authored (MSIX/winget/Choco/update-feed/signing/SBOM); real build+sign needs the **W0 cert** + a Windows runner. | #1240-1243. |
| **G2–G5 adversarial gates** | ❌ not formally run (per-wave verifiers ≠ pre-registered G-gate red-team). | — |

---

## 1. The five workstreams + dependency graph

```
WS-A  Green + gate the base ─────────────┐  (unblocks safe parallel merging)
                                          ▼
WS-B  DRIVE (real backends)  B0 design ─► B1..B6 fan-out ─┐
WS-C  Engine parity (G2 real) ───────────────────────────┼─► WS-D validate on Win11 ─► WS-E ship
                                          (parallel)      │        (needs Win11 Pro)   (needs W0 cert)
                                                          ▼
                                              Gates G2 → G3 → G4 → G5 (each after its evidence exists)
```

- **WS-A** is the prerequisite for everyone (a required-green CI gate so parallel streams can't regress each other silently).
- **WS-B0** (the app↔engine architecture) is a **hard serialization point** — it must be decided + landed before B1–B6 fan out (per the "one coherent design decision first" rule). WS-C can run fully in parallel with WS-B.
- **WS-D/WS-E** are validation/shipping — gated on the Windows environment (you) and the cert (you).

---

## 2. Execution model — how the parallelism actually runs

The proven loop (used for all 8 prior waves): **worktree-isolated agent streams → independent adversarial verifier per stream → orchestrator consolidates into one integration branch → admin-merge to `main`.** Rules, per the parallelism standard:

- **Isolation:** every implementation stream gets its own git worktree; no two streams edit the same file in the same wave. File ownership is declared per stream below.
- **Verify-not-trust:** every stream is independently rebuilt/tested by a second agent that tries to *refute* it. Nothing lands on a claim.
- **macOS ceiling honesty:** portable logic (C#/Swift) is real-`dotnet test`/`swift test`-verified on macOS; anything past the Windows-only XamlCompiler / GPU / native-API line is authored + flagged and **verified by Windows CI or the Win11 box** — never asserted green from a Mac.
- **Integration discipline:** the orchestrator reconciles overlaps (esp. `.sln`, `OpenBurnBar.App.csproj`, `SurfacePageResolver`, area-registration files), de-dupes, runs the repo gates (`check-windows-tree-budget.sh`, actionlint, the full dotnet suite), and only then merges. No concatenation of raw agent output.
- **Coupling caps parallel width:** high-churn shared files (the `.sln`, the app csproj, the nav resolver) are touched by **one** stream per wave; everything else fans out.

---

## 3. Detailed workstreams

Each stream below follows: **Mission · Owns · Non-goals · Approach · Verification · Size · Owner · Parallel-safe-with.**

### WS-A — Green + gate the base
> Make it impossible to merge a Windows regression, and clear the pre-existing reds.

- **A1 — Land #1249** (5 test fixes → 2,545/2,545). *Owner: me (merge). Size: S. Done-when: merged.*
- **A2 — Make the Windows lanes REQUIRED status checks.** `openburnbar-engine-windows.yml` + a new full-suite Windows dotnet job become **required** in branch protection so red can't merge. *Owns: `.github/workflows/*windows*`, branch-protection settings. Non-goals: don't touch macOS gates. Verify: actionlint + a deliberately-red PR is blocked. Owner: me (workflow) + **Alberto** (branch-protection toggle). Size: S.*
- **A3 — Full-suite Windows CI** (all ~2,545 tests on `windows-latest` **and** `windows-11-arm`, + the WinUI app `dotnet build` to full XamlCompiler completion — now that it builds). *Owns: a new `pr-windows-full.yml`. Verify: green on `main`. Size: M.*
- **A4 — Green pre-existing `main` reds** (debt budgets / GRDB-SPM cache / clippy toolchain — they fail on clean `main`, unrelated to the port). Either fix them or document the admin-merge path so CI-required doesn't deadlock the port. *Owner: me (diagnose) + Alberto (repo-maintenance call). Size: M.*

**Parallel:** A2/A3/A4 independent; A1 first.

### WS-B — Make it DRIVE (real backends replacing stubs) — the biggest parity chunk

#### B0 — Architecture decision + spike (SERIALIZED — must land first)
> The Windows app shows demo data because nothing real is behind it. Decide, spike, and freeze the app↔engine/data contract before wiring anything.
- **Mission:** choose + prove the Windows data/runtime backend. **Options:** (1) **host the Swift Engine in-process** in the WinUI app via a C-ABI/UniFFI bridge (reuses the *already-Windows-compilable* `OpenBurnBarCore`; no second process; SOTA-recommended) — the same pattern the Rust crates already use; (2) **port `OpenBurnBarDaemon`** to a Windows service + named-pipe (heavier; reuses the landed ConPTY/peer-auth harness); (3) **hybrid** (engine in-process for reads/parse; a thin broker for privileged/computer-use ops). 
- **Deliverable:** an ADR (`docs/windows-port/adr/0007-windows-app-backend.md`) + a walking spike proving one real end-to-end path (real CLI spawn → parse → real storage row → a live tile) through the chosen backend. 
- **Owns:** the ADR + a spike project. **Non-goals:** no broad rewiring yet. **Verify:** the spike runs (Windows CI / macOS-portable half). **Owner:** me (a Plan/architecture-review lane + an implementation spike). **Size:** L. **Blocks:** B1–B6.

#### B1–B6 (fan out AFTER B0 freezes the contract)
- **B1 — Real CLI feed.** Replace `StubCliStream`'s canned `Script[]` with a `ConPtyCliStream : ICliStream` that spawns the real agent CLI via the landed ConPTY harness and streams stdout as `CliStreamEvent`s (parsed through the Engine's `HermesOpenAICompatibleStreamParser`). *Owns: `windows/app/.../Cli/`, `windows/pal/ipc` consumption. Non-goals: don't touch other surfaces. Verify: a real `claude --output-format stream-json` spawn on Windows CI/box produces the golden event stream; unit-test the parse path on macOS. Size: M.*
- **B2 — Real persistence.** Replace the in-memory/sample stores (`BudgetRuleStore`, `InMemoryElderWandPersistence`, `SwitcherProfileStore` + `SwitcherSampleData`, `HomeAssistantTokenStore`) with SQLCipher-backed persistence via `windows/storage` (the byte-compatible store that already opens the Mac DB). *Owns: the Presentation-layer stores + `windows/storage` read/write API. Non-goals: don't change the Mac schema. Verify: real `dotnet test` round-trips (write→reopen→read) on the committed encrypted fixture; schema-hash stable. Size: M–L.*
- **B3 — App↔engine wiring (consumes B0).** Wire the real surfaces (Dashboard tiles, SessionLogs, Memory, Insights data) to the B0 backend instead of placeholder providers. *Owns: the app data-provider layer. Verify: each surface renders real data from a seeded store/engine. Size: L.*
- **B4 — Live cloud.** Wire the landed `windows/cloudsync` (Firestore REST gateway + CloudVault + App Check client) to real: desktop-OAuth → Firestore read/write; App Check token attach; CloudVault live cross-platform round-trip. *Owns: `windows/cloudsync` app consumption + an OAuth desktop flow. Non-goals: don't weaken E2EE/fail-closed. Verify: against the real `burnbar` Firebase project (needs creds — dev-host/CI-secret). Size: L.*
- **B5 — Remaining stub nav pages.** Enumerate every `SurfacePageResolver` fall-through to `SurfaceStubPage`; wire the real page for each (or confirm it's genuinely out-of-scope, e.g. a W5/W8/W9 surface). *Owns: `windows/app/.../Shell/SurfacePageResolver` + the specific surfaces. Verify: 0 in-scope destinations resolve to the stub; app build green. Size: S–M.*
- **B6 — Mission Control real dispatch.** Replace `MissionDispatchDemoHost` with real Firestore-backed mission dispatch (behind the existing `IMissionDispatchHost`). *Owns: `windows/app/.../MissionControl`. Verify: dispatch round-trips against the fake gateway + a live smoke. Size: M.*

**Parallel:** B1/B2/B5/B6 are file-disjoint and fan out together once B0 lands; B3/B4 follow B0+B2.

### WS-C — Finish engine parity (make G2 real) — fully parallel with WS-B
- **C1 — Lift the remaining 12 parsers** into the Engine (Antigravity/Augment/CursorAgent/GeminiCLI/Grok/Kimi = CLEAN; ForgeDev/Goose/Windsurf/Warp + the UsageAggregator set = SEAM via the **already-landed** SQLite reader + crypto shim). Extend the golden + harness to cover them. *Owns: `OpenBurnBarCore/.../Services/LogParser/` + `OpenBurnBarG2ParserParity`. Verify: harness byte-identical for all; `swift build` green; Windows CI runs it. Parallel: batch CLEAN vs SEAM. Size: L.*
- **C2 — Lift the 20 quota adapters** into the Engine + a **Windows quota value-match harness** (≥1 provider per each of the 4 mechanisms, values matched to the Mac golden — not just pacing math). *Owns: `OpenBurnBarCore/.../ProviderQuota` + a new harness. Size: L.*
- **C3 — Full wrap-vector corpus on Windows** (`llm-safe-wrap-vectors.json` via a `swift run`/CI step — not just the single skeleton probe). *Size: S.*
- **C4 — SQLite seam parity proof** — an explicit GRDB-write→seam-read divergence test (type coercion, NULL) + exercise Hermes's SQLite path (add a Hermes-SQLite fixture; today both Hermes goldens are JSON). *Owns: `OpenBurnBarCore/.../Services/SQLite` + fixtures. Size: M.*
- **C5 — Live cross-platform E2EE round-trip** (Windows-seal→Mac-open + reverse on the 2 hardest domains) **or** a formal, Alberto-signed deferral of the G2 cloud criterion to WS-D. *Owner: me (harness) + Alberto (deferral call). Size: M.*

### WS-D — Windows-runtime fidelity (authored headless; VALIDATED on Win11)
- **D1 — Particle engine fidelity** — 30 substrates @60fps on real Windows (x64 **and** ARM64); Win2D output vs macOS goldens (accepted-drift list). *Needs: Win11 box/VM (GPU). Authored: any gaps I fix headless.*
- **D2 — Pretext WebView2 metric-parity** — run the committed text corpus; heights/line-widths within tolerance vs the Mac golden (fixes Chat layout drift). *Needs: Windows box.*
- **D3 — Computer-use + pet real run** — ViGEm/SendInput/UIA/WGC/Win32 overlay; kill-switch halts within bound; capability-token gate; click-through passthrough. *Needs: Windows box; preserve the security invariants.*
- **D4 — DPI + keyboard + UIA/Narrator** accessibility passes across all surfaces (the G3 acceptance criteria). *Needs: Windows box.*
- **Owner:** me authors fixes for anything the box surfaces; **you** run the Win11 validation (the runbook step 4-5). **Feeds:** G3/G4 gates.

### WS-E — Ship (procurement + signed distribution + certification)
- **E1 — W0 procurement (Alberto, calendar-bound):** Authenticode/Azure-Trusted-Signing cert + Microsoft Store publisher + winget publisher. **External lead-times — start now; gates E2/E3.**
- **E2 — Real signed build:** MSIX (`OpenBurnBar.Packaging.wapproj`) + portable zip + Choco, Authenticode-signed via the E1 cert on a Windows runner; the Ed25519-pinned update-feed sign→verify round-trip end to end. *Owner: me (workflow) + the cert. Size: M.*
- **E3 — Parity certification (W11):** the full parity-matrix + launch-evidence bundle (every surface/flow: screenshot + test + the accepted-drift list), the G5 gate. *Size: M.*

### The gates (adversarial G2–G5)
Run each as an independent red-team **after its evidence exists**: **G2** after WS-C (+ WS-A required-CI), **G3** after WS-D visual, **G4** after WS-D computer-use, **G5** after WS-E. Each returns GO/FIX/PIVOT with a criteria table; FIX items feed the next wave.

---

## 4. Division of labor + critical path

| Owner | Workstreams |
|---|---|
| **Me — headless (macOS + Windows CI)** | A1/A3/A4, **all of B** (design + implementation + verify + consolidate + merge), **all of C**, D-authoring, E2/E3-authoring, all G-gates |
| **Windows CI (free, x64+ARM64)** | validates A3, C1–C4, the app build; the required gate |
| **You — Win11 *Pro* box/VM** | WS-D validation (GPU/render/computer-use/DPI) + **R14 TPM** (Home can't) |
| **You — Alberto** | A2 (flip CI to required), C5/deferral call, **E1 cert/Store/winget**, the periodic merges |

**Critical path:** A1 → **B0 (architecture, serialized)** → B1–B6 ∥ C1–C5 → land + green → **WS-D on Win11 Pro** → G2/G3/G4 → **E1 cert** → E2 signed build → G5 → ship.

---

## 5. Honest sizing

- **A:** 2–3 PRs. **B0:** 1 design + 1 spike PR (the pivotal one). **B1–B6:** ~6–10 PRs. **C1–C5:** ~6–10 PRs. **D:** authoring PRs as the box surfaces issues + 1 validation pass. **E:** 2–3 PRs + the cert lead-time.
- **≈ 6–10 more verified agent-waves**, each consolidated + admin-merged, plus **one Win11-Pro validation pass** and **the cert procurement** (the long human lead-time). Wall-clock is gated by merge throughput + the Windows-env pass, not by unknowns.

## 6. Top risks + mitigations

1. **B0 architecture is the real unknown** → treat as a serialized design+spike lane; do NOT fan out B1–B6 until the contract is frozen (the one place parallelism would cause drift).
2. **Shared-file churn** (`.sln`, app csproj, `SurfacePageResolver`, area-registration) → one owner per wave; orchestrator reconciles at integration (proven across 8 waves).
3. **Merge/CI-green gate** (pre-existing `main` reds + admin-bypass friction) → WS-A A2/A4 make green real + required; the admin-merge path is documented.
4. **Windows-only fidelity (GPU/metrics/TPM) can't be Mac-verified** → authored + flagged; validated on the Win11-Pro pass; never claimed green from macOS.
5. **TPM SKU gate** → the Win11 box/VM MUST be **Pro** (Home lacks the provider). Called out in every TPM task.
6. **Cloud creds** (B4/C5 live round-trips) → need the `burnbar` Firebase project secrets in CI/dev-host; until then, vector-parity + a documented deferral.

---

_Execution starts at WS-A1 (land #1249) → WS-B0 (the architecture decision). Everything else fans out from there under the parallelism + integration discipline in §2._
