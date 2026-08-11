# OpenBurnBar for Safari

OpenBurnBar for Safari brings the user's chosen agent into the page they are
already viewing. It combines visible-page imagery with precise
DOM/accessibility structure, and it can perform user-approved page actions in
the real logged-in Safari tab.

The Safari surface is not an independent cloud client. Provider selection,
model routing, quotas, usage accounting, approvals, audit, memory policy, and
panic halt remain owned by the OpenBurnBar app and daemon.

## What it does

### Ask about this page

OpenBurnBar collects:

- readable page text
- a box-annotated accessibility/DOM snapshot
- viewport size, zoom offsets, and device pixel ratio
- a compressed screenshot of the visible viewport

The daemon sends only the context needed for the selected request to the
selected model. The extension never stores provider API keys. If a cloud model
will receive a screenshot or page excerpt, the popup shows a provider
disclosure for that session.

### Agentic

The agent can propose typed actions such as click, type, select, scroll,
navigate, extract, wait, and run approved JavaScript. The popup previews
state-changing actions and offers the decisions supported by the active trust
mode. OpenBurnBar:

1. checks the live tab URL against scope and deny rules;
2. confirms the tab belongs to the run;
3. requests approval when required;
4. executes through the content script;
5. re-reads the page and verifies the result;
6. appends a `safari.*` audit event.

The Stop control and OpenBurnBar's global panic shortcut stop the same run.
Stop is a forward cancellation boundary: it aborts bridge waiting, invalidates
the current work generation, ignores stale completion, prevents queued or new
actions, and revokes daemon authority. JavaScript already executing in the page
or isolated world cannot be forcibly killed or undone. Any page effect completed
before Stop remains visible and is part of the run's audit/recovery state.

### Watch and approve

The popup mirrors active daemon runs, pending approvals, recent actions, and
terminal state. It does not create a second run journal in Safari.

### Hand off

With explicit approval, OpenBurnBar can prepare a read-only page briefing for
an installed agent CLI and follow that run through the daemon. The v1 handoff
does not grant the spawned CLI direct Safari control.

### Learn

For eligible Pro/Pro Max/Ultra users, learning is opt-in:

- durable preferences/facts are proposed through the existing memory system;
- recurring workflows can become reviewable portable skill proposals;
- recalled material is redacted and injected as visibly untrusted context;
- credentials, raw page dumps, and denied-domain content are never learned;
- entries remain reviewable, editable, forgettable, and auditable.

Free-tier use is session-only and writes no durable Safari learning state.

### Review what BurnBar learned

Open the dedicated **What BurnBar Learned About You** window from any of these
app-owned entry points:

- the macOS menu bar: **Learning → What BurnBar Learned About You…**
  (`⌘⇧L`);
- the OpenBurnBar status item secondary menu: **What BurnBar Learned…**;
- the authenticated app deep link: `openburnbar://learning`.

The window is a daemon-authoritative projection, not a second memory store. It
reuses one window and model while the app is running, refreshes whenever it is
reopened, and preserves the user's saved window frame. The timeline supports:

- plain-text search across titles, learned content, reasons, and source sites;
- All, Proposed, Active, Rejected, and Rolled Back status filters;
- explicit approval or rejection of staged proposals;
- UTF-8-bounded title/content editing with optimistic version checks;
- rollback to the immediately preceding retained version;
- permanent forgetting of an individual item, including proposed items;
- pausing new Safari learning while keeping the existing profile reviewable;
- confirmed whole-profile deletion, including active skill materializations.

Edits fail closed on stale versions. If another process changes an item while
the editor is open, OpenBurnBar refreshes the daemon timeline and preserves the
local draft for comparison instead of silently overwriting either version.
Free-tier users see the same honest session-only explanation but cannot enable
durable learning. Learned content is rendered as plain text and is never
interpreted as markup or app instructions.

## Installation and enablement

The Safari extension is embedded in both supported macOS distributions:

- Developer ID direct-download `OpenBurnBar.app`
- sandboxed Mac App Store `OpenBurnBar.app`

After installing the app:

1. Launch OpenBurnBar once so the app can complete daemon and token setup.
2. Open Safari → Settings → Extensions.
3. Enable **OpenBurnBar**.
4. Pin the OpenBurnBar toolbar button if Safari does not show it.
5. Open a page, click the toolbar button, and grant that site access when
   Safari asks.
6. Choose a model/agent and mode.

Site access is controlled by Safari. OpenBurnBar cannot silently grant itself
access to a site.

## Permissions and privacy

The MV3 manifest requests:

- `activeTab`
- `alarms`
- `nativeMessaging`
- `scripting`
- `storage`
- `tabs`

Persistent host access is restricted to the three loopback gateway forms:
`http://127.0.0.1/*`, `http://localhost/*`, and `http://[::1]/*`. Broad
HTTP/HTTPS **page** access remains optional and is still subject to Safari's
per-site grant. The native appex is sandboxed and receives only outbound
network access, App Group `group.com.openburnbar.app`, and the shared
OpenBurnBar Keychain group needed for local token resolution.

Viewport capture uses Safari's WebExtension capture path. It does not require
macOS Screen Recording permission. The capture contains only the visible
viewport; full-page capture is a separate opt-in action with size caps.

The extension does not:

- contain provider API keys;
- bypass Safari's site permission;
- authorize itself to modify every tab;
- send screenshots to an unselected provider;
- treat page text as trusted instructions;
- store credentials or raw page dumps as learned memory.

## Safety model

Safari's site grant is necessary but not sufficient. OpenBurnBar independently
enforces:

- tab ownership
- live URL scope
- built-in and user deny rules
- entitlement/budget/concurrency gates
- manual, step, or trusted approval mode
- global and session kill switches
- hash-chained audit events
- post-action verification

Banking, payment, credential, account-security, localhost, file, admin, and
other protected destinations fail closed according to the Computer Use deny
registry. A web page cannot override these controls with text, markup, images,
or injected instructions.

## Failure and recovery

| State | User-visible behavior | Recovery |
|---|---|---|
| Extension disabled | Popup explains that Safari has not enabled OpenBurnBar | Enable it in Safari Settings → Extensions |
| Site access denied | No page content/action request is attempted | Grant access for the current site in Safari |
| Daemon unavailable | Read-only error state; actions disabled | Use the repair/restart action in OpenBurnBar, then retry |
| Gateway token unavailable | Model actions disabled; no provider fallback in the extension | Repair local OpenBurnBar authentication |
| No routable models | Agent picker shows an empty-state explanation | Configure or reconnect a provider/agent in OpenBurnBar |
| Scope/deny rejection | Action is not executed; reason is shown and audited | Change task/site or create a supported explicit rule |
| Approval timeout/rejection | Action remains unexecuted | Re-run the step and approve deliberately |
| Tab navigated/replaced | Run pauses and requires fresh page state/scope | Re-hand the tab to the run |
| Page structure changed | Stale selector/box is rejected | Re-capture context and retry |
| Chunk integrity/expiry failure | Payload is discarded; no partial parse | Retry capture; inspect daemon/app logs if repeated |
| Panic halt | Run, pending actions, and bridge waits stop; late completions are ignored. JavaScript and page effects already executed are not undone. | Start a new run only after reviewing the cause and resulting page state |

## Developer workflow

The web package lives at `extensions/safari`. The native appex lives at
`OpenBurnBarSafariExtension`.

Run the canonical package gate:

```bash
./scripts/test-openburnbar-safari-extension.sh
```

That command performs a locked `npm ci`, then runs type checking, lint,
formatting, dependency checks, tests with coverage, production build, manifest
validation, and bundle-size limits through the package's `test:ci` script.

Other focused checks:

```bash
node --test scripts/ci/classify-ci-impact.test.mjs
bash scripts/diff-coverage-ts-self-test.sh
bash scripts/ci/verify-openburnbar-development-signing.test.sh
bash scripts/ci/verify-openburnbar-safari-extension.test.sh
./scripts/test-openburnbar-app.sh \
  -only-testing:OpenBurnBarTests/SafariLearningTimelineViewModelTests \
  -only-testing:OpenBurnBarTests/DaemonSocketClientBufferTests/testSafariLearningMethods_sendAuthenticatedTypedRequestShapes
python3 scripts/ci/verify-openburnbar-safari-extension-layout.py \
  /path/to/OpenBurnBarSafariExtension.appex
```

Build output is `extensions/safari/dist`. Xcode copies its contents into the
appex resource root, so the packaged manifest is:

```text
OpenBurnBarSafariExtension.appex/Contents/Resources/manifest.json
```

Do not hand-copy generated files into the native source directory.

For an Apple Development local build, `make build-signed` now succeeds only
when both the host app and Safari appex are signed by the same expected team,
carry hardened runtime plus library validation, embed exact non-wildcard
development profiles, and independently authorize
`group.com.openburnbar.app` plus `TEAMID.com.openburnbar.app`. A wildcard appex
profile is intentionally a build failure even if Xcode produced an otherwise
signed bundle. When no Apple Development identity exists, the command retains
its contributor-friendly ad-hoc fallback, but explicitly does not certify
Safari App Group transport or provisioned Keychain behavior.

## Distribution invariants

The embedded product must remain:

- bundle ID `com.openburnbar.app.safari-extension`
- extension point `com.apple.Safari.web-extension`
- MV3, Safari minimum 15.4
- App Sandbox enabled
- App Group `group.com.openburnbar.app`
- signed before the containing app

The direct-download release requires:

- `OPENBURNBAR_SAFARI_EXTENSION_PROFILE` locally, or
- `OPENBURNBAR_SAFARI_EXTENSION_PROFILE_BASE64` in the protected GitHub
  `release` environment.

The profile must be the dedicated `MAC_APP_DIRECT` profile for the extension,
not the host app profile. The containing app also needs its own regenerated
`MAC_APP_DIRECT` profile. Both profiles and both signed products must authorize
the exact App Group `group.com.openburnbar.app` and shared Keychain group
`TEAMID.com.openburnbar.app`; a profile for only one side is not a working
transport.

The Mac App Store build uses automatic App Store signing and verifies the appex
in both the archive and the expanded exported package. Host MAS entitlements
are supplied through `OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS`; never pass the
host `CODE_SIGN_ENTITLEMENTS` globally. The MAS host and appex profiles must
independently authorize the same App Group and Keychain group. Until Apple
capabilities/profiles and the protected direct-profile secrets are regenerated,
distribution remains **HOLD** even when source, mock, unsigned layout, and CI
tests pass.

## QA and proof

Automated mocks prove contracts and failure behavior, not the user's real
Safari session. Complete the candidate-bound checklist in
[Safari Extension QA](qa/SAFARI_EXTENSION_QA.md) before claiming the feature is
release-ready.

Keep these proof surfaces separate:

- source and unit/integration proof
- native build/embedding proof
- signed direct artifact proof
- notarized public DMG proof
- Mac App Store archive/export proof
- physical real-Safari behavior
- provider/model behavior and disclosure

## References

- [Safari Web Extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions)
- [Native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [Safari compatibility assessment](https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility)
- [Safari extension optimization](https://developer.apple.com/documentation/safariservices/optimizing-your-web-extension-for-safari)
- [OpenBurnBar Safari ADR](adr/2026-08-10-openburnbar-safari-extension.md)
- [OpenBurnBar threat model](THREAT_MODEL.md)
