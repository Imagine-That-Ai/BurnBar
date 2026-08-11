# Linux/macOS parity: current candidate source audit

Date: 2026-08-11
macOS gold standard: OpenBurnBar for macOS
Audited implementation parent: `e8d51bd4be551e2399d7f64f6fdcd7b315a4e8c6`
Exact source candidate: the local commit containing this report
Branch: `codex/linux-macos-parity-completion-20260809`
Publication state: local only; not pushed, merged, signed, or promoted

## Executive summary

The Linux app is much closer to the macOS app than the strict parity ledger
looks. Most product code, packaging contracts, proof producers, hostile
mutation tests, and Linux-native fallbacks are already present. The complete
parity preflight passes **46/46**, and the focused registry, capability,
Fcitx5, pet, privacy, and shell-readiness packet passes **29/29**.

This candidate also closes the largest visible daily-use source gap found in
the previous audit: Linux now has a real AI Inbox and Founder Lens surface. It
uses daemon-authoritative read/unread, archive, snooze, feedback, filtering,
mark-all-read, item detail, discussion threads, accepted Founder Plans,
mission promotion, grading, telemetry, navigation, and Settings. The Linux
renderer does not invent durable state. The shared Swift contracts, daemon
SQLite store, RPC capability boundary, Rust/Tauri layer, strict TypeScript
codec, React store, UI, and tests all use the same contract.

The next daily-use gap is now source-closed as well. Linux chat and Inbox share
a bounded rich-content renderer for headings, lists, quotes, code, tables,
links, mentions, citations, and Hermes atoms without executing embedded HTML.
Chat now supports persistent conversation tabs, nested horizontal and vertical
splits, isolated controllers, per-pane backend/model/thinking state, keyboard
navigation, pointer and keyboard divider resizing, zoom, close/reopen, pane
move/swap, titles, colors, unseen completion state, and exact-pane native
notification focus. The one compatibility controller remains primary and is
re-homed safely when its pane closes.

The Linux Inbox now also closes the three daemon-authority gaps that were
deliberately disabled in the previous checkpoint:

- “Remember this” approves one canonical Inbox memory candidate.
- “Remember” turns one canonical Founder Plan step into approved memory and
  binds its durable memory ID.
- “Follow up” idempotently creates and binds a Mission Control follow-up.

All three actions reload canonical daemon state. The renderer cannot author
memory bodies, IDs, hashes, timestamps, or follow-up IDs. Memory goes through
the normal secret gate, quarantine, approval, approved-only export, and
reject/forget removal path. Retries reuse deterministic authority records and
do not replace unrelated approved memories.

The Inbox action loop now also preserves the exact target represented by each
action. Project actions select the one controller project whose authoritative
workspace metadata exactly matches the action path. Session and resume actions
select only a verified canonical conversation identity. Durable chat-thread
routes fetch and merge an exact thread even when it is outside the loaded rail.
All route inputs are typed, reload-safe, length-bounded, and reject duplicate
or unknown parameters, control characters, and path traversal.

The strict release result is still **0/40 product rows and 0/7 environments**.
That does not mean the implementation is empty. It means this exact candidate
has not yet been installed and exercised in the required Linux environments,
and several rows also need production cloud, physical-device, real-device,
signed-feed, or previous-release evidence.

The most important current distinction is:

- **Source and proof infrastructure:** advanced; most rows are ready for
  installed execution.
- **Estimated source implementation:** approximately **93%** of the scoped
  macOS parity outcome, with pet presentation depth and VM-found defects the
  clearest remaining source work.
- **Estimated end-to-end readiness:** approximately **74%**. This includes
  source/build confidence but discounts all unrun installed, environment,
  external-authority, and final-certification evidence.
- **Exact-candidate Linux proof:** not started for this candidate.
- **Full release certification:** blocked until all 40 rows and all seven
  environment rows pass.

The audit found and corrected four stale source-status statements:

1. The product said Fcitx5 was unavailable even though the candidate packages
   a native addon.
2. The pet document said P-30 proof ownership was not registered even though
   it is registered.
3. The privacy document said retention was unavailable even though the daemon,
   bridge, Settings UI, tests, and P-40 proof contract implement it.
4. The privacy document said account erasure was unavailable even though the
   daemon-owned trusted-device path, UI, redacted result decoder, and
   partial-failure retry behavior exist.

Those corrections do not mark any row certified. They make the app and audit
tell the truth about what is implemented and what still needs live proof.

This final clean pass also replaced renderer-level Inbox link opening with a
dedicated native command. Inbox links now require HTTPS, no credentials, the
default HTTPS port, and a remote DNS host. Localhost, IP literals, file URLs,
script URLs, custom ports, and malformed URLs are rejected. The existing
Stripe-only opener remains separate and unchanged.

## Evidence checked

- Complete parity preflight: **46 passed, 0 failed**, 413.83 seconds.
- Focused source packet: **29 passed, 0 failed**.
- Linux frontend: **123 test files, 1,167 tests passed**.
- Focused chat controller/workspace/surface/composer packet:
  **4 test files, 40 tests passed**.
- Rich-content renderer packet: **2 test files, 20 tests passed**.
- Focused Inbox/bridge/UI packet after native-link hardening:
  **4 test files, 109 tests passed**.
- Focused exact-target route/store/surface packet:
  **10 test files, 113 tests passed**.
- Linux TypeScript typecheck: passed.
- Linux ESLint gate: passed with zero warnings.
- Linux production Vite build and bundle verifier: passed.
- Adaptive foreground/contrast audit: **192/192** sampled skin/kernel/timeline
  states passed at **4.5:1 or better**, with no browser console errors.
- Rust/Tauri suite: **166 tests passed**, including native Inbox URL rejection
  of HTTP, credentials, custom ports, localhost, IP literals, file URLs, and
  script URLs.
- Shared Swift core Inbox/RPC packet: **21 tests passed**.
- Shared Swift daemon Inbox/socket/capability packet: **44 tests passed**.
- Generated RPC canon: **181 methods, no drift**.
- Product requirement inventory: exactly **P-01 through P-40**.
- Proof registry: **40/40** requirements have a validator, capture owner, and
  materializer.
- Support matrix: seven required environment rows.
- Parity ledger: `productParityClaim=false`, all 40 product rows blocked, all
  seven environment rows blocked.
- Candidate worktree: clean before this source-audit correction.
- Protected user stash: unchanged.

## Current parity matrix

“Source ready” means the implementation and proof owner exist. It does not mean
the feature passed in an installed Linux package.

| ID | Area | Current source verdict | What still blocks parity | Priority |
|---|---|---|---|---|
| P-01 | Release integrity | Packaging, manifests, signatures, verification, and lifecycle proof contracts exist | Build and exercise the exact signed candidate, compatible previous release, update feed, rollback, and data preservation | Critical |
| P-02 | Parity certification | Complete 40-row fail-closed ledger and proof ownership exist | Generate candidate-bound evidence and close every row without `allowBlocked` | Critical |
| P-03 | Installed runtime | Package-owned GUI, daemon, CLI, service, version, and uninstall paths exist | Fresh install, login start, crash/restart, suspend, upgrade, rollback, and uninstall on the current candidate | Critical |
| P-04 | Architecture reach | x86_64 and aarch64 workflows and architecture checks exist | Produce and run current-candidate artifacts on both architectures | Critical |
| P-05 | Credential custody | Secret Service, KWallet, and encrypted headless custody are implemented | Real locked/unlocked/missing/rotated/recovery behavior in every required environment | Critical |
| P-06 | Gateway credential boundary | Native gateway owns credentials and keeps them out of the renderer | Installed adversarial, reconnect, streaming, log, and diagnostics proof | Critical |
| P-07 | Computer Use | Browser authority, approval, panic, replay, audit, system portal input, and mobile approval source are broad | Production auth/App Check, physical-device approval, installed browser/system actions, Agent Watch breadth, panic, tamper, and restart proof | Critical |
| P-08 | Mercury media | Calls, files, capture, playback, consent, capability probing, and proof ownership are broad | Real paired-device file/call/share, codec fallback, portal consent, teardown, and compositor proof | Critical |
| P-09 | Navigation and shell | All primary routes include AI Inbox; bounded Inbox, project, workspace, session, conversation, and chat-thread routes load and focus exact authoritative targets, including targets outside the current list/filter | Current-candidate installed cold/warm routing, secondary-window, focus, multi-monitor, not-found recovery, and restore proof is open | High |
| P-10 | Dashboard layouts | Six layouts and their state handling exist | Installed visual matrix with real data, compact/wide sizes, themes, and restart persistence | Medium |
| P-11 | Usage ingestion | Canonical parser catalog, local ingestion, projections, recount, and provenance checks are broad | Real Linux corpus, remaining API/quota/cloud breadth, restart/recount, and same-input macOS comparison | High |
| P-12 | Quota | Quota read state, account slots, failover policy, reset, and provenance exist | Live exhausted/cooling/ready switching, alerts, restart, and cloud-account behavior | Medium |
| P-13 | Onboarding | Daemon-owned steps, provider setup, cloud-auth state machine, retry, privacy, and restart gates exist | Clean-profile installed flow, production OAuth, permission denial/retry, first data, and all environments | High |
| P-14 | Chat | Durable threads, streaming, models, attachments, citations, approvals, export, resume, reconnect, pop-out, sanitized rich content, persistent tabs, nested splits, isolated pane controllers, keyboard/drag/resize/zoom, unseen completion, and exact-pane notification focus are implemented | Installed provider breadth, binary/media behavior, unloaded history, restart re-upload, persisted workspace restoration, accessibility, performance, and recovery proof remain | High |
| P-15 | Account and billing | PKCE, membership state, portal routing, export, erasure handoff, and safe URLs exist | Production OAuth/App Check, membership, checkout/portal, recovery, erasure, and exact-candidate proof | High |
| P-16 | Cloud and devices | Encrypted replica, sync, conflict handling, remote read, escrow, and trusted-device controls exist | Production callable execution, two-device approval/revoke, conflict/recovery, and signed installed proof | High |
| P-17 | Activity and session logs | Search, detail, body, replay, resume, export, and source-resolution safety exist | Populated real history, complete-history proof, provider runtime, restart, and installed UI proof | High |
| P-18 | Memory review | Pending/approve/reject/forget, quarantine feed, tombstones, and audit hashes exist; Linux can approve one canonical Inbox candidate and remember one Founder Plan step through daemon authority without replacing unrelated exports | Installed persistence, normal-recall exclusion, cross-device replication, and cloud authority remain | High |
| P-19 | Projects | CRUD, associations, delete/reassign, migration, tombstones, and replay protection exist | Real populated migration, restart, collision, deletion, and installed proof | Medium |
| P-20 | Missions | Create, approve, answer, cancel, detail, evidence, history, and health exist | Installed full lifecycle through restart/reconnect with real integrations | Medium |
| P-21 | Insights | Canvas, widgets, citations, compare, follow-up, audit, and stale-response fencing exist | Real ledger data, macOS qualitative comparison, restart/reconnect, and installed evidence | Medium |
| P-22 | Database | Inspect/search, snapshots, watch, recovery bundles, native pickers, and integrity checks exist | Populated SQLCipher database, native keyring, corruption/key-loss/device-transfer, performance, and installed proof | Medium |
| P-23 | Provider/model workspace | Catalog, health, aliases, variants, routing, failover, custom models, and deep links exist | Real credentials, multi-slot failover, degraded states, restart, and installed matrix | Medium |
| P-24 | Settings | Searchable tabs now include AI Inbox scheduling, budget, egress, run-now, telemetry, and honest capability states; selected writes use daemon readback | Execute the AI Inbox settings against an installed daemon, then cover all supported writes, unavailable states, restart, accessibility, and restoration in the VM matrix | Medium |
| P-25 | Updates | Signed-feed checks and installed update/rollback proof contracts exist | Compatible previous package, valid feed history, exact update/rollback, restart, and data preservation | High |
| P-26 | Tray and native shell | Native tray routes, health, usage, updates, reconnect, autostart, and background mode exist | GNOME/KDE/wlroots tray behavior, DBusMenu actions, accessibility, login start, relaunch, and restoration | High |
| P-27 | Notifications and deep links | Native actions, queued cold-start routes, OAuth return validation, and deep-link safety exist | Real notification hosts, WebDriver/AT-SPI actions, login start, persistence, accessibility, and all environments | High |
| P-28 | SmartHub | Typed allowlisted discovery/status/control and bounded CLI execution exist | Supported real devices, Avahi, offline/reconnect, daemon restart, hostile input, and installed proof | High |
| P-29 | Text expansion | Encrypted snippets, consent, IBus, native Fcitx5 addon, separate signed identities, secure-field denial, lifecycle, and proof ownership exist | Real Secret Service/KWallet, IBus/Fcitx5 registration and expansion, secure fields, cancellation, restart, sync/conflicts, and desktop matrix | High |
| P-30 | Pet companion | X11 child, Wayland contained fallback, summon, click-through controls, movement, chat, file drop, 114-entry catalog, GLB/atlas rendering, and proof ownership exist | Exact-candidate compositor/GPU/focus/scaling/restart proof; macOS offscreen 3D thumbnails and persona/local-floor behavior remain thinner | High |
| P-31 | Accessibility | Axe, keyboard, reduced motion, forced colors, focus, AT-SPI/Orca proof contracts exist | Exact-candidate keyboard/Orca/AT-SPI/200%/contrast/reduced-motion matrix in all environments | High |
| P-32 | Performance | Matched workload, latency/resource budgets, and candidate-bound proof exist | Current-candidate matched macOS/Linux startup, route, IPC, tray, memory, CPU, GPU, and soak results on comparable hardware | High |
| P-33 | Reliability | Crash/restart, stale-response, reconnect, subscription, and restoration proof contracts exist | Long idle/suspend, daemon loss, portal/keyring faults, migration faults, multi-hour soak, and all environments | High |
| P-34 | Security hardening | Native URL, secret, process, renderer, fixture, package, and proof boundaries are broad; Inbox external links now use a separate native HTTPS-only remote-host validator without widening the Stripe allowlist | Installed hostile-input, secret-leak, permission, symlink, replay, tamper, unsigned/substituted package, diagnostics, and browser-open proof | Critical |
| P-35 | Diagnostics and support | Redacted metadata export, native save, reconnect, package/runtime facts, and proof owner exist | Exact bundle contents, cancellation, permissions, offline/reconnect, restart, accessibility, and environment proof | Medium |
| P-36 | Visual and interaction polish | Shared components, stable readiness selectors, responsive states, themes, keyboard menus, and screenshot harness exist | Current-candidate screenshot/AT-SPI baselines at required sizes, themes, motion states, overflow, GPU fallbacks, and desktop environments | Medium |
| P-37 | Linux matrix | Environment-bound proof harness exists for all seven required rows | Run Ubuntu GNOME X11/Wayland on both architectures, Fedora KDE Wayland on both, and Arch Sway x86_64 | Critical |
| P-38 | CI and release automation | Fail-closed build, package, sign, aggregate, proof, and promotion workflows exist | Run the exact candidate through hosted architecture lanes, signing, assembly, evidence closure, and promotion gates | Critical |
| P-39 | Cross-platform differential proof | Same-contract comparator, redaction, duplicate-key rejection, volatile paths, and path-level diffs exist | Generate same-commit macOS and Linux artifacts from the same corpus and close every unexpected difference | High |
| P-40 | Data and privacy | Consent, inventory, local delete, encrypted export, retention, cloud export, account erasure, partial retry, and recovery-bundle controls exist | Current-candidate installed RPC/UI proof, trusted-device backend receipts, locked keyring, recovery propagation, unrelated-data preservation, and all environments | High |

## Meaningful gaps by type

### Functionality

- P-07 still needs full real-device Browser/System Computer Use certification
  and thinner Agent Watch behavior compared with macOS.
- P-08 still needs real paired-device media outcomes.
- P-14 still needs installed provider, attachment, restored-workspace,
  accessibility, and performance breadth.
- P-30 still has a visible source-level polish gap around macOS-style offscreen
  3D thumbnails and persona/local-floor behavior.
- P-40 still needs backend and cross-device proof for destructive cloud and
  recovery outcomes.

### UI and UX

- Current-candidate screenshots and AT-SPI states have not been captured.
- Secondary-window and multi-monitor behavior are thinner than macOS.
- Pet library thumbnails are not yet at the macOS offscreen 3D standard.
- Native desktop behavior must stay Linux-appropriate: portals on Wayland,
  AppIndicator/DBusMenu where available, native package-manager updates, and
  clear contained fallbacks where a compositor cannot safely match macOS.

### Performance and reliability

- Historical performance results are encouraging, but they do not prove this
  exact candidate.
- Current-candidate startup, route latency, IPC, tray, memory, CPU/GPU, long
  idle, suspend, daemon crash, keyring lock, portal denial, and upgrade/rollback
  still need live execution.

### Accessibility

- Source automation is broad, but the current candidate needs real AT-SPI,
  Orca, keyboard-only, 200% scaling, contrast, reduced-motion, and focus
  restoration proof in each required desktop/session.

### Platform integrations

- IBus and Fcitx5 are now both represented honestly in source and packaging.
- Tray, notifications, portals, autostart, secret stores, package managers,
  SmartHub discovery, PipeWire/GStreamer, and desktop deep links still require
  environment-specific live proof.

### Overall polish

- The codebase has strong fail-closed behavior and unusually complete proof
  infrastructure.
- The remaining polish risk is concentrated in installed visual behavior,
  compositor differences, real data/devices, recovery states, and exact package
  lifecycle—not in basic route scaffolding.

## Detailed gap register

The 40-row matrix above is the complete release scope. The gaps below are the
directly observed product differences that still require engineering or live
proof. Each item states the permanent fix and how QA should close it.

### G-01 — AI Inbox memory-candidate approval — source closed

- **Difference:** The previous Linux checkpoint showed the same proposal but
  kept “Remember this” disabled. The current source now routes one canonical
  proposal through the normal quarantine-first memory authority.
- **Why it matters:** memory is a trust boundary. Using the existing Linux
  `inboxMemoryExport` call as a shortcut would replace the complete approved
  export set and could revoke unrelated approved entries by omission.
- **Recommended solution:** implemented as daemon-authoritative
  `daemon.inbox.memory_candidate.approve`, keyed by item fingerprint and
  candidate ID. It creates or reuses a quarantined authority record, runs the
  secret gate, writes provenance and audit events, approves only that record,
  upserts only its approved export, and returns the canonical memory ID.
- **Priority:** High.
- **Implementation notes:** reuse the same authority and audit path as
  `InboxMemoryApprovalHandler`; do not let the renderer provide approval
  timestamps, memory IDs, hashes, or an entire replacement set. Make retries
  idempotent by candidate provenance.
- **QA verification:** local authority, socket, retry, secret-rejection, export
  isolation, and reject/forget tests pass. Installed QA must approve one
  proposal; prove quarantine precedes
  approval; verify normal recall includes it only after approval; retry the
  same request; inject a secret and prove rejection; interrupt between
  quarantine and approval and prove no unapproved fact enters recall; verify
  unrelated approved memories remain unchanged; restart and repeat readback.

### G-02 — Founder Plan “Remember” — source closed

- **Difference:** The previous Linux checkpoint kept “Remember” disabled. The
  current source turns an accepted Founder Plan step into approved memory and
  binds the returned canonical memory ID to the plan step.
- **Why it matters:** Founder Plans are meant to become durable operating
  knowledge. A visual control without the same authority would either lose the
  memory or bypass the memory safety model.
- **Recommended solution:** implemented as a daemon-owned recoverable saga that
  creates the plan-derived quarantined memory, approves it, exports the
  refreshed approved set, and binds the canonical memory ID to the step.
- **Priority:** High.
- **Implementation notes:** preserve provenance
  `ai-inbox:plan:<planID>:step:<stepID>`, deduplicate retries, and define
  rollback/recovery when memory approval succeeds but plan binding fails.
- **QA verification:** local migration, binding, authority, retry, and
  production-socket tests pass. Installed QA must remember a step; prove exact
  provenance and audit
  ordering; retry; restart; verify plan readback contains the memory ID; prove
  the memory appears in normal recall; simulate binding failure and verify a
  repairable, non-duplicated state.

### G-03 — Founder Plan follow-up creation — source closed

- **Difference:** The previous Linux checkpoint could bind an existing
  `followupID` but could not create one. The current source creates the
  canonical follow-up and binds it to the step.
- **Why it matters:** the accepted plan loop is incomplete when a user cannot
  turn a step into a scheduled follow-up.
- **Recommended solution:** implemented as daemon-authoritative follow-up creation from
  a plan step, return the canonical follow-up ID, and bind it atomically or
  through an idempotent saga.
- **Priority:** High.
- **Implementation notes:** require project attribution and an explicit due
  date/default policy; never invent an ID in the renderer. Reuse the existing
  follow-up store and notification scheduling path.
- **QA verification:** local production-socket creation and retry tests pass.
  Installed QA must create a follow-up; verify project, title, body, due
  date, notification, and plan binding; double-click/retry; restart; cancel;
  simulate create-success/bind-failure and verify recovery without duplicates.

### G-04 — Exact-target Inbox actions — source closed

- **Difference:** macOS opens the exact session log, conversation, or project
  represented by an Inbox action. The current Linux source now does the same
  through typed, reload-safe exact-target route contracts.
- **Why it matters:** the user can lose the context that made the Inbox item
  actionable, especially in a large project or activity history.
- **Recommended solution:** implemented typed, bounded route-selection
  contracts for project, workspace, session, conversation, and chat-thread
  targets. Destination stores validate the target, load it outside the current
  page/filter when the daemon can prove identity, select it, and show a
  recoverable not-found or ambiguity state.
- **Priority:** High.
- **Implementation notes:** route parsing accepts exactly one allowed target
  parameter, rejects duplicates, unknown keys, empty/trimmed/control/replacement
  characters, oversized values, and workspace traversal. Workspace selection
  uses only explicit authoritative controller metadata; it never opens a path
  from the renderer or infers identity from a basename/title. Conversation
  selection requires `sourceIDVerified === true`; repeated same-target
  navigation increments a route revision so focus and selection retrigger.
- **QA verification:** the focused route/store/surface packet passes
  **113/113** and covers warm/cold route parsing, repeated navigation,
  outside-page exact loading, ambiguity, missing/incomplete history, hostile
  input, authoritative workspace matching, and exact chat-thread merge. Installed
  QA must still exercise warm and cold native entry, restart restoration,
  notification/deep-link entry, keyboard focus, and missing/deleted recovery.

### G-05 — Rich chat and Inbox content rendering — source closed; installed proof open

- **Difference:** macOS has tiled/tabbed multi-pane chat workspaces and rich
  technical content. Linux now implements the same outcomes with Linux-native
  tabs, nested splits, drag/drop, keyboard resizing/navigation, pane options,
  unseen completion state, and a shared bounded rich-content renderer.
- **Why it matters:** long technical conversations and evidence-heavy Inbox
  items can now be scanned, compared, copied, and acted on without flattening
  their structure or forcing one active transcript.
- **Recommended solution:** implemented shared sanitized content rendering for
  chat and Inbox plus a persistent workspace model with exactly one primary
  compatibility controller and isolated secondary controllers.
- **Priority:** High.
- **Implementation notes:** the renderer never injects supplied HTML. Workspace
  persistence is versioned, validates depth/count/IDs/metadata, repairs
  malformed primary ownership, clamps split fractions, and keeps layout data
  separate from daemon-owned messages. Same-thread concurrent sends fail
  before append/gateway, stale async results are fenced by controller
  generation, and closing a primary pane re-homes the compatibility controller.
- **QA verification:** local rich-content coverage passes **20/20** and the
  focused chat packet passes **40/40**, including controller isolation, split,
  resize, zoom, tab close/reopen, exact-pane drop, atomic pane swap,
  accessibility semantics, notification targeting, export, deep links, and
  streaming regressions. Installed QA must still exercise restart persistence,
  real providers, pop-out/rejoin, Orca order, reduced motion, 200% scaling,
  large-history scrolling, and CPU/RSS behavior.

### G-06 — AI Inbox list hierarchy — source closed; visual proof open

- **Difference:** macOS groups active items into attention/today/earlier
  sections and has platform-native SwiftUI hierarchy. Linux now groups active
  rows into Attention, Today, and Earlier, and resolved/archived rows into
  Closed, while preserving daemon order and filter semantics.
- **Why it matters:** sectioning improves scan speed when the Inbox becomes
  large. The source hierarchy is now present, but it has not yet been visually
  compared against the gold standard with real populated installed data.
- **Recommended solution:** the deterministic recency/attention sectioning is
  implemented. Tune density, selection, empty/error states, and responsive
  collapse only from installed macOS/Linux screenshot comparison.
- **Priority:** Medium.
- **Implementation notes:** section only client-visible rows; do not duplicate
  server ranking or derive durable status. Preserve semantic headings and
  virtualize if the configured item cap grows.
- **QA verification:** capture empty, one-item, dense, attention-heavy,
  archived, resolved, loading, error, and retry states at compact/standard/wide
  sizes; test keyboard movement across section boundaries, Orca announcements,
  200% scaling, forced colors, and long localized strings.

### G-07 — Pet companion presentation depth

- **Difference:** Linux implements the X11 child window, Wayland-contained
  fallback, click-through controls, movement, chat, file drop, catalog, GLB,
  and atlas rendering. macOS still has richer offscreen 3D thumbnails and
  thinner persona/local-floor differences remain on Linux.
- **Why it matters:** the pet is a visible delight surface; weak thumbnails or
  movement grounding make the Linux app feel like a port even when the core
  behavior works.
- **Recommended solution:** bring the offscreen render pipeline, persona
  behavior, local-floor grounding, animation state, and thumbnail cache to the
  Linux renderer with compositor-specific fallbacks.
- **Priority:** Medium.
- **Implementation notes:** keep X11 and Wayland ownership separate, cap GPU
  work, cache thumbnails by asset/version/theme, and retain the contained
  fallback where global transparent click-through is not safe.
- **QA verification:** test every asset family, missing/corrupt assets,
  multi-monitor coordinates, fractional scaling, focus, drag/drop,
  summon/dismiss, restart, GPU fallback, Wayland containment, X11
  click-through, CPU/GPU/RSS budgets, and screenshot comparison.

### G-08 — Exact-candidate installed proof

- **Difference:** source, local unit/integration tests, packaging contracts, and
  proof producers are advanced, but the exact commit containing this report has
  not yet been built, installed, and exercised on X31.
- **Why it matters:** source-green does not prove package ownership, native
  libraries, desktop integration, GPU/compositor behavior, keyrings, portals,
  accessibility, process lifecycle, or visible UX.
- **Recommended solution:** build and install only the exact local commit on
  X31 Ubuntu 24.04 GNOME X11 aarch64, record artifact/package digests, then run
  the installed smoke and high-risk native rows before accepting any source
  verdict as runtime proof.
- **Priority:** Critical.
- **Implementation notes:** first confirm the prior guest build has exited;
  preserve VM state; bind every receipt to commit, version, architecture,
  package digest, desktop/session, and capture time; do not reuse historical
  screenshots or installed binaries.
- **QA verification:** verify package ownership and process paths; launch every
  primary route; exercise Inbox read/archive/snooze/feedback/settings/link
  opening; run tray, notification, login-start, restart, suspend, keyring,
  accessibility, pet, text-expansion, diagnostics, and cleanup checks; capture
  logs, screenshots, AT-SPI, hashes, and restoration evidence.

### G-09 — Seven-environment and external-authority certification

- **Difference:** macOS is the gold standard and Linux has one authorized VM
  available, but strict parity requires 40 product rows across seven Linux
  environments plus external cloud, billing, update-feed, physical-device, and
  paired-media proof where the row requires it.
- **Why it matters:** GNOME X11 success cannot prove GNOME Wayland, KDE,
  wlroots/Sway, x86_64, aarch64, production OAuth/App Check, Stripe, trusted
  devices, media peers, or update/rollback.
- **Recommended solution:** close the matrix in risk order using the
  fail-closed evidence registry; obtain separate exact approval before any
  billable/provider/production action; run same-commit macOS/Linux differential
  proof only after the installed environments are stable.
- **Priority:** Critical.
- **Implementation notes:** keep source implementation, local tests, one-VM
  proof, external authority, and final certification as separate ledgers. Never
  convert `BLOCKED` or `NOT_RUN` into pass and never use `allowBlocked` for
  promotion.
- **QA verification:** all required evidence closures validate against the same
  signed candidate and package digests; every mandatory row is ready; all
  seven environment rows are ready; production/device receipts identify the
  exact action; the same-commit differential has no unexplained difference;
  only then generate `productParityClaim=true`.

## Linux parity implementation plan

### 1. Seal the current source candidate

Engineering tasks:

- Finish the AI Inbox shared contracts, daemon presentation store/RPCs,
  Rust/Tauri bridge, strict codecs, renderer store, UI, Settings, navigation,
  and native safe-link opening.
- Finish the shared rich-content renderer and the persistent Linux-native chat
  tab/split workspace with isolated controllers and exact-pane notifications.
- Keep memory/follow-up authority daemon-owned and visibly report pending,
  success, unavailable, and failure states.
- Update the parity report with the exact source gaps and implementation order.
- Run frontend, type, lint, production build, Rust, Swift, canon, suppression,
  and diff-hygiene checks.
- Keep `productParityClaim=false`.
- Commit locally without pushing or merging.

Dependencies:

- None beyond the clean candidate worktree.

Acceptance criteria:

- AI Inbox state is daemon-authoritative across restart-capable RPCs.
- Active, Needs attention, Resolved, and Archived are real server filters.
- Read/unread, archive/unarchive, snooze/clear, feedback/clear, and
  mark-all-read return canonical daemon readback.
- Founder Lens discussion, accepted plans, grading, and mission promotion work.
- Unsupported actions never claim success.
- Inbox URLs open only through the dedicated native validator.
- Rich content is bounded and inert, workspace state repairs malformed
  persistence, and pane operations preserve exactly one primary controller.
- All relevant local checks pass and the worktree is clean after the local
  commit.

### 2. Prepare the exact X31 VM candidate

Engineering tasks:

- Confirm the X31 VM identity, architecture, desktop, session, free space, and
  package prerequisites.
- Build or transfer only artifacts bound to the exact candidate HEAD.
- Record source HEAD, package digest, manifest digest, version, architecture,
  and build/run IDs before installation.
- Do not reuse a historical installed package as current proof.

Dependencies:

- Step 1 committed.
- X31 storage and VM attached.

Acceptance criteria:

- Candidate identity is recorded before install.
- Package bytes and manifests are hashed.
- Existing VM/user state is inventoried and recoverable.
- No unrelated host or VM process is disrupted.

### 3. Run the first installed smoke and native shell gate

Engineering tasks:

- Install the exact candidate.
- Prove one package-owned daemon, CLI, GUI, and service.
- Exercise launch, relaunch, login start, deep links, tray, notifications,
  Settings, onboarding, Support, accessibility tree, and basic recovery.
- Capture screenshots, AT-SPI, logs, package ownership, process identity, and
  restoration.

Dependencies:

- Step 2.

Acceptance criteria:

- No blank window, crash loop, stale binary, duplicate daemon, or wrong version.
- All primary routes load from the installed package.
- Honest unavailable/degraded states appear when a dependency is missing.
- VM state is restored after the proof lane.

### 4. Execute high-risk native product rows

Recommended order:

1. P-05/P-34 secret and security boundaries.
2. P-29 IBus/Fcitx5 text expansion and secure fields.
3. P-30 pet X11/Wayland behavior.
4. P-31 accessibility.
5. P-32/P-33 performance and reliability.
6. P-40 privacy retention/export/delete/recovery.
7. P-07/P-08 Computer Use and Mercury.

Dependencies:

- Stable installed smoke.
- Required local secret store, portal, media, and input-method packages.
- Physical trusted device for P-07/P-08/P-16/P-40 external authorization.

Acceptance criteria:

- Every feature is proven from the installed app, not a fixture or source scan.
- Every destructive or permission-sensitive flow has cancel, deny, partial
  failure, retry, restart, and restoration evidence.
- Unsupported compositor behavior stays visibly unavailable or contained.

### 5. Execute core product rows with real data

Engineering tasks:

- Usage, quota, onboarding, chat, account, cloud, Activity, memory, projects,
  missions, insights, database, providers, Settings, updates, tray,
  notifications, SmartHub, diagnostics, and visual polish.
- Use bounded real test data and restore the original state.
- Compare outcomes with the macOS gold standard.

Dependencies:

- Stable daemon/database/secret store.
- Production or approved staging authority where a row requires cloud data.
- Compatible previous package for update/rollback.
- Supported SmartHub devices where P-28 is claimed.

Acceptance criteria:

- No synthetic production state.
- Exact readback after mutations.
- Restart persistence and stale-response safety.
- Clear macOS-equivalent outcome or an explicit Linux-native substitute.

### 6. Close external and production dependencies

Engineering tasks:

- Production OAuth/App Check/Firebase callable execution.
- Stripe membership/portal lifecycle.
- Physical-device approval and two-device cloud/media flows.
- Real SmartHub devices.
- Valid signed update feed and previous release.

Dependencies:

- Separate exact approval before billable cloud/provider changes.
- Physical device availability.
- Release signing and distribution secrets.

Acceptance criteria:

- Backend receipts bind to the exact candidate and exact user-approved action.
- No credential, token, action proof, or private payload enters renderer state,
  logs, diagnostics, or proof artifacts.
- Partial backend failure remains retryable and is never reported as success.

### 7. Run all seven Linux environments

Required order:

1. Ubuntu 24.04 GNOME X11 x86_64.
2. Ubuntu 24.04 GNOME X11 aarch64.
3. Ubuntu 24.04 GNOME Wayland x86_64.
4. Ubuntu 24.04 GNOME Wayland aarch64.
5. Fedora KDE Wayland x86_64.
6. Fedora KDE Wayland aarch64.
7. Arch Sway/wlroots Wayland x86_64.

Acceptance criteria:

- All mandatory P rows meet their required evidence tier.
- No environment uses `allowBlocked`.
- All evidence matches the exact HEAD and package digest.
- Installation, runtime, accessibility, performance, reliability, cleanup, and
  restoration pass in every row.

### 8. Same-commit macOS/Linux differential and release seal

Engineering tasks:

- Build macOS and Linux from the same commit.
- Run the canonical shared corpus and behavior contract.
- Review every normalized difference.
- Generate final product closures and parity ledger.
- Keep promotion blocked until every required closure is valid.

Dependencies:

- Steps 1 through 7.

Acceptance criteria:

- P-01 through P-40 are ready.
- All seven environments are ready.
- `productParityClaim=true` is generated only by the validated closure path.
- The exact signed artifacts, public feed, release notes, and rollback path
  agree on version, commit, architecture, and digest.

## Prioritized roadmap

| Order | Work | Why now | Exit condition |
|---|---|---|---|
| 1 | Seal and locally commit the Inbox plus rich-chat/workspace source slice | Makes the latest daily-use source additions exact, reviewable, and candidate-bound | Full local gates green; clean local commit; no push or merge |
| 2 | Start X31 VM and identify the exact environment | Converts source confidence into real installed evidence | VM identity and prerequisites recorded |
| 3 | Build/install exact candidate and run smoke, including AI Inbox | Finds package/runtime blockers before expensive deep testing | Stable GUI/daemon/CLI/service, all primary routes, durable Inbox state, and native safe links |
| 4 | Text expansion, pet, privacy, accessibility | These are Linux-native/high-risk and recently changed | P-29/P-30/P-31/P-40 installed receipts or named defects |
| 5 | Core product workflows, including exact-target actions | Proves daily-use parity with real state | Installed row receipts, exact project/session/conversation selection, and fixed defects |
| 6 | Memory approval and follow-up authority | Completes the Founder Lens operating loop without bypassing trust boundaries | Candidate/plan memory and follow-up flows are daemon-authoritative, idempotent, and restart-safe |
| 7 | Pet presentation depth and VM-found source defects | Closes the clearest known remaining source polish gap and any real installed regressions | Pet visual comparison green; every reproducible X31 defect fixed and retested |
| 8 | Computer Use, media, cloud, billing, devices | Requires external authority and physical systems | Exact backend/device receipts |
| 9 | Performance, reliability, update/rollback | Requires a stable candidate and previous release | Budgets, soak, fault, and lifecycle green |
| 10 | Remaining six environments | Closes architecture/compositor portability | 7/7 environments ready |
| 11 | Same-commit macOS comparison and seal | Final independent parity decision | 40/40, 7/7, signed closure |

## QA checklist

### Candidate identity

- [ ] Record exact HEAD, version, branch, artifact digest, manifest digest, run
  ID, architecture, desktop, session, and package type.
- [ ] Confirm no source, package, or evidence substitution.
- [ ] Confirm all captured evidence is newer than installation and bound to the
  same candidate.

### Installation and lifecycle

- [ ] Fresh install.
- [ ] Upgrade from a compatible previous version.
- [ ] Rollback.
- [ ] Uninstall.
- [ ] Login start and tray-first background start.
- [ ] Crash and daemon restart.
- [ ] Suspend/resume and logout/login.
- [ ] No duplicate daemon or stale/deleted binary.
- [ ] Data preserved where required.

### Core UX

- [ ] Every primary route loads with real state.
- [ ] Loading, empty, populated, offline, error, retry, and restored states.
- [ ] Keyboard-only operation and visible focus.
- [ ] Deep links, secondary windows, focus restoration, and multi-monitor.
- [ ] Compact, standard, wide, light, dark, reduced-motion, high-contrast, and
  200% scaling.
- [ ] No clipping, overlap, blank render, fake success, or stale state.

### Native Linux integration

- [ ] Secret Service and KWallet locked/unlocked/missing/rotated.
- [ ] GNOME/KDE/wlroots tray and notifications.
- [ ] Wayland portal grant/deny/cancel/revoke/restart.
- [ ] X11 safe fallback behavior.
- [ ] IBus and Fcitx5 registration, expansion, secure fields, restart, cleanup.
- [ ] PipeWire/GStreamer capture/playback and codec fallback.
- [ ] Native save/open pickers and cancellation.
- [ ] Autostart, package manager, desktop files, MIME/deep-link handlers.

### Data and security

- [ ] No secrets or tokens in renderer state, logs, screenshots, diagnostics, or
  proof JSON.
- [ ] Symlink, traversal, unsafe owner/permission, replay, stale identity,
  tamper, and oversized-input rejection.
- [ ] Exact readback after every mutation.
- [ ] Destructive actions require exact confirmation and approved authority.
- [ ] Partial destructive failure is not reported as success.
- [ ] Unrelated data remains intact.
- [ ] Cleanup restores services, processes, files, policies, and user state.

### Product workflows

- [ ] AI Inbox filters, item deep links, read/unread, archive, snooze,
  feedback, mark-all-read, settings, telemetry, discussion, plans, grading,
  mission promotion, memory-candidate approval, plan-step memory, follow-up
  creation, and safe external links.
- [ ] Memory approval proves quarantine-before-approval, secret rejection,
  retry idempotency, reject/forget revocation, restart persistence, and
  unrelated-memory preservation.
- [ ] Usage and quota.
- [ ] Onboarding and provider credentials.
- [ ] Chat, attachments, citations, approvals, export, resume, and pop-out.
- [ ] Rich headings/lists/quotes/tables/code/links/mentions/atoms remain inert,
  readable, copyable, and safe under malformed or hostile content.
- [ ] Chat tabs, horizontal/vertical splits, drag/drop, keyboard resize,
  keyboard pane/tab movement, zoom, close/reopen, move/swap, titles, colors,
  unseen completion, exact-pane notifications, restart persistence, and
  primary-controller re-homing.
- [ ] Account, billing, cloud sync, trusted devices, export, and erasure.
- [ ] Activity, memory, projects, missions, insights, and database.
- [ ] Providers/models, Settings, updates, tray, notifications, and support.
- [ ] Computer Use, Mercury, SmartHub, text expansion, and pet companion.

### Accessibility

- [ ] Axe/static semantic checks.
- [ ] Real AT-SPI tree.
- [ ] Orca traversal and announcements.
- [ ] Keyboard-only workflows.
- [ ] Focus entry, movement, trapping where appropriate, and restoration.
- [ ] 200% scaling.
- [ ] Reduced motion, forced colors, and contrast.
- [ ] Native tray/notification/dialog accessibility.

### Performance and reliability

- [ ] Cold and warm startup.
- [ ] Route navigation p50/p95/p99.
- [ ] IPC and daemon response p50/p95/p99.
- [ ] Tray open and notification action latency.
- [ ] CPU, RSS, GPU, file descriptors, and process count.
- [ ] Long idle and multi-hour soak.
- [ ] Offline/reconnect, daemon crash, portal loss, keyring lock, database
  corruption, and interrupted update.
- [ ] No unbounded retries, hangs, deadlocks, or stale response overwrite.

### Final release gate

- [ ] P-01 through P-40 ready.
- [ ] Seven of seven environments ready.
- [ ] Same-commit macOS/Linux differential reviewed.
- [ ] Signed artifacts and feed match exact digests.
- [ ] Rollback path proven.
- [ ] Documentation describes only proven behavior.
- [ ] `productParityClaim=true` generated by the validated closure path.

## Current conclusion

The Linux implementation is in the final source-gap, proof, and defect-fixing
phase, not the early build phase. AI Inbox memory authority, follow-up creation,
list hierarchy, exact-target actions, rich content, and the chat tab/split
workspace are source closed. Pet presentation depth is the clearest known
source gap. The exact candidate still needs a local commit and an installed
X31 build. The VM may find real defects, and those defects must be fixed before
any percentage or “full parity” claim is treated as release truth. Even a clean
X31 result will be one-environment proof, not the final 40/40 and 7/7
certification.
