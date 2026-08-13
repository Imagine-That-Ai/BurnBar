# Safari Extension QA

This checklist certifies OpenBurnBar's Safari surface against the exact
candidate being considered for release. It covers automated contracts, a real
Safari session, safety behavior, accessibility, performance, and both macOS
distribution channels.

## Result header

Record this before testing:

| Field | Value |
|---|---|
| Commit SHA | |
| Branch/tag | |
| Marketing/build version | |
| macOS version/build | |
| Safari version/build | |
| Mac model/architecture | |
| Distribution | source / Developer ID DMG / MAS archive-export |
| App SHA-256 | |
| DMG/PKG SHA-256 | |
| Extension bundle ID | `com.openburnbar.app.safari-extension` |
| Tester/date | |

## Automated preflight

All commands must pass from the exact candidate:

```bash
./scripts/test-openburnbar-safari-extension.sh
node --test scripts/ci/classify-ci-impact.test.mjs
bash scripts/diff-coverage-ts-self-test.sh
bash scripts/ci/verify-openburnbar-safari-extension.test.sh
bash -n scripts/test-openburnbar-safari-extension.sh \
  scripts/ci/sign-openburnbar-safari-extension.sh \
  scripts/ci/verify-openburnbar-safari-extension.sh
./scripts/test-openburnbar-app.sh \
  -only-testing:OpenBurnBarTests/SafariLearningTimelineViewModelTests \
  -only-testing:OpenBurnBarTests/DaemonSocketClientBufferTests/testSafariLearningMethods_sendAuthenticatedTypedRequestShapes
```

For a built app:

```bash
python3 scripts/ci/verify-openburnbar-safari-extension-layout.py \
  "/path/to/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
```

For a signed direct app:

```bash
bash scripts/ci/verify-openburnbar-safari-extension.sh \
  "/path/to/OpenBurnBar.app" direct TEAMID
```

For a signed MAS archive app:

```bash
bash scripts/ci/verify-openburnbar-safari-extension.sh \
  "/path/to/OpenBurnBar.xcarchive/Products/Applications/OpenBurnBar.app" \
  mas TEAMID
```

## Test content

Use controlled accounts and non-production fixtures wherever an action could
have side effects.

Required fixture classes:

1. semantic static article with headings, links, table, image, and chart
2. React-controlled text input and select controls
3. open-shadow-root component
4. closed-shadow-root component with a supported page-world bridge
5. strict-CSP page
6. infinite-scroll list
7. zoomed page with horizontal and vertical viewport offsets
8. same-origin and cross-origin frames
9. protected banking/payment/credential-like route that must be denied
10. navigation flow that opens and closes a run-owned tab

Never perform destructive payment, account, security, deletion, or publishing
actions against a real production service.

## Installation and onboarding

- [ ] A fresh install contains exactly one
      `OpenBurnBarSafariExtension.appex` under `Contents/PlugIns`.
- [ ] Packaged persistent host permissions contain only
      `http://127.0.0.1/*`, `http://localhost/*`, and `http://[::1]/*`.
- [ ] Broad HTTP/HTTPS page host permissions remain optional rather than
      permanently granted.
- [ ] Safari lists OpenBurnBar with the expected name/icon.
- [ ] The user can enable and disable the extension.
- [ ] The extension requests site access only when needed.
- [ ] Denying site access produces a clear recovery state and no page capture.
- [ ] The popup explains daemon-down, missing-token, and no-model states.
- [ ] Recovery reconnects without requiring an app reinstall.
- [ ] Direct and MAS builds explain unavailable distribution-specific
      fallbacks accurately.

## Ask about this page

Run the matrix against at least three independently routed model families when
provider access is available. Record the exact provider/model and whether page
imagery leaves the Mac.

- [ ] The agent answers exact text questions from DOM/accessibility content.
- [ ] The agent answers visual layout/color/chart/image questions from the
      screenshot.
- [ ] Mixed questions use both sources and do not hallucinate hidden/offscreen
      content as visible.
- [ ] Screenshot long edge is at most 1568 pixels.
- [ ] Screenshot capture is the visible viewport unless full-page capture was
      explicitly requested.
- [ ] Zoomed-page boxes align with visible elements.
- [ ] Page content is wrapped/labeled as untrusted prompt input.
- [ ] A page instruction asking the model to ignore OpenBurnBar policy does not
      alter tools, approvals, deny rules, or provider choice.
- [ ] Cloud screenshot disclosure appears once per session before the first
      relevant provider request.
- [ ] Choosing a local model keeps the screenshot/page context local.
- [ ] Cancelling during capture/model streaming stops promptly and leaves the
      popup reusable.

## Agentic actions

Exercise click, type, select, press key, scroll, hover, focus, navigate,
open/close/list tabs, wait, extract, approved JavaScript, and abort.

- [ ] Each state-changing action shows an accurate preview when approval is
      required.
- [ ] Reject leaves the page unchanged and records the rejected decision.
- [ ] Allow once applies to one action only.
- [ ] Session trust expires at the documented boundary.
- [ ] React-controlled inputs receive the intended value and page listeners
      observe the input/change sequence.
- [ ] Scroll-to-target is followed by a fresh bounding-box read.
- [ ] A stale selector/box is rejected rather than clicking old coordinates.
- [ ] Every action verifies an expected postcondition before the next action.
- [ ] Synthetic-event limitations surface honestly; they do not trigger an
      unannounced privileged fallback.
- [ ] Page-world JavaScript requires the expected approval and is audited.
- [ ] For approved JavaScript in both isolated and page worlds, Stop aborts
      bridge waiting, rejects the late completion, and prevents queued or new
      actions from starting.
- [ ] The test records that already-running JavaScript may finish and that page
      effects completed before Stop remain. UI and audit surfaces never promise
      forced termination or rollback.
- [ ] Strict-CSP/closed-shadow failures are typed and recoverable.
- [ ] The run cannot modify a background tab the user did not hand it.
- [ ] A run-owned tab can be opened, listed, used, and closed.
- [ ] Manual user navigation pauses/re-scopes the run before another action.

## Safety and panic

- [ ] Built-in banking/payment/credential/account-security denies preempt an
      allow rule.
- [ ] `file://`, localhost, admin, billing, and OAuth-style protected routes
      follow the deny registry.
- [ ] URL scope is populated from the live tab for every action.
- [ ] Popup Stop aborts active bridge waits and queued Safari work, invalidates
      the current work generation, and rejects stale completion.
- [ ] The global panic shortcut aborts the same run.
- [ ] No action begins after panic until a new run is explicitly started.
- [ ] Pending App Group chunks are deleted/expired after abort.
- [ ] Audit-chain validation passes after allowed, rejected, failed, and
      aborted actions.
- [ ] Tampering with a chunk digest/count/owner/expiry fails closed without
      partial parsing.
- [ ] Restarting the short-lived native handler cannot inherit stale request
      state.

## Memory and learning

- [ ] Free tier writes no durable Safari memories or skills.
- [ ] Pro+ first use presents consent before durable learning.
- [ ] Opting out keeps the current session usable without durable writes.
- [ ] Credentials, tokens, cookies, raw page dumps, and denied-domain material
      are rejected.
- [ ] A correction or repeated workflow creates a proposal, not a silent
      activated rule.
- [ ] Proposed memory/skill includes provenance and review state.
- [ ] Recall is redacted and wrapped as untrusted context.
- [ ] Edit, reject, forget, rollback, and whole-profile deletion work.
- [ ] Turning learning off deletes the learned Safari profile when requested.

### Native learned-profile review

Exercise the dedicated app window against a controlled timeline containing at
least one proposed memory, approved memory, approved site rule, proposed skill,
rejected item, and rolled-back item.

- [ ] **Learning → What BurnBar Learned About You…** opens the window.
- [ ] `⌘⇧L` opens the same window.
- [ ] The status item secondary menu's **What BurnBar Learned…** item opens the
      same window.
- [ ] `openburnbar://learning` opens the same window from a cold and warm app.
- [ ] Reopening focuses the existing window instead of creating a duplicate,
      refreshes the daemon projection, and preserves its saved frame.
- [ ] All, Proposed, Active, Rejected, and Rolled Back filters show exact
      counts and items.
- [ ] Search matches title, learned content, reason, and source site without
      treating learned text as markup.
- [ ] Approve and Reject update the visible item to the exact daemon-returned
      version.
- [ ] Proposed items can be permanently forgotten without first being
      rejected.
- [ ] Edit validates title/content byte limits before sending and preserves the
      draft after a simulated stale-version conflict.
- [ ] Rollback targets the immediately previous retained version and projects
      the daemon-returned result.
- [ ] Pause disables new learning and recall while leaving existing items
      reviewable.
- [ ] Confirmed whole-profile deletion removes the timeline and active skill
      materializations; cancelling the confirmation changes nothing.
- [ ] Free tier cannot opt in or mutate durable state and presents a clear
      session-only explanation.
- [ ] Daemon unavailable, timeout, malformed response, and authorization
      failure states are readable, actionable, and leave no optimistic state
      stranded.
- [ ] A late response from an older refresh cannot overwrite a newer timeline.

## Accessibility and visual quality

- [ ] Every popup control is reachable in logical order by keyboard.
- [ ] Visible focus is never clipped or hidden by animation.
- [ ] VoiceOver announces mode, selected agent, activity, approval action,
      disclosure, error, Stop, and terminal run state.
- [ ] Approval choices are distinguishable without color.
- [ ] Increased Contrast and Reduce Transparency remain legible.
- [ ] Reduce Motion removes nonessential animation without hiding state.
- [ ] Light/dark appearance preserves text, icon, focus, and status contrast.
- [ ] 200% browser zoom does not truncate critical controls.
- [ ] Long model names, localized-style expansion, and multiline errors wrap
      without overlapping controls.
- [ ] Loading, empty, denied, offline, timeout, and partial-result states feel
      intentional rather than blank or frozen.
- [ ] The learned-profile window is usable at its 720×520 minimum size and
      remains balanced at its 980×760 preferred size.
- [ ] VoiceOver announces the learned-profile status, counts, filters, item
      kind/status, provenance, mutation progress, editor validation, and
      destructive confirmation without relying on color.
- [ ] Every learned-profile control is keyboard reachable; `⌘R` refreshes and
      Escape/Cancel closes the editor without discarding daemon state.
- [ ] Long learned titles/content, UTF-8 text, and expanded localized strings
      wrap or scroll without clipping the mutation controls.

## Performance and durability

### Candidate-bound performance evidence

Performance JSON is useful only when it is bound to the exact installed
candidate. Before collecting measurements:

1. Complete the **Result header** and record the source commit and tree.
2. Hash the installed host and nested appex as distributed artifacts; do not
   substitute a source-tree hash for installed bytes.
3. Record the extension and daemon versions shown in the exported JSON.
4. Preserve any prior export, then use the drawer's two-step **Clear samples**
   control. Export once and confirm `totalRecorded`, `droppedCount`, and
   `samples.length` are all zero before exercising the candidate.
5. Start from a known extension lifecycle boundary. For a cold sample, quit
   Safari and OpenBurnBar, relaunch both, and open the popup once. For a warm
   sample, leave both processes running and repeat the controlled operation.
6. Use only controlled fixtures, record the fixture class separately, and
   never put fixture URLs, page content, prompts, account names, or provider
   identifiers into the performance JSON.
7. Split the work into bounded scenario batches and export each batch before
   clearing it. The 240-sample window spans all metrics, so one monolithic run
   can legitimately expire early samples before the full matrix is complete.

The popup's **Performance evidence** drawer records:

| JSON metric | Required exercise |
|---|---|
| `popup_bootstrap` | At least 5 cold and 20 warm popup openings |
| `native_attach` | At least 5 cold and 20 warm daemon attachments |
| `command_poll` | Idle polls and polls that issue controlled commands |
| `command_completion` | Successful, rejected/failed, and aborted command acknowledgements |
| `viewport_capture` | Normal viewport plus zoomed/offset and full-page-segment captures |
| `image_resize` | Offscreen path, content fallback when available, and full-page stitching |
| `ask_first_token` | Local and cloud Ask routes, including one intentional abort |
| `action_verification` | Click, type, scroll, navigation, tab, and failure/stale-target cases |
| `stop_panic` | Popup Stop, popup-local shortcut, and daemon-issued abort; correlate the separate native global-panic proof |
| `learning_load` | Cold and warm learning projection loads |
| `learning_mutation` | Opt-in/out, correction proposal, approve, reject, and forget |

The metric boundary is part of the evidence:

- `ask_first_token` begins when the user submits Ask, before page
  preparation/capture/recall, and ends at the first streamed assistant delta;
- `viewport_capture` and `image_resize` are separate so Safari capture cost is
  not confused with image processing;
- `action_verification` includes the fresh post-action page-state read but not
  the daemon completion acknowledgement;
- `command_completion` measures that acknowledgement separately;
- `stop_panic` is a forward-cancellation latency, not proof that already
  completed page effects were rolled back. A `popup_shortcut` or
  `daemon_abort` sample is not, by itself, evidence that the macOS system-wide
  panic hotkey fired. Preserve the native panic audit/recording and correlate
  its timestamp with cessation of Safari work.

After each cold and warm matrix:

1. Open **Performance evidence** and confirm the drawer remains keyboard
   reachable, VoiceOver-readable, and responsive while samples exist.
2. Use **Download JSON**. Use **Copy JSON** as an additional clipboard-path
   check; both actions must flush and request the current background snapshot,
   and a clipboard failure must leave Download available.
3. Hash the JSON and preserve it beside the candidate identity record. Record
   whether `performance.persistence` is `ready` or `memory_only`; a
   `memory_only` export is valid only for that live process and must be
   preserved before exit.
4. Verify `retentionLimit` is 240, retained samples never exceed it,
   `totalRecorded >= samples.length`, and `droppedCount` increases after
   retention is exceeded.
5. Recalculate a representative metric's minimum, median, p95, maximum,
   latest, and outcome counts from `samples`; they must match `summaries`.

Privacy inspection is mandatory. Search the exported bytes for all controlled
fixture URLs/domains, page titles, prompts, unique page text, test account
names, provider/model IDs, tokens, tab IDs, and command IDs. The result must
contain none of them. The `privacy.localOnly` declaration must be `true`, and
the exclusion list must name URLs, page titles, prompts, page text,
screenshots, model/provider identifiers, tokens/credentials, and tab/command
identifiers. Treat any content leak as **FAIL**, remove the evidence from
normal sharing locations, and remediate the serializer before continuing.

Record separately because the bounded JSON intentionally does not contain
them:

- page extraction time and bounded payload bytes;
- screenshot output dimensions and bytes;
- native-message round-trip latency for small and chunked payloads;
- approval wait time versus action execution time;
- memory and App Group disk usage after 1, 10, and 100 capture/action cycles;
- fixture name, provider route identity, and screenshot-disclosure evidence.

Acceptance:

- [ ] Cold and warm exports are bound to the installed host/appex hashes,
      source commit/tree, extension version, daemon version, tester, and time.
- [ ] All eleven metrics have representative successful samples; applicable
      error and aborted paths are also represented.
- [ ] Retention, dropped-count, percentile, latest-value, and outcome summaries
      reconcile with the exported samples.
- [ ] Export inspection finds no URL, title, prompt, page text, screenshot,
      provider/model ID, credential/token, tab ID, or command ID.
- [ ] `ready` persistence survives popup reopen and extension lifecycle
      behavior as documented; `memory_only` is clearly disclosed and exported
      before process exit.
- [ ] Copy and download actions are keyboard reachable, VoiceOver-readable,
      and expose clear success/failure recovery.
- [ ] Clear samples requires explicit two-step confirmation, produces a
      verifiably empty export, and does not contact the daemon or a provider.
- [ ] UI input, scrolling, and Stop remain responsive while capture/model work
      is active.
- [ ] Repeated capture/action cycles do not show unbounded memory or App Group
      disk growth.
- [ ] Oversized page context is bounded/truncated with a visible explanation.
- [ ] Network loss, daemon restart, Safari restart, app restart, and sleep/wake
      recover without executing a stale action.
- [ ] Bundle-size checks pass for background, content, popup, and total output.

## Distribution proof

### Apple Development local build

- [ ] `make build-signed` reaches the explicit development signing verifier.
- [ ] Host and appex embed separate exact, device-authorized development
      profiles; no wildcard application identifier is accepted.
- [ ] Both profiles authorize `group.com.openburnbar.app` and the shared
      `TEAMID.com.openburnbar.app` Keychain authority.
- [ ] Host and appex use the expected Apple Development team and certificate,
      with hardened runtime and library validation.
- [ ] The installed build is still exercised in real Safari; verifier success
      is artifact proof, not behavioral certification.

### Developer ID direct download

- [ ] Dedicated extension `MAC_APP_DIRECT` profile is embedded.
- [ ] Profile authorizes the exact extension application identifier, App Group,
      and Keychain group.
- [ ] Host `MAC_APP_DIRECT` profile independently authorizes the exact shared
      App Group and Keychain group.
- [ ] Signed host entitlements retain `group.com.openburnbar.app` and
      `TEAMID.com.openburnbar.app`.
- [ ] Signed appex entitlements retain App Sandbox and outbound network client.
- [ ] Nested code is signed before the appex; appex before app.
- [ ] Explicit verifier passes; `codesign --deep` is not the only evidence.
- [ ] App and DMG are notarized/stapled.
- [ ] Mounted public DMG verifier passes on the downloaded bytes.
- [ ] Mounted-DMG smoke launches the app and authenticates the packaged daemon.

### Mac App Store

- [ ] Host app receives MAS entitlements through the host-only build variable.
- [ ] Signed MAS host retains the shared App Group and Keychain group in both
      the archive and expanded exported package.
- [ ] Appex retains its own sandbox/App Group/Keychain entitlements.
- [ ] Archive verifier passes.
- [ ] Exported package is expanded and the exported appex verifier passes.
- [ ] Direct-only AppleScript/Accessibility fallbacks are absent or disabled.
- [ ] App Store reviewer flow does not require an unsandboxed daemon path.

## Final verdict

Record one of:

- **PASS** — every required automated, real-Safari, safety, accessibility, and
  selected distribution check passed for the exact candidate.
- **HOLD** — candidate may be technically healthy, but a required manual,
  provider, physical, signing, notarization, public, or App Store proof surface
  is missing.
- **FAIL** — observed behavior contradicts a requirement.

List every remaining risk and owner. Do not convert `HOLD` into `PASS` based on
CI, mocks, a different candidate, or a different distribution channel.
