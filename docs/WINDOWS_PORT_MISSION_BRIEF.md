# Windows Port — Zenith Mission Brief

**Purpose:** the entry-point brief for the Zenith long-running mission that executes the Windows port.
Pass this file's content as the `brief` to `start_project(brief, workspace_dir)`. The **authoritative
specification** is [`docs/WINDOWS_PORT_MASTER_PLAN.md`](WINDOWS_PORT_MASTER_PLAN.md) (v2.1) — read it first; this
brief only records the accepted scope + the decisions that were open in that plan and are now resolved.
Shared desktop substrate contracts live in [`DESKTOP_FOUNDATION.md`](DESKTOP_FOUNDATION.md); this brief inherits them and records only Windows-specific execution decisions.

**Created:** 2026-07-02 · **Workspace:** `/Users/albertonunez/Documents/Developer/BurnBar` (macOS)

---

## Intended outcome

Full **peer** parity of the macOS app (`AgentLens/`) on Windows 10/11 (x64 + ARM64): the local log-reading agent
engine, every UI surface, computer-use, the daemon, the pet, **full cloud sync**, and distribution — proven by a
parity-certification harness. Executed phase-by-phase (Phase 0→5) with an adversarial red-team gate (G0–G5) between
every phase, through the BurnBar software factory. Not a cloud-only companion (that is iOS/Android); Windows is a
local peer like the Mac.

## Actor / workflow

A Windows user running local AI coding-agent CLIs (Claude Code, Codex, Droid, etc.). The app ingests those CLIs'
on-disk session logs, aggregates usage/cost/quota, provides chat + computer-use + a menu-bar/tray surface, and syncs
E2EE to the cloud. Full capability inventory: master plan §10.1.

## Locked decisions (2026-07-02) — supersede the "open decisions" in master plan §15

1. **Engine stack = SPIKE-FIRST.** Do **not** modify the production Swift `OpenBurnBarCore` until Phase 0's G0 gate
   binds the stack on evidence. Phase 0 proves Swift-on-Windows viability (0-a), DB byte-compat (0-d), and the App
   Check pipeline (0-e); **G0 binds Option A (Swift-on-Windows Core reuse) or Option B (Rust/C# reimplementation).**
   The Core Engine/UI split, `wrapUntrusted` extraction, and explicit SQLCipher PRAGMA pinning happen **only after
   G0 binds Option A.** (Master plan §4, R1/R21.)
2. **Cloud scope = FULL parity via a TPM-attestation App Check custom provider.** Not local-only, not MSIX-identity.
   Build a **new secure Node Firebase-Admin backend** that verifies a **Windows TPM hardware-backed key attestation**
   (CNG `NCryptCreateClaim` / Windows Attestation APIs) and mints an App Check token via `createToken`; the Windows
   client's `getToken()` returns it. **Must clear the known Win11 Admin-SDK bug (firebase-admin-node #2308)** in the
   0-e spike. This is a real backend workstream, added to W3. (Master plan §9.3, R14, §15 decision 6.)
3. **Build environment = hosted Windows CI + macOS prep + one Windows dev host.** Windows builds/tests run on
   **GitHub Actions Windows runners**, mirroring the existing Android harness job. All macOS-doable prep (Rust
   `*-pc-windows-msvc` cross-compile, CI lane, portable fixtures, and — post-G0-Option-A — the macOS-side refactors)
   is done from the macOS workspace. **The user provides one Windows dev host** for interactive spikes that CI can't
   cover: WinUI shell, TPM attestation (0-e), opening a **real Mac SQLCipher DB** on Windows (0-d), ARM64 (0-g), and
   the real Claude Code Windows path encoding (0-h).

**Standing recommendations from the plan (not overridden, adopt unless changed):** UI = **WinUI 3** (§15 #2);
distribution = **direct MSIX/zip + winget primary, Store secondary** (§15 #3); **PetCompanion is in v1 scope** (§15
#4, consistent with full-parity intent).

## First mission phase — Phase 0 de-risk spikes → G0 go/no-go

Phase 0 is the gating phase; **G0 is a genuine go/no-go**, and 0-d (DB) or 0-e (App Check) can PIVOT the approach.
Spikes (master plan §4/§8):
- **0-a** Core `Engine`/`UI` split feasibility + compile the Engine subset on Swift-on-Windows (24-file surgery; incl.
  Pretext/WebKit, CloudVaultCrypto/Security, ComputerUseCore's 12 Darwin/XPC/Keychain files). *Proves Option A.*
- **0-b** WinUI 3 shell + tray + Mica + a live-streaming CLI spawn end-to-end.
- **0-c** `openburnbar-iroh` + `burnbar-remote` → `x86_64-pc-windows-msvc`, called from C# via a C-ABI shim
  (`uniffi-bindgen-cs` round-tripping one async+callback+error interface). *macOS cross-compile startable now.*
- **0-d** Open a **real Mac SQLCipher DB** on Windows: pin `cipher_compatibility`/`kdf_iter`/`cipher_page_size`,
  `--enable-fts5`, match `porter unicode61` + `bm25()`/`snippet()`, FTS5 MATCH identical row set, migrate to v53,
  schema-hash == Mac, write + reopen on Mac. Raw-SQLCipher-C fallback if GRDB won't build. *(R2 kill-risk.)*
- **0-e** Interactive desktop OAuth → Firebase custom-token → authenticated Firestore REST read/write, **AND** the
  full TPM→Node-Admin-backend→`createToken` App Check pipeline, clearing #2308. *(R14 kill-risk.)*
- **0-f** ConPTY interactive session (resize + clean process-tree kill) + the named-pipe peer-auth handshake.
- **0-g** ARM64 build-only proof (Core subset + both Rust crates + WinUI hello-world for `aarch64-pc-windows-msvc`).
- **0-h** Capture the **real Claude Code Windows** `~/.claude/projects/` path encoding as a fixture.

Also in Phase 0 (startable on macOS now): the empty Windows solution tree, `area: Windows` label + CODEOWNERS, a
skeleton Windows CI job, and **W0 procurement** (Authenticode/Azure Trusted Signing cert + Store/winget account
lead-times).

## Environment / setup assumptions

- macOS dev workspace (this repo, active software factory, 47+ CI workflows, ratchets/budgets).
- A user-provided **Windows dev host** (TPM-capable, x64; ARM64 if available) for interactive spikes.
- GitHub Actions **Windows runners** for CI builds/tests.
- Rust toolchain with `*-pc-windows-msvc` targets (cross-link from macOS may need the Windows SDK / `xwin`).
- Firebase project `burnbar` (App Check enforced fail-closed — the reason decision #2 exists).

## Testing / validation strategy

Master plan §11: **parser-output contract** (byte-identical token/cost/model vs a Mac golden — the headline),
**DB-compat vector**, **KAT triplet extended to Windows**, **prompt-injection-`wrapUntrusted` contract**, **e2e
multi-provider session-replay corpus**, Windows-native snapshot baseline + manual design review vs macOS goldens,
and **diff-coverage required on PRs** (not post-merge). Adversarial G0–G5 gates are the judgment layer.

## Non-functional requirements

Byte-compatible DB + wire protocol + CloudVault crypto (Tier A); preserve the prompt-injection wrapping invariant,
the computer-use capability-token/audit-chain/kill-switch semantics, and the daemon peer-auth strength (redesigned
for named pipes, R16). x64 + ARM64. Signed MSIX + auto-update from an Ed25519-**pinned** feed.

## Accepted non-goals (explicit — master plan §15.1)

- **v1.1:** secure-desktop / lock-screen input injection via a WHQL-signed virtual-HID driver (ViGEm covers the
  non-secure-desktop case in v1).
- Structurally N/A on Windows (Tier-C substitutions, not drops): Sign in with Apple (→ MSA/Google/email), iCloud
  mirror (→ OneDrive/Firestore-only), App Intents/Siri (→ command palette + hotkey).
- **Everything else in master plan §10.1 — including full cloud sync and PetCompanion — is v1 scope.** Unfinished
  scope is reported as incomplete, never relabeled out-of-scope.

## Known risks

Master plan §13 (R1–R22). The two Phase-0 kill-risks: **R2** (GRDB-no-Windows / SQLCipher byte-compat) and **R14**
(App Check — now a real TPM-backend workstream). Plus **R21** (24-file Core split) and **R22** (Pretext WKWebView
engine). Sizing: master plan §14 — ~1,000–1,300 PRs is a **floor** for Option A; a few agent-months.

## Execution vehicle

BurnBar software factory (`docs/SOFTWARE_FACTORY_PR_LOOP.md`) + Zenith orchestration. Codex = approval gate; branch
protection = merge gate; sharded review + per-workstream integration branches + per-tree budgets (master plan §6.3).
