---
name: Safari Extension — Visibility Recovery, Efficiency, and Feature Completion
overview: The Safari web extension is fully built, signed, embedded, and registered — but invisible in Safari because an Aug 24 in-bundle daemon hot-patch broke the host app's code seal. Restore the seal, make the failure class impossible to repeat, land the parked native-bridge program so the extension actually connects, then cut its idle cost and finish its feature surface.
---

# Diagnosis (evidence-backed, 2026-08-29)

## Why it is not showing up in Safari

1. `/Applications/OpenBurnBar.app` (v1.0.40) **does contain** the extension:
   `Contents/PlugIns/OpenBurnBarSafariExtension.appex`, individually valid
   (`codesign --verify` clean), and registered with pluginkit as enabled:
   `pluginkit -m -p com.apple.Safari.web-extension` →
   `+ com.openburnbar.app.safari-extension(1.0.40)`. The dist inside matches
   `origin/main` byte-for-byte (`background.js` = 102836 B both sides).
2. The **host app fails deep signature verification**:
   `codesign --verify --deep --strict /Applications/OpenBurnBar.app` →
   *"a sealed resource is missing or invalid."*
   Safari refuses to surface extensions whose containing app fails signature
   validation, so it never reaches Settings → Extensions. That is the whole bug.
3. Root cause of the broken seal — exactly two files inside the bundle were
   modified after the Aug 20 15:52 signing:
   - `Contents/Helpers/OpenBurnBarDaemon` (replaced Aug 24 12:05, "streamfix",
     re-signed with the same team ID but not the host's seal)
   - `Contents/Helpers/OpenBurnBarDaemon.bak-pre-streamfix-20260824` (the
     original, left behind as an unsealed extra file)
4. Secondary gap (hits after visibility is restored): the appex handler on
   `main` is the deliberate stub (`SafariWebExtensionHandler.swift` answers
   `native_bridge_unavailable`), so the popup renders **disconnected** until the
   native-bridge program lands. The full bridge exists but is parked in open PRs:
   - #2354 `safari/native-bridge-rpc-20260819` — RPC surface + daemon handlers
     (~11k lines incl. 5 test files: RPC boundary, e2e, peer authz, session
     broker navigation, trust store loopback)
   - #2371 `safari/appex-entitlements-20260820` — App Group + Keychain Sharing
     for the appex (the required `OpenBurnBarSafariExtensionMAC_APP_DIRECT`
     profile is already in `~/Downloads/`)

## Scope charter

**In scope:** restore extension visibility; make seal-breaking impossible to
repeat; land the native bridge end-to-end; cut idle runtime cost; extend the
feature surface. **Non-goals:** Mac App Store lane changes beyond what #2371
needs; new extension permissions (the pinned set stands); iOS/Safari-on-iOS.

---

# Phase 0 — Immediate unblock (operational, no code)

**Option A (30 seconds, reverts the streamfix):**
```bash
cd /Applications/OpenBurnBar.app/Contents/Helpers
mv OpenBurnBarDaemon OpenBurnBarDaemon.streamfix-20260824
mv OpenBurnBarDaemon.bak-pre-streamfix-20260824 OpenBurnBarDaemon
codesign --verify --deep --strict /Applications/OpenBurnBar.app   # must be silent
```
Then launch OpenBurnBar once, restart Safari, and enable the extension in
Settings → Extensions.

**Option B (durable, recommended): rebuild and replace the app** from current
`origin/main` (v1.0.40+repair.34) with `scripts/build-macos-website-release.sh`,
which already signs the appex with its own entitlements/identifier before the
host and asserts `codesign --verify --deep --strict` plus peer signatures.
Main's daemon is newer than the Aug 24 streamfix, so nothing is lost. Use the
Developer ID identity + profiles already on this machine.

Decision: run Option A now to unblock, schedule Option B as the next release
build. Never re-hot-patch the bundle in the meantime.

# Phase 1 — Make this failure class impossible (durable guidance)

- `docs/SAFARI_EXTENSION.md` troubleshooting gains the entry: *"Extension not
  listed in Safari → run `codesign --verify --deep --strict` on the app; a
  broken seal hides every extension."*
- `AGENTS.md` / `CLAUDE.md`: prohibit modifying anything inside a signed
  `OpenBurnBar.app` bundle (binary swaps, `.bak` files, resource edits). Fixes
  ship through the release script, which exists precisely to sign nested code
  in the right order.
- Optional cheap tripwire: a preflight check in the app or a
  `scripts/verify-installed-app-seal.sh` one-liner for support/diagnostics.

# Phase 2 — Land the native bridge (feature completion)

Order (each is a reviewable coherent unit; the pair is a structured large lane):

1. Merge #2371 (appex App Group + Keychain Sharing entitlements). Profile is
   already downloaded; the website lane must locate it fail-closed like the
   other helpers.
2. Merge #2354 (native bridge RPC surface + daemon handlers + RPC canon).
3. New wiring PR: replace the stub in `OpenBurnBarSafariExtension/` with
   `BurnBarSafariNativeBridgeController`, embed via the existing appex target,
   keep the `native_bridge_unavailable` envelope as the degraded answer.
   Update `SafariProjectStructureTests` expectations accordingly.

Done when: popup shows **connected**, `hello`/`catalog`/`poll` cycle against
the real daemon works, Ask streams an answer end-to-end, and Watch/Agentic/
Handoff paths exercise their approvals.

# Phase 3 — Efficiency (evidence: code survey 2026-08-29)

1. **Idle poll cost.** Today: `pollOnce` → `bridge.poll()` through
   `runtime.sendNativeMessage` (one appex spin-up per message), cadence
   server-driven but clamped to [100 ms, 5 s], plus a 1-minute alarm heartbeat.
   Improvements, in order of value:
   - **Long-poll**: daemon holds `poll` open ~25 s when idle, returns instantly
     on a command. The 1-minute alarm stays (it is the service-worker
     keepalive; a pending native message is not). Cuts idle native round-trips
     ~10–50×. Touches the #2354 handler surface + the 5 s clamp ceiling.
   - **Port-based native messaging** (`runtime.connectNative`): verify Safari
     actually supports it for web-extension appexes on this OS
     (`WKWebExtensionMessagePort` exists in the SDK — confirm the JS surface),
     then replace per-message `sendNativeMessage` with one persistent port.
     Investigation task first; do not commit before the capability check.
2. **Ask stream rendering.** The 40 ms flush interval is right; verify
   `popup/render.ts` (1145 lines) applies transcript deltas incrementally
   instead of re-rendering the list per flush. Measure before changing.
3. **Screenshot pipeline.** `imagePipeline.ts` already resizes via
   OffscreenCanvas + JPEG. Add: skip the screenshot when the DOM-derived
   context suffices for the question (saves capture, base64, and upload), and
   adaptive quality/long-edge by answer need.
4. **Already good — keep:** on-demand content injection (activeTab +
   `scripting`, no `content_scripts` in the manifest), size budgets
   (90/90/70/300 KB), knip + dependency-cruiser gates, the service-worker
   DOM-free typecheck.

# Phase 4 — Feature surface (beyond the bridge)

- **Handoff mode**: the blocked-agent set (`droid`, `forge`, `kimi`, `junie`)
  is hardcoded — surface *why* an agent is blocked in the popup and make the
  set data-driven.
- **Usage-memory loop**: land the parked trio #2258 (permission pin),
  #2270 (usage observations → daemon spool), #2271 (honest popup copy).
- **Quick-Ask invocation**: keyboard shortcut / toolbar affordance. Verify
  Safari's MV3 `commands` support level before promising it; the popup-only
  path stays the fallback.
- **Certification lane**: #2235 external certification for release trust.

---

# Validation contracts (condensed VAL-*)

- **VAL-VIS-001** — Surface: browser. Needs: valid host seal. Behavior: Safari
  Settings → Extensions lists OpenBurnBar; enabling it shows the toolbar icon;
  the popup opens. Evidence: `codesign --verify --deep --strict` clean output +
  screenshot of the Extensions pane + popup screenshot.
- **VAL-SEAL-002** — Surface: cli. Behavior: rebuilt/replaced app passes deep
  verification with zero post-signing modifications; release-script peer
  signature assertions green. Evidence: command transcripts from the release
  build.
- **VAL-GUARD-003** — Surface: docs. Behavior: troubleshooting covers the
  seal check; AGENTS.md prohibits in-bundle edits. Evidence: doc diffs.
- **VAL-BRIDGE-001** — Surface: browser + job. Needs: #2371, #2354, wiring.
  Behavior: popup reports connected; Ask streams an answer end-to-end against
  the real daemon; Agentic command executes with approval; Watch narrates;
  Handoff hands the live tab off. Evidence: popup screenshots, transcript,
  `command_poll` performance counters.
- **VAL-BRIDGE-002** — Surface: browser. Behavior: daemon stopped →
  "OpenBurnBar is not running." and reconnect on next popup open. Evidence:
  screenshots before/after daemon stop/start.
- **VAL-POLL-003** — Surface: job. Needs: bridge landed. Behavior: idle
  `command_poll` round-trips drop ≥10× with no command pickup regression
  (p95 pickup ≤ 500 ms). Evidence: performance recorder metrics over a fixed
  idle window, before/after.
- **VAL-FEAT-004..006** — one per Phase 4 item, each with its real-surface
  evidence (popup UI, daemon spool state, shortcut firing in Safari).

# Task topology

| # | Task | Type | Depends on |
| --- | --- | --- | --- |
| W0 | Restore seal on installed app (Option A now, Option B at next release) | ops | — |
| W1 | Durable guard: docs + AGENTS.md + optional verify script | work | — |
| W2 | Land #2371 → #2354 → bridge wiring PR (structured large lane) | work | W0 for validation, not for code |
| W3 | Long-poll (+ Port investigation, capability-check first) | work | W2 |
| W4 | Popup incremental render + screenshot skip/adaptive quality (measure first) | work | independent of W3 |
| V1 | Real-surface lane: Safari on this machine, VAL-VIS/BRIDGE set | validate | W0, W2 |
| V2 | Scrutiny lane: extension `test:ci`, SafariProjectStructureTests, release assertions | validate | W2–W4 |
| G1 | Gate: visibility + seal + bridge e2e green | gate | V1, V2 |

# Risks / accepted decisions

- macOS 27 beta + Safari 27.0 on this machine may behave stricter than release
  OSes; validate here first, re-check on release OS.
- #2354 is large (~11k lines): ship as a structured large lane with review map
  per AGENTS.md; do not slice it into meaninglessness, do not mix goals.
- Port-based native messaging is *unverified capability* in Safari —
  investigation before commitment; long-poll is the guaranteed win.
- Option A temporarily reverts the Aug 24 streamfix daemon; accepted because
  main's daemon is newer and the next release build supersedes it.
