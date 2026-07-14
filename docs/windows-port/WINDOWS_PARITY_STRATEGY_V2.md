# Windows ↔ macOS parity strategy v2 (adversarially hardened)

**Date:** 2026-07-09
**Status:** Authoritative strategy after loophole pass on the 2026-07-09 scan
**Supersedes for strategy/ordering:** naive phases in `WINDOWS_MACOS_PARITY_SCAN_2026-07-09.md` §6–7
**Does not supersede:** `WINDOWS_PARITY_LEDGER.yml` (status SoT), WPD-0003/0005/0006/0007 (architecture), master plan tier contract

---

## 0. Confidence statement (honest)

**No multi-month port strategy can be epistemically 100% certain about calendar, PR count, or third-party APIs.**
What *this* document claims at high confidence:

| Claim | Confidence | Basis |
|---|---|---|
| The prior scan’s phase order and “full parity” wording had material loopholes | **Certain** | Code + WPD evidence below |
| Two **distinct** finish lines must be named (Ship Peer vs True 1:1) | **Certain** | WPD-0006 defers 18 daemon rows while product still says “full parity” |
| Chat Real ≠ “enable ConPTY” | **Certain** | `ChatSurfaceView` never uses `CliStreamFactory` / ConPTY |
| Model Proxy UI without a gateway process is not Mac peer | **Certain** | WPD-0006 row 1 DEFER; Mac `ModelProxySettingsView` drives live gateway |
| Insights can silently invent non-KPI chart data without sample mode | **Certain** | `CloudSyncInsightSource` → `InsightSampleData.ForKind` |
| vTPM ≠ final hardware App Check acceptance | **Certain** | HANDOFF TPM caveat |
| Remaining residual risks (listed §9) are closed-set and named | **High** | Only after this pass |

**Therefore:** confidence in **v2 strategy structure and ordering** is high; confidence that “no unknown work remains” is **not** 100% — residual risks stay explicit in §9, never rebranded as done.

---

## 1. Loopholes found in v1 scan/strategy (and fixes)

### L1 — “Full parity” vs 18 deferred daemon capabilities

**Loophole:** Scan promised “full peer parity with macOS” while WPD-0006 **DEFER**s 18 rows (HTTP gateway, provider router/executors, headless run service, local Mission Control execution, Pensieve watcher, browser CU/Playwright, Elder Wand orchestration, companion CLI, connector plane, …). That is not 1:1 Mac.

**Fix — two finish lines (must pick; default Ship Peer):**

| Finish line | Name | Includes | Excludes (documented) |
|---|---|---|---|
| **F1 — Ship Peer (G5 default)** | Local peer desktop under accepted WPDs | Log ingest, quota, chat via in-app backends, CU desktop loop, pet, cloud sync, DCC, tray, signed install | Remaining WPD-0006 DEFER rows, physical parser performance, Tier-C Apple-only |
| **F2 — True 1:1** | Mac feature completeness | F1 **plus** local HTTP gateway + model proxy live, local mission execution, headless runs, Pensieve watcher, project-code static parser, browser CU, Elder Wand fusion orchestration | Only Tier-C structural N/A |

**Gate language rule:** Never say “100% parity” without **F1** or **F2**. Ledger Real on F1 scope ≠ F2 complete.

**Product decision required (Alberto or goal-driver):** Confirm **F1 default**. If Model Proxy / local gateway is non-negotiable for “peer,” promote WPD-0006 rows 1–4 (and dependents) from DEFER → SUB-BUILD and add a gateway workstream (Linux-boundary Swift Service or C# gateway port).

---

### L2 — Chat Real conflated with ConPTY

**Loophole:** Phase 1 said “ConPTY chat production driver as default → nav-chat Real.”
**Facts:**

- `ChatSurfaceView` constructs `new ChatSurfaceViewModel()` with no driver injection.
- Default driver = `UnavailableChatStreamDriver` (or scripted only if `OPENBURNBAR_SAMPLE_MODE=1`).
- `CliStreamFactory` / `ConPtyCliStream` feed `LiveCliStreamView` (spike CLI pane), **not** the Hermes atom chat surface.
- Mac chat uses `CLIBridge` + `ChatBackendRegistry` (codex / hermes / pi, …); Hermes/Pi expect a **local gateway**.

**Fix — Chat work is three layers (ordered):**

1. **C-Chat-1:** `IChatStreamDriver` adapters for at least one real backend on Windows
   - Minimum F1: **CLI stream-json → `ChatStreamEvent`** (Claude/Codex/Grok CLI) via ConPTY or process pipes, composed into `ChatSurfaceViewModel`.
   - Not the same as showing raw PTY text in `LiveCliStreamView`.
2. **C-Chat-2:** Backend registry + settings (enabled backends, model pick) peer of Mac `ChatBackendID` subset that F1 supports.
3. **C-Chat-3 (F1 optional / F2 required):** Hermes/Pi **gateway-backed** chat — only after a gateway process exists (WPD-0006 row 1 revive or substitute).

**Ledger rule:** `nav-chat` stays Blocked until C-Chat-1 is production default (not Unavailable). ConPTY green alone does not flip the row.

---

### L3 — Settings “bind the 11 VMs” oversold

**Loophole:** Treating Settings as a XAML bind wave implied Mac depth. Reality:

- VMs are **partial** (e.g. Agents = quota display + managed runtimes + Cursor connector; not full Connections wizard / provider plan).
- **Model Proxy VM** persists gateway endpoint fields for a **server that does not exist** under F1 (WPD-0006 row 1 DEFER). Shipping a full Model Proxy page that only edits dead config is a **false peer**.
- Account/Cloud/Devices remain DataGated until OAuth + App Check — leaf pages before cloud are UI theater for Real.

**Fix — Settings tiers:**

| Tier | Tabs | Definition of done |
|---|---|---|
| **S0** | General, Updates, Appearance, Data Sources | Already real pages — keep production-honest |
| **S1** | Daemon (substitution matrix UI), Alerts, Notifications, Text Expansion, Pets, Computer Use (policy UI) | Real XAML + portable VM + no dependency on deferred servers |
| **S2** | Account, Cloud, Devices & Sync | Only after OAuth + App Check mint path works |
| **S3a (F1)** | Agents (connections subset), Cursor connector | Real without local BurnBar HTTP gateway |
| **S3b** | Model Proxy | **F1:** settings show “Gateway deferred (WPD-0006)” + cannot enable a non-existent server **or** promote gateway. **F2:** live gateway required |
| **S4** | Media | After Mercury live adapters |
| **S5** | Settings Copilot, full Provider Plan wizard | Explicit depth; optional F1, required for F2 polish |

**Rule:** No production route may open `SettingsPlaceholderPage` for S0–S2 after their phase; S3b must not look “live” without a server.

---

### L4 — Insights silent sample (honesty bug)

**Loophole:** Strategy assumed sample only under `OPENBURNBAR_SAMPLE_MODE`.
**Fact:** `CloudSyncInsightSource` falls back to `InsightSampleData.ForKind` for non-KPI widgets when cloud/local data is missing — **without** checking sample mode. That is silent fabricated chart geometry.

**Fix (Wave 0 code, before any Real claim on insights):**

- Empty / “no data” widget data for all kinds when sample mode is off.
- Sample data only if `RuntimeDataMode.SampleModeEnabled`.
- Add a test that fails if non-sample path constructs `InsightSampleData`.
- Rename confusing `*SampleData` empty helpers (e.g. session logs empty source is fine behavior, bad name for scanners).

**Same audit** for every `*SampleData` call site not gated by `RuntimeDataMode.SampleModeEnabled`.

---

### L5 — Database + Projects as “Week 2 full ports”

**Loophole:** Mac Database workspace is multi-mode (**story / atlas / system**) with large snapshot builders; Projects includes memory/detail sheets. Strategy treated both as equal nav fill-ins.

**Also:** Project Code Memory static parser is **deferred by WPD-0003 past Phase 0**, scheduled for engine/W4 — not “permanent v1.1 drop,” but **not available for full Projects depth day one**. Lexical fallback only.

**Fix — IA completeness in slices:**

| Slice | Deliverable | Parity level |
|---|---|---|
| **IA-1** | `database` + `projects` keys in `NavCatalog` + pages | Routes exist (unblocks ledger Blocked) |
| **IA-2** | Database **system** mode first (schema/tables/FTS over SQLCipher seam) | Functional peer of Mac System mode |
| **IA-3** | Database story/atlas | Visual/product depth |
| **IA-4** | Projects list + open path from usage DB / folder paths | List-level peer |
| **IA-5** | Projects memory + static parse depth | Closed by WPD-0003 revival, native x64/ARM64 parser evidence, and the encrypted source-free semantic store |

**Do not** claim physical parser performance from hosted architecture evidence;
WPD-0003 is revived for implementation, while physical performance remains a
release-certification gate.

---

### L6 — Mission Control “surface Real” ≠ local execution (closed for F2)

**Original loophole:** Mac can schedule/execute missions via daemon DAG while
Windows F1 initially shipped only **Firestore dispatch + console client**.
Calling that “full Mission Control parity” was false.

**Resolution:** WPD-0009 fired the F2 trigger and WPD-0006 row 14 is now
`SUB-DONE`: the authenticated companion plane production-composes deterministic
local DAG planning/execution, policy, rate limiting, metadata-only journaling,
and resume/recovery. F1 remains accurately described as a dispatch client;
local execution is the separately evidenced F2 capability.

---

### L7 — App Check / vTPM overconfidence

**Loophole:** Punchlist treats VM vTPM as retiring R14. HANDOFF: vTPM proves ~95% of flow; **manufacturer-signed hardware EK** may still require a physical Windows box for final trust policy.

**Fix — two evidence levels:**

| Level | Environment | Unblocks |
|---|---|---|
| **R14-A** | Win11 + vTPM mint → `createToken` → enforced callable | Dev/cloud integration; most Real cloud rows |
| **R14-B** | Physical TPM / production App Check policy acceptance | Production-enforced App Check if backend requires hardware EK |

Strategy: drive R14-A immediately on VM; keep R14-B as residual until policy is known. Do not mark production cloud “certified” if backend rejects vTPM EK.

---

### L8 — Fake percentages and “agent ceiling ~65%”

**Loophole:** ~50–55% / ~65% are not measurable from the ledger and create false precision.

**Fix — only ledger-derived metrics:**

```
Real_count / in_scope_rows(F1)
Blocked_product_count
Settings_tabs_with_real_page / SettingsTab_count
Mac_primarySections_mapped / 7
Silent_sample_call_sites (must be 0)
```

No composite “% done” in ship claims.

---

### L9 — Phase order ignored hard dependencies

**Loophole:** Settings Account/Cloud Real and Memory/DCC/Missions Real before OAuth+App Check; packaging before cert; “sample death” before honesty audit.

**Fix — dependency DAG (see §3).** Violating edges is a process failure, not a PR style preference.

---

### L10 — Branch / integration risk ignored

**Loophole:** Working branch `windows/liquid-glass-kernel-reskin` diverged (ahead/behind origin). Strategy assumed a clean factory lane on main.

**Fix:** Every wave PR rebases onto current `main`; liquid-glass work stays a **theme lane** that must not gate F1 data Real. Integration conflict budget is explicit residual risk.

---

### L11 — Elder Wand surface vs orchestration

**Loophole:** Surface Real without fusion orchestrator (WPD-0006 row 32 DEFER) overclaims analysis product.

**Fix:** F1 = preset + judge config + persistence; F2 = multi-model fusion orchestration. UI copy must not promise fusion runs that cannot execute.

---

### L12 — Session logs naming vs scanner semantics

**Loophole (resolved H0):** `SessionLogSampleData` name tripped mental “fake data” model while implementation was **empty** (honest). **Renamed → `SessionLogEmptySource`** (H0 honesty unit).

**Fix:** Rename to `EmptySessionLogReadSource` in a small honesty PR; keep behavior. Real still requires configured SQLCipher + production path never depending on demo labels.

---

## 2. Corrected definitions

### 2.1 F1 Ship Peer (recommended default)

Windows is a **local log-reading peer** like Mac for:

- Ingest + parse agent CLI logs (G2 already Real)
- SQLCipher usage/session data (read proven; write breadth tracked)
- Quota acquisition + workspace
- Budget rules
- Chat via **in-app CLI backends** (C-Chat-1), not necessarily Hermes gateway
- Mission **dispatch** to cloud/Mac, console UX
- Memory review / cloud facts when attested
- DCC callables when attested
- Computer-use **desktop** loop (SendInput/UIA/WGC/ViGEm + audit)
- Pet overlay
- Tray/flyout, onboarding, settings S0–S2 + S3a
- Signed MSIX + update
- Cast/HA/SmartHub/Mercury at **live-once evidence** level

**Explicitly not F1 (F2 or named DEFER):** local BurnBar HTTP gateway as product, headless daemon runs, local mission DAG execution, Playwright browser CU, project-code static parser full fidelity, Pensieve local watcher, Settings Copilot full, secure-desktop HID.

### 2.2 F2 True 1:1

F1 + revive WPD-0006 DEFER rows that Mac users treat as core. Gateway/model
proxy, headless/local mission execution, Browser CU, and the project-code parser
are now promoted through C# substitutes and native Windows parser evidence;
Full Elder Wand fusion and connector brokers remain explicit workstreams.
General Pensieve watching, Telegram, and gateway token-bucket limiting are
closed by `docs/windows-port/evidence/f2/pensieve-knowledge-watcher.md`,
`docs/windows-port/evidence/f2/telegram-bridge.md`, and
`docs/windows-port/evidence/f2/gateway-rate-limiter.md`.

---

## 3. Dependency DAG (only legal order)

```text
[0 Honesty] Silent-sample purge + rename empty helpers
        │
        ├──────────────────────────────────────────────┐
        v                                              v
[1 Human gates] VM+SSH, OAuth secrets, cert start, CI required
        │
        v
[2 Host foundation] R14-A, OAuth e2e, ConPTY proof, FFI msvc, E2EE C5
        │
        v
[3 Chat F1] C-Chat-1 driver + registry subset  ──► nav-chat leave Blocked
        │
        v
[4 Cloud Real] Memory, DCC live, Mission dispatch live, Settings S2
        │
        v
[5 IA] database/projects routes + system/list slices
        │
        v
[6 Settings S1/S3a] placeholder death for non-gateway tabs
        │
        v
[7 Surface Real] Dashboard, Quota, Logs, Budget, Flyout, Insights, Switcher, Onboarding
        │
        v
[8 G4] CU full loop + Pet live + integrations live-once
        │
        v
[9 G5] Signed dist + update + evidence freeze
        │
        v
[10 Optional F2] Gateway / local execution / WPD-0003 / browser CU / fusion
```

**Illegal:** claiming Insights/Dashboard Real before [0]; Settings Account Real before [2]; Model Proxy “live” before [10] under F1; G5 without cert.

---

## 4. Phased plan (v2)

### Phase H0 — Honesty & metrics (1–3 days, no VM)

1. Gate all chart/demo fabrication on `RuntimeDataMode.SampleModeEnabled` (`CloudSyncInsightSource` first).
2. Repo-wide audit: ungated `*SampleData` / `DemoHost` / scripted drivers.
3. Rename empty “Sample” types that are not demos.
4. Publish F1/F2 scope table in certification bundle + Engine Room settings.
5. Stop using composite % scores in PRs/docs.

**Exit:** CI test forbids silent InsightSampleData outside sample mode; docs say F1/F2.

### Phase H1 — Alberto gates (calendar)

Unchanged necessity: VM+SSH, Trusted Signing start, Desktop OAuth client secrets, require Windows full gate, Partner Center if Store.
**Add:** written choice **F1 vs F2** (default F1). If F2, schedule gateway workstream now.

### Phase H2 — Host foundation (VM)

| ID | Work | Unblocks |
|---|---|---|
| H2.1 | Full `dotnet` solution build/test on Windows | XAML truth |
| H2.2 | R14-A App Check on vTPM | Cloud Real |
| H2.3 | OAuth loopback e2e with real client | Sign-in |
| H2.4 | ConPTY interactive proof (CLI) | Chat adapter input |
| H2.5 | CloudVault live Windows→Mac | C5 row |
| H2.6 | FFI msvc loopback | Native Real |
| H2.7 | Particles 60fps ARM64 | G3 canvas |
| H2.8 | Record R14-B residual | Production policy |

### Phase H3 — Chat F1 (critical path product)

1. Implement `CliJsonChatStreamDriver` (or equivalent) mapping stream-json → `ChatStreamEvent`.
2. Wire `ChatSurfaceView` composition root: production default = real driver when CLI present; else Unavailable with **actionable** empty state (already close).
3. Backend picker for F1 subset (e.g. claude/codex/grok CLI).
4. Pretext WebView2 metric tests (tolerance).
5. Flip `nav-chat` only when production path is non-Unavailable on configured host.

**Do not** wait for full Hermes gateway for F1 chat usefulness.

### Phase H4 — Cloud surfaces Real

After H2.2+H2.3: Memory, DCC authenticated callables + high-risk envelope, Mission dispatch host (not demo), Settings S2 pages, Switcher cloud bits if any.

### Phase H5 — IA Database & Projects (sliced)

IA-1 routes → IA-2 Database system → IA-4 Projects list → (later) IA-3/IA-5.
WPD-0003 revive is a **named F2/F1.1 task**, not silent.

### Phase H6 — Settings placeholder death (honest tabs only)

S1 then S3a; S3b Model Proxy: **deferred disclosure UI** under F1 or gateway under F2.
Media S4 after integrations.

### Phase H7 — Remaining surface Real conversion

Dashboard, Quota (live acquisition), Budget, Session logs (configured DB), Flyout tray, Insights (post-H0), Onboarding first-run, Elder Wand presets (not fusion).

### Phase H8 — G4 system integration

CU full loop evidence, Pet overlay live, Cast/HA/SmartHub/Mercury live-once, text-expansion global hook proof.

### Phase H9 — G5 ship

Signed MSIX, update round-trip, winget, evidence freeze, `dist-msix-signed` Real.

### Phase H10 — F2 only (optional)

Gateway service, model proxy live, local mission execution, browser CU, project-code static parser msvc, Elder Wand fusion, companion CLI.

---

## 5. What stays from v1 (still correct)

| Item | Status |
|---|---|
| Ledger vocabulary Real/Substituted/DeferredApproved/Blocked | Keep |
| WPD-0005 C# SQLCipher storage | Keep |
| WPD-0006 no monolithic daemon **for F1** | Keep (with F2 revive path) |
| G2 parsers Real | Keep |
| CloudVault KAT Real; live C5 separate | Keep |
| Named-pipe peer auth Real | Keep |
| Phase 3 UI budget order of magnitude (hundreds of PRs for depth) | Keep as effort envelope, not % |
| Alberto cert/OAuth/VM still required for G5 | Keep |

---

## 6. Anti-false-green checklist (every PR)

- [ ] Does not claim Real without ledger fields (test + evidence + production paths)?
- [ ] No new ungated SampleData/DemoHost/Stub production default?
- [ ] Chat changes touch `IChatStreamDriver` composition, not only ConPTY spike?
- [ ] Settings pages for deferred servers show deferred, not “connected”?
- [ ] Mission Control copy says dispatch vs execute correctly?
- [ ] F1/F2 label on any “parity complete” language?
- [ ] `bash scripts/ci/verify-windows-parity-ledger.sh` green?

---

## 7. Immediate next actions (reordered, concrete)

1. **Decide F1 vs F2** (recommend F1; document if gateway is sacred).
2. **H0 honesty PR:** Insights sample gate + sample call-site audit.
3. **Alberto H1** in parallel (VM, cert, OAuth, CI).
4. **H3 design spike on paper:** stream-json → `ChatStreamEvent` mapping table from Mac `CLIBridge` events (implementation after VM ConPTY proof).
5. **Do not** start full Database/Projects visual ports before H0–H3 — routes-only IA-1 is OK early.
6. **Do not** mark Model Proxy Real under F1.

---

## 8. Success criteria

### F1 done when

1. All F1-in-scope ledger rows Real or DeferredApproved with revive triggers.
2. `nav-database` and `nav-projects` not Blocked (at least IA-1+IA-2/IA-4).
3. `nav-chat` Real with non-Unavailable default when CLI configured.
4. Zero silent sample data paths.
5. Settings: no Placeholder for S0–S2; S3b honest under F1.
6. R14-A + OAuth proven; R14-B residual documented if any.
7. Signed install + update evidence.
8. WPD-0006 DEFER list published in-app (Engine Room) so users aren’t surprised.

### F2 done when

F1 + gateway live + local mission execution + WPD-0003 parser + browser CU + fusion orchestration (or explicit residual list empty).

---

## 9. Residual uncertainty register (closed set)

| ID | Uncertainty | How we close it | Until then |
|---|---|---|---|
| U1 | Production App Check accepts vTPM EK or not | R14-B on physical box / policy from Firebase | R14-A only; cloud “prod certified” blocked |
| U2 | Pretext WebView2 metric drift magnitude | Corpus parity tests on Windows | Chat layout tolerance budget |
| U3 | Win2D 60fps on target ARM GPU | H2.7 measurement | Canvas fidelity may drop |
| U4 | main vs liquid-glass-kernel-reskin merge cost | Rebase early/often | Theme may lag data Real |
| U5 | Whether product owners need F2 gateway in year-1 | Explicit Alberto decision | F1 ships without Model Proxy live |
| U6 | High-risk DCC envelope (Signal/nonce) needs | Spike after OAuth | Export/revoke may stay partial |
| U7 | ViGEm/driver install friction for CU | G4 host pass | CU may ship mouse/keyboard-only first |
| U8 | Unknown Mac-only features not in ledger | Periodic `AgentLens/Views` inventory vs NavCatalog | Add ledger rows when found |

No other “unknown unknowns” are claimed closed; U8 is the process for discovery.

---

## 10. Relationship to other docs

| Doc | Role after v2 |
|---|---|
| `WINDOWS_PARITY_LEDGER.yml` | Still only status SoT |
| `WINDOWS_MACOS_PARITY_SCAN_2026-07-09.md` | Inventory useful; **§6–7 phases superseded by this file** |
| `PARITY_100_REMEDIATION_PLAN.md` | Historical; waves remapped to H0–H10 |
| `decisions/0006` | F1 architecture; F2 = fire revisit triggers intentionally |
| `ALBERTO_PARITY_CHECKLIST.md` | Still human gates; add F1/F2 decision |

---

## 11. Adversarial loop log

| Pass | Finding | Resolution |
|---|---|---|
| 1 | Full parity vs WPD-0006 DEFER | F1/F2 split |
| 2 | Chat = ConPTY false | C-Chat-1/2/3 layers |
| 3 | Settings bind-only | S0–S5 tiers; Model Proxy honest defer |
| 4 | Silent Insights sample | H0 mandatory |
| 5 | Database/Projects megaport | IA slices + WPD-0003 honesty |
| 6 | Mission execute vs dispatch | Language + F2 |
| 7 | vTPM = R14 done | R14-A/B |
| 8 | Fake % complete | Ledger metrics only |
| 9 | Wrong phase deps | DAG §3 |
| 10 | Branch divergence | U4 |
| 11 | Elder Wand fusion | F1 surface vs F2 orch |
| 12 | SessionLogSampleData scare | **Resolved H0:** renamed → `SessionLogEmptySource` |

**Stop condition for this loop:** every material contradiction between “peer parity,” WPDs, and code paths is either fixed in strategy or listed in §9. Residual U1–U8 remain **named**, not silently assumed closed.

---

*Strategy v2 is the plan to execute. Implementation starts at H0 + H1 decision, not at another inventory.*
