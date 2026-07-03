# G0 pre-registration — falsifiable go/no-go rubric + Option-A/B bind procedure

**Status:** accepted (pre-registered) · **Area:** Windows port · Phase 0 → gate **G0**
**Contract:** `VAL-P0-GATE-030` · **Authored:** 2026-07-03 (macOS) — **before any Windows spike evidence lands**
**Specification:** [`docs/WINDOWS_PORT_MASTER_PLAN.md`](../docs/WINDOWS_PORT_MASTER_PLAN.md) §4 / §7.2 / §7.3 · [`docs/WINDOWS_PORT_MISSION_BRIEF.md`](../docs/WINDOWS_PORT_MISSION_BRIEF.md)

---

## Why this document exists (pre-registration integrity)

The G0 gate is a **genuine go/no-go with Alberto**: Phase-0 spike 0-d (DB byte-compat, R2) or 0-e
(App Check, R14) can *invalidate the approach*, and the engine stack (Option A vs. B) is **bound at
G0 on evidence, not assumed** (master plan §4, locked decision #1 = spike-first).

Master plan §7.2 requires the gate's pass/fail criteria to be **pre-registered before the phase
runs**, so the go/no-go is *pre-registered, not reverse-engineered from results*. This file fixes —
**now, on macOS, before the spikes report** — the falsifiable rubric that the later G0 verdict will
be judged against. Concretely, for **each of the seven §7.3 G0 exit criteria** it fixes:

1. a **measurable, falsifiable trigger** (what to run / read),
2. the **pass bar** (the exact condition that counts as GO for that criterion),
3. the **disposition on a miss** — is a miss a `PIVOT` (escalates to Alberto), a `FIX` (fix inside
   Phase 0 before GO), a `note-and-carry` (record a named gap, proceed, resolve in a later phase),
   or a `block` (G0 cannot return GO until resolved) — and,
4. the **owner** who executes the disposition and, where relevant, the **escalation path**.

Plus the **Option-A ABORT conditions** and the **A/B stack-bind decision procedure** (§Stack bind).

**This rubric is frozen by commit.** The commit that introduces this file predates the Phase-0
spikes report / G0 verdict, which land as a *separate later commit*. Commit order + dates are the
pre-registration proof.

> **`VAL-P0-GATE-030` FAIL conditions (verbatim intent):** authored *after* Windows results are
> known (commit order / dates prove pre-registration is defeated), **or** any of the 7 §7.3 criteria
> left without a pre-registered disposition. This document is written to make both impossible.

### Disposition vocabulary (fixed here so a miss can't be re-argued later)

| Disposition | Meaning | May G0 still `GO`? |
|---|---|---|
| **PIVOT** | The criterion's failure invalidates a *strategy* (stack, DB-reuse, or cloud). Escalate to **Alberto** with evidence + pre-framed options. | Only after Alberto binds the pivot. |
| **FIX** | A concrete, in-scope defect. Fix inside Phase 0 and **re-run the trigger before GO**. | Yes, once the re-run passes. |
| **note-and-carry** | A real but non-blocking gap. Record it as a **named, owned** item against a later phase (Phase-1 predecessor, G2, or G3) with its acceptance criterion. | Yes, with the carried item logged. |
| **block** | The criterion's *deliverable itself* is missing (e.g. nothing captured). G0 cannot `GO` for this criterion until the deliverable exists. | No. |

---

## The seven §7.3 G0 exit criteria — pre-registered rubric

Ordered as they appear in the master plan §7.3 **G0** row. All seven are enumerated; none is left
without a disposition.

| # | Criterion (§7.3) | Contract / spike | Disposition class | Owner (escalation) |
|---|---|---|---|---|
| 1 | **Stack bound A/B** against pre-registered abort conditions | `CORE-015` / 0-a | **decision + Option-A ABORT** | Mission lead + red-team → **Alberto** signs |
| 2 | **DB byte-compat**: real Mac DB opens + FTS5 identical row set + migrate-to-v53 + schema-hash == Mac | `DB-010` / 0-d (R2) | **PIVOT-bearing** | W2 native-core → **Alberto** on strategy pivot |
| 3 | **App Check posture resolved** (costed / risk-accepted in writing / PIVOT) | `AC-013` / 0-e (R14) | **PIVOT-bearing** | W3 data/cloud → **Alberto** (locked decision #2) |
| 4 | iroh/burnbar-remote **round-trip a byte-identical wire vector from C#** | Rust/FFI (`FFI-007` Mac-proven → Windows re-run; `RUST-005/006`) / 0-c | **required-pass** | W2 / Rust-lane lead |
| 5 | `claude --output-format stream-json` run → **N parsed events diffed vs. a Mac run** | `STREAM-029` / (0-h-adjacent) | **required-pass** | W4 parser lead (capture: Windows-host spike owner) |
| 6 | **ARM64 builds** | `ARM64-020` / 0-g | **required-pass** | W2 (core/crates) + W6 (WinUI shell) |
| 7 | Real **Claude Code Windows path encoding captured as a fixture** | `PATH-022` / 0-h (`PATH-021` Mac-proven) | **required-pass** | W11 / PATH lane (capture: Windows-host spike owner) |

The detailed trigger / pass bar / miss-disposition for each follows.

---

### Criterion 1 — Stack bound A/B · `CORE-015` · 0-a · *the bind decision + Option-A ABORT*

This criterion is not a single measurement; it is the **stack-bind decision itself**, driven by
whether the Option-A **Engine subset compiles clean on Swift-on-Windows**. The full A/B procedure is
in [§ Stack bind](#stack-bind--the-ab-decision-procedure); the pre-registered condition set is here.

**Prior macOS input (already landed):** `CORE-014` proved the Core `Engine`/`UI` split is
**tractable on the macOS half** — a UI-free `OpenBurnBarEngine` SwiftPM target compiled green — and
enumerated the 24-file cross-cutting seam surface (Pretext/WebKit, `CloudVaultCrypto`/Security,
`ComputerUseCore`'s 12 Darwin/XPC/Keychain files, feature-flag/app-state types) as **named seams,
not architectural blockers**. `CORE-015` is the *true* gate: does that Engine subset compile on
**Swift-on-Windows**?

**Measurable trigger (0-a / `CORE-015`):** on Swift-on-Windows (Swift 6, strict concurrency), attempt
a clean compile of the Engine subset — the ~90k Core-engine + extracted DataStore surface, with
swift-crypto (minus SecureEnclave, using the already-abstracted software-key seam), each of the 24
named UI/Apple seams **substituted or Windows-stubbed** (PretextEngine → WebView2 seam, `RGBA`/UI
primitives extracted, Security/Keychain → CNG/DPAPI seam).

**Pass bar (Option-A GO input):** the Engine subset **compiles clean** on Swift-on-Windows within the
spike window — Swift-6 strict concurrency holds at production quality (R1), and every one of the 24
seams resolves to a substitute or a stub (R21), with no load-bearing Core dependency left without a
Windows story.

**Pre-registered Option-A ABORT conditions** (any one fires → bind Option B):

- **A1** — the Engine subset **cannot compile clean** on Swift-on-Windows (toolchain cannot carry
  Swift-6 strict concurrency at production quality — R1).
- **A2** — the 24-file split proves **intractable** as a real refactor — a seam has no substitute and
  no stub (e.g. an Apple-only type is structurally load-bearing across the engine — R21).
- **A3** — a load-bearing Core dependency has **no Swift-on-Windows toolchain support** and no seam.
- **A4 (DB-linked)** — the DB reuse thesis collapses *and* the only remedy is a full data-layer
  rewrite that erases Option A's reuse premise (see Criterion 2's PIVOT branch). DB alone does **not**
  abort Option A — it has its own fallback ladder — but a total DB rewrite feeds this decision.

**Disposition on miss:** *decision, not miss.* If **no** abort condition fires → **bind Option A**.
If **any** fires → **bind Option B** (Rust/C# reimplementation + WinUI shell — the plan's ready
fallback, R1/R21). Either way the bind is a **written GO/NO-GO signed by Alberto** (locked decision
#1). Silence is not a bind.

**Owner:** mission lead assembles the evidence; the **cold red-team** (§7.1/§7.2) judges it against
these conditions; **Alberto signs** the bind.

---

### Criterion 2 — DB byte-compat · `DB-010` · 0-d · **PIVOT-bearing (R2, crown-jewel kill-risk)**

**Prior macOS input (already landed):** `DB-009` shipped the **de-risk kit** — a real Mac-produced
`openburnbar-db-compat-v53.sqlcipher` fixture (live migrator → v53, 54 migrations), the DB-compat
vector (schema hash `8f8f0eba…3992c` + FTS5 `bm25()`/`snippet()` row set), the observed params, and
[`decisions/sqlcipher-params.md`](sqlcipher-params.md) pinning `cipher_compatibility=4`,
`kdf_iter=256000`, `cipher_page_size=4096`, `HMAC_SHA512`, `PBKDF2_HMAC_SHA512`. A stock
`brew install sqlcipher` CLI already reproduces the schema hash + FTS vector cross-provider — a cheap
pre-check. `DB-010` is the **Windows-native** proof against the committed fixture.

**Measurable trigger (0-d / `DB-010`), all required:**

1. Open the committed `openburnbar-db-compat-v53.sqlcipher` on Windows with passphrase
   `OBB-WinPort-DBByteCompat-Fixture-Key-v53-000=` and **no extra PRAGMAs** → `PRAGMA cipher_version`
   non-empty.
2. Readback: `cipher_page_size=4096`, `kdf_iter=256000`, `cipher_hmac_algorithm=HMAC_SHA512`,
   `cipher_kdf_algorithm=PBKDF2_HMAC_SHA512`.
3. **Schema hash == Mac** — SHA-256 over the normalized `sqlite_master` DDL (the `DB-009` algorithm:
   `SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY
   type,name`, `strip()` each, join with `\n`; 170 statements for v53) equals the committed vector.
4. **FTS5 identical row set** — the 4 `MATCH` probes return `bm25()`/`snippet()` rows byte-identical
   to the vector (porter stemming, case-folding, multi-column indexing, rank order).
5. **Migrate-to-v53** — a fresh DB run through the *live* migrator lands at
   `v53_memory_forget_outbox` with the same schema hash.
6. **Round-trip** — write a row on Windows, reopen on Mac; the Mac reads it clean.

**Pass bar:** all six hold, via **either** the GRDB-on-Windows build **or** the raw-SQLCipher-C
fallback the plan already names.

**Pre-registered disposition ladder (R2 is PIVOT-bearing):**

- **GRDB builds on Windows + fixture opens byte-identical** → **GO input for Option A**, DB path =
  **GRDB**.
- **GRDB won't build on Windows, but raw-SQLCipher-C opens the fixture byte-identical** → **GO for
  Option A with the raw-SQLCipher-C data layer.** This is a pre-registered *sub-branch selection*
  (DB path = raw-C), **not** an Option-A abort — the plan names raw-SQLCipher-C as the fallback (§9.3).
  Owner **W2** picks GRDB-vs-raw-C on the evidence; no Alberto escalation.
- **A pinnable parameter mismatch** (schema hash or FTS row set differs, but an *explicit* PRAGMA pin
  — `cipher_compatibility=4; kdf_iter=256000; cipher_page_size=4096` — makes it reproduce, per
  `decisions/sqlcipher-params.md`) → **FIX**: add the explicit pins on **both** platforms in
  lock-step, re-run the trigger before GO. Owner **W2**.
- **Neither GRDB nor raw-SQLCipher-C reproduces byte-compat, and no Mac-side pin fixes it** → the
  "reuse the Mac's encrypted file" thesis is **falsified** → **PIVOT to Alberto** with the exact
  failing parameter and two pre-framed options: **(i)** re-encrypt / migrate on first Windows open (a
  bounded data-migration path, added scope), or **(ii)** Windows keeps its own local DB and reaches
  shared state only through the cloud/CloudVault layer. If the only viable remedy is a full data-layer
  rewrite, this also fires Option-A abort condition **A4** (feeds Criterion 1). **Never a silent
  workaround.**

**Owner / escalation:** **W2 native-core lead** owns the GRDB↔raw-C↔explicit-pin ladder; a *strategy*
pivot (re-encrypt vs. cloud-only) escalates **mission lead → Alberto**.

---

### Criterion 3 — App Check posture resolved · `AC-013` · 0-e · **PIVOT-bearing (R14, existential for cloud)**

**Prior macOS input (already landed):** `AC-011`/`AC-011B` built the **mint backend** —
`functions/src/callables/windowsAppCheck.ts`, the first `admin.appCheck().createToken` caller — with
a **MOCK attestation verifier behind a registry that is EMPTY under prod config** (the prod fence is
an *absent verifier*, not an `if(prod) disable`), plus the Windows-app-id allowlist surfaces
(`config.ts`, relay `auth.ts`, index) and accept/reject tests on all three enforcement surfaces. The
server half is 100% macOS-buildable against a mock fixture. `AC-013` is the **real Windows TPM
attestation** end-to-end (locked decision #2 = full cloud via TPM-attestation).

**Measurable trigger (0-e / `AC-013`):** on a real TPM-capable Windows host —

1. Mint a **Windows TPM hardware-backed key attestation** (CNG `NCryptCreateClaim` / Windows
   Attestation APIs).
2. The **Node Firebase-Admin backend** verifies it and calls
   `admin.appCheck().createToken(windowsAppCheckAppID, {ttlMillis})`.
3. The minted App Check token is **accepted** by ≥1 App-Check-enforcing callable **and** the relay
   `x-firebase-appcheck` header check → an **authenticated, App-Check-enforced Firestore REST
   read/write** completes from Windows.
4. The known **firebase-admin-node #2308** (`App attestation failed` on Win11) does **not** block
   minting — either it does not trigger, or a documented workaround is applied and recorded.

**Pass bar (§7.3 wording — the posture is *resolved*, in exactly one of three states):**

- **(a) Costed & GO** — the full TPM pipeline stands up and clears #2308 → **cloud is v1 scope** as
  locked (brief decision #2(a)). This is the target.
- **(b) Risk-accepted in writing** — the strong TPM path slips, but the weaker **MSIX-package-identity
  signal** via the same custom-provider plumbing is stood up **with a written, Alberto-signed risk
  acceptance** (documented lower assurance). Cloud ships on the weaker signal.
- **(c) PIVOT to Alberto** — no attestation path is viable in the spike window → escalate with
  evidence; the pre-framed choice is **fund more backend work** to clear the blocker (schedule
  impact) **or** ship Windows **local-only for v1** (no cloud sync / Hermes relay / hosted Insights),
  moving the cross-platform-E2EE cloud criterion to the **v1.1 gate** (master plan §15.1) with its
  acceptance criterion stated to users, not hidden.

**Disposition on miss:** because locked decision #2 fixes *full cloud*, moving off (a) to (b) or (c)
is a **scope change only Alberto can make** — it **PIVOTS to Alberto**, and G0 does not `GO` on this
criterion until Alberto has bound (a), (b)-with-signed-acceptance, or (c). **Never a silent Phase-3
surprise** (master plan §4). Any of the three *is* a valid G0 resolution; an *unresolved* posture is
a `block`.

**Owner / escalation:** **W3 data/cloud lead** owns the pipeline + the #2308 clearance; the posture
choice escalates **mission lead → Alberto** (decision #2 is locked).

---

### Criterion 4 — Rust/FFI byte-identical wire vector from C# · 0-c · **required-pass (not PIVOT)**

**Prior macOS input (already landed):** `FFI-007` proved a **byte-identical golden wire-vector
round-trip** via `dotnet test` on macOS (5/5) against the native `libburnbar_remote.dylib`, using the
`uniffi-bindgen-cs` C# binding (WPD-0001); `RUST-005` added the `*-pc-windows-msvc` targets + Windows
build workflows and cross-compiled the `burnbar_remote.dll` from macOS (WPD-0002). `G0` needs the
**Windows-native** re-run.

**Measurable trigger (0-c):** on Windows (CI lane `RUST-006` and/or the dev host), the C# binding
loads the Windows `burnbar_remote.dll` and round-trips the **committed golden wire vector** through
`encode/decode_quality_decision` (async + callback + error interface) → `dotnet test`.

**Pass bar:** the C# round-trip output is **byte-identical** to the Mac golden (the same 5/5 vectors),
proving the parity-locked wire protocol is preserved across the Windows binding.

**Disposition on miss (required-pass):**

- **Byte-identical** → **PASS**.
- **A byte diff** → **FIX** inside Phase 0. The wire protocol is **Tier-A byte-compatible** (a
  non-functional requirement) and is consumed by cloud sync; a Windows diff would corrupt
  cross-platform state. Root-cause it in the C# binding (endianness / struct packing / string
  encoding) and **re-run before GO**. This is *not* note-and-carry (unlike the parser, the vector is
  small and already Mac-proven, so a Windows diff is a concrete binding bug to fix now) and *not* a
  stack PIVOT (binding-level, not stack-level).
- **The `.dll` cannot be built or loaded on Windows at all** → **block** G0 for this criterion until
  the `RUST-006` Windows build lane is green (a named dependency).

**Owner:** **W2 / Rust-lane lead**.

---

### Criterion 5 — stream-json parse-diff · `STREAM-029` · **required-pass (not PIVOT)**

**Measurable trigger:** run `claude --output-format stream-json` on Windows against a **fixed prompt**,
capture **N** events, normalize them per the **parser-output contract** (exclude wall-clock /
UUID / absolute-path volatile fields — `PARSER_OUTPUT_CONTRACT.md`), and **diff the normalized event
stream** against a Mac run of the *same* prompt.

**Pass bar:** the fixture is **captured** *and* the normalized streams are **identical** — or every
diff line is attributable to a **known-portable transform** (CRLF↔LF line framing, path-remap) that
the W4 Claude Code parser will absorb, with each such line characterized in the captured delta.

**Disposition on miss (required-pass; the G0 deliverable is the *captured, characterized* fixture —
the parser is fixed at G2, not G0):**

- **Diff only in already-excluded volatile fields** → **PASS** (not a miss).
- **Diff is line-framing / encoding** (CRLF, BOM, UTF-16) → **FIX** in Phase 0: it is cheap and
  foundational to *every* parser; normalize and re-run before GO.
- **Diff is a genuine event-shape / contract-relevant field difference** → **note-and-carry to
  Phase 2**: capture it as a fixture delta the **W4 Claude Code parser** must handle (path-remap
  layer), enforced by the **G2 parser-output contract vector** (the headline G2 gate). G0 `GO`s with
  the delta captured + owned; the parser is not required to be fixed at G0.
- **Claude Code cannot emit stream-json on Windows at all** → **block** this criterion (no fixture is
  capturable) until an alternate capture path is found; surface as a scoping note (not a stack PIVOT).

**Owner:** **W4 parser lead** owns the diff + the carry item; the **Windows-host spike owner**
performs the capture.

---

### Criterion 6 — ARM64 builds · `ARM64-020` · 0-g · **required-pass (not PIVOT)**

**Measurable trigger (0-g, build-only at G0):** compile for `aarch64-pc-windows-msvc` — (i) the Core
engine subset (Option-A Engine, or the Option-B core once bound), (ii) **both** Rust crates
(`openburnbar-iroh`, `burnbar-remote`), and (iii) a **WinUI hello-world** shell.

**Pass bar:** all three **build clean** for ARM64. (Full ARM64 *functional* parity — running the whole
suite — is a **G3** criterion, §7.3, not G0.)

**Disposition on miss (required-pass):**

- **All three build clean** → **PASS**.
- **An isolated component fails to build for ARM64 while x64 is green, and the failure is a
  third-party / host-tooling gap with a documented remedy** (à la the `RUST-005` finding: source is
  target-clean, only `llvm-lib` was missing) → **note-and-carry to Phase 3**: log the failing
  component + its remedy; ARM64 functional parity is the G3 gate. G0 `GO`s.
- **A load-bearing component has no ARM64-Windows build path and no remedy** → **block** G0 for this
  criterion; if it is architecturally impossible for the *bound stack*, it feeds the stack decision
  (Criterion 1) as an additional data point (extremely unlikely — Rust and WinUI both support ARM64).

**Owner:** **W2** (core + crates) and **W6** (WinUI shell) leads for their respective build targets.

---

### Criterion 7 — Claude Code Windows path encoding fixture · `PATH-022` · 0-h · **required-pass (not PIVOT)**

**Prior macOS input (already landed):** `PATH-021` shipped the **Foundation-only, portable**
`ClaudeCodeProjectPathCodec` + the capture-schema fixture, empirically proving the codec is
`cwd.replace(/[^A-Za-z0-9]/g, "-")` against **26/27 live macOS sessions**; the Windows/UNC/non-ASCII
rows are already **modeled** in the fixture as `captured:false`. `PATH-022` is the **real Windows
capture** that flips them to `captured:true`.

**Measurable trigger (0-h / `PATH-022`):** on a real Windows Claude Code install, read the `cwd` field
inside real `~/.claude/projects/**/*.jsonl` and confirm the schema invariant `encode(cwd) == dirName`
(the fixture's `capturedRowMismatches()` assertion) for ≥1 captured row per path class: drive-letter
(`C:\Users\a` → `C--Users-a`), UNC (`\\srv\share` → `--srv-share`), and non-ASCII (incl. the
modeled-not-yet-observed astral `😀` → `--`).

**Pass bar:** the fixture is **updated with real Windows captures** (`captured:true`) and
`encode(cwd) == dirName` holds for every captured row — i.e. the observed encoding **matches** the
shipped codec.

**Disposition on miss (required-pass):**

- **Observed encoding matches the codec** → **PASS**.
- **Observed encoding differs from the codec** (e.g. Claude Code encodes `C:\` other than `C--`) →
  **FIX** as a **Phase-1 predecessor** (before the W4 parser fan-out): the codec is small,
  Foundation-only, and already shipped; a wrong codec silently mis-routes *every* Windows session's
  logs. Correct the codec, re-capture, re-assert. Not a stack PIVOT (Option A/B is unaffected).
- **The Windows dev host is unavailable to capture in the spike window** → **note-and-carry to
  Phase 1**: keep the modeled rows `captured:false` with a named owner; G0 may `GO` because the codec
  is already proven against 26/27 macOS sessions and the Windows forms are algorithmically derived —
  but the capture is a tracked, owned Phase-1 item, not silently dropped. (If a host *is* provided per
  the brief, capture is required and its absence is instead a `block` on the deliverable.)

**Owner:** **W11 / PATH lane lead** owns the fixture + any codec FIX; the **Windows-host spike owner**
performs the capture.

---

## Stack bind — the A/B decision procedure

This is the mechanism behind Criterion 1. It is the mission's **one genuine cross-cutting barrier at
G0** (master plan §6: the two fleet-wide barriers are the stack-bind at G0 and the PAL contract at
G1). Locked decision #1: **do not modify the production Swift `OpenBurnBarCore` until this bind**.

1. **Collect** the Phase-0 spike evidence for all 7 criteria into the spikes report (the *later*
   commit this rubric judges).
2. **Evaluate the Option-A ABORT conditions** (Criterion 1's A1–A4), gated primarily on **`CORE-015`
   Engine-subset-compiles-clean-on-Swift-on-Windows** and secondarily on the **`DB-010` fallback
   outcome** (A4).
3. **If NO abort condition fired → BIND Option A** (Swift-on-Windows Core reuse + WinUI shell). Only
   *then* do the macOS-side refactors the brief gates behind Option A begin in Phase 1: the Core
   `Engine`/`UI` split, the `wrapUntrusted` extraction into Core (R18), and the explicit SQLCipher
   PRAGMA pinning on both platforms.
4. **If ANY abort condition fired → BIND Option B** (Rust/C# reimplementation + WinUI shell — the
   plan's ready fallback). Phase 1 proceeds on the Option-B core; the DB and cloud criteria still
   apply against their own dispositions above.
5. **The bind is a written GO/NO-GO signed by Alberto.** G0 and G1 are the two hard barriers that
   require Alberto sign-off; the App Check posture (Criterion 3) escalates to Alberto independently if
   it lands on (b) or (c).
6. **Record** the bind + the evidence + the red-team's written refutation (below) in the spikes
   report / G0 verdict. This pre-registration file is *not* edited to match the outcome — it is the
   fixed rubric the outcome is scored against.

### GO / FIX / PIVOT summary for the whole gate

- **GO** requires: Criterion 1 bound (A or B) + Criteria 2–7 each at their pass bar **or** carrying a
  logged, owned disposition (`FIX` re-run passed / `note-and-carry` recorded) — and **no** open
  `block` and **no** unresolved `PIVOT`.
- **FIX** loops stay *within* Phase 0 (re-run the trigger before GO).
- **PIVOT** (Criterion 2's strategy branch; Criterion 3's (b)/(c)) **escalates to Alberto** and
  suspends GO for that criterion until Alberto binds it.

---

## Red-team gate mechanics (how this rubric is applied) — §7.1 / §7.2

The G0 verdict is produced by an **independent cold red-team** judged against *this* pre-registered
rubric, per master plan §7.1/§7.2:

- **claim harvest → diverse-lens refutation (parallel) → verdict quorum → synthesize GO/FIX/PIVOT.**
  Lenses: correctness, parity-gap, false-parallelism, **security-regression**, Windows-idiom.
- **Pass/fail is pre-registered** (this file) *before* the phase ran.
- At least one **cold** critic reviews **without** the builders' rationale.
- A **written refutation attempt is required even on GO.**
- **No builder reviews a seam they built or consumed** (e.g. the `CORE-014`/`CORE-015` author does not
  sit on the stack-bind red-team; the `DB-009`/`DB-010` author does not judge the DB criterion).

---

## Coverage self-check (all 7 §7.3 criteria have a pre-registered pass/fail + disposition + owner)

| # | Criterion | Contract | Pass bar fixed? | Disposition fixed? | Owner fixed? |
|---|---|---|:---:|:---:|:---:|
| 1 | Stack bound A/B (Option-A ABORT + A/B procedure) | `CORE-015` | ✅ | ✅ decision + ABORT | ✅ mission lead → Alberto |
| 2 | DB byte-compat (real Mac DB / FTS5 / v53 / schema-hash) | `DB-010` | ✅ | ✅ **PIVOT** ladder | ✅ W2 → Alberto |
| 3 | App Check posture resolved | `AC-013` | ✅ (a/b/c) | ✅ **PIVOT** to Alberto | ✅ W3 → Alberto |
| 4 | Rust/FFI byte-identical wire vector from C# | `FFI-007`→Win / `RUST-006` | ✅ | ✅ FIX / block | ✅ W2 / Rust lane |
| 5 | stream-json parse-diff vs. Mac | `STREAM-029` | ✅ | ✅ FIX / carry-to-P2 / block | ✅ W4 parser lead |
| 6 | ARM64 builds | `ARM64-020` | ✅ (build-only) | ✅ carry-to-P3 / block | ✅ W2 + W6 |
| 7 | Claude Code Windows path fixture | `PATH-022` | ✅ | ✅ FIX / carry-to-P1 / block | ✅ W11 / PATH lane |

Plus the **stack-bind procedure** (§ Stack bind) and the **pre-registration integrity** guarantee
(this file predates the spikes report by commit order). All seven §7.3 G0 criteria — `CORE-015`,
`DB-010`, `AC-013`, the Rust/FFI wire vector, `STREAM-029`, `ARM64-020`, `PATH-022` — carry a
pre-registered disposition. None is left to be reverse-engineered from results.
