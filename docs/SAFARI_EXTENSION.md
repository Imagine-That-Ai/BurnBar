# The Safari web extension

OpenBurnBar ships a Safari Web Extension (MV3) inside `OpenBurnBar.app`. It lets you
ask, act, and approve against the page you are already looking at, in your real Safari
session — signed in, with your cookies, without a second headless browser.

- **Source:** [`extensions/safari/`](../extensions/safari)
- **Shipped bundle:** `extensions/safari/dist/` — committed, and reproducible from source
- **Host app target:** `OpenBurnBarSafariExtension` (the appex embedded in the Mac app)

## Building it

```bash
npm ci --prefix extensions/safari
npm run build --prefix extensions/safari
```

`dist/` is committed because the appex consumes it as its resources. CI rebuilds it and
fails if the result differs from the committed tree, so a source change without its
rebuilt bundle cannot merge.

Run the project's full gate — types, lint, format, knip, dependency-cruiser, tests,
build, and size budgets — with:

```bash
npm run test:ci --prefix extensions/safari
```

### The service-worker typecheck

The MV3 background runs as a **service worker**, where `window`, `document`, and
`localStorage` do not exist. `tsconfig.background.json` typechecks `src/background` and
`src/shared` against the WebWorker lib with no DOM, so a DOM-only global fails at compile
time rather than at runtime.

This gate exists because a single `window.setTimeout` in the background truncated every
streamed Ask answer at the first delta, and the jsdom-based tests could not see it. CI
additionally asserts that the built `dist/background.js` contains zero `window.`
references.

## Versioning

`build.mjs` stamps `dist/manifest.json` from `extensions/safari/package.json`. The
extension ships inside the Mac app, so its version **is** the app's version:
`package.json`, the source `manifest.json`, and the built `dist/manifest.json` must all
equal `MARKETING_VERSION` in `project.yml`. `scripts/verify-version-consistency.sh`
enforces all three.

## Permissions and the safety model

The extension is deliberately narrow. It asks for the least it can, as late as it can.

### What it holds by default

| Permission | Why |
| --- | --- |
| `nativeMessaging` | Talk to the local OpenBurnBar daemon. This is the only egress. |
| `activeTab`, `tabs`, `scripting` | Read and act on the tab you invoked it on. |
| `storage` | Remember your mode, model, and per-site trust. |
| `alarms` | Keep the service worker's poll loop alive. |

Host access is **loopback only** by default — `http://127.0.0.1/*`, `http://localhost/*`,
and `http://[::1]/*` — which reaches the local daemon and nothing else. Access to real
websites is an *optional* permission that Safari itself must grant, per your explicit
action.

### Website access

Choosing **Complete setup** calls Safari's permission sheet from inside your click,
because Safari discards the request if it loses the user gesture. Nothing is trusted
until Safari confirms the grant *and* the daemon accepts the matching trust record; if
the daemon rejects it, the local grant is rolled back rather than left half-applied.

If the page changes while the sheet is open, the request is refused — the tab and origin
you started from are pinned across the whole transaction.

### Cloud screenshot disclosure

When the selected model is a **cloud** model, sending a screenshot requires acknowledging
that the image leaves your machine. That acknowledgement is **session-scoped**: it lives
in memory, is never written to disk, and is cleared whenever the native session changes.
Quitting Safari or restarting OpenBurnBar means you are asked again — which is what the
disclosure says, so it is what the code does.

### Sensitive pages

Pages that look sensitive are flagged, and acting on them requires a per-site override
you set deliberately. Content scripts run with the restricted API surface Safari gives
them — they never receive the privileged `tabs`, `scripting`, or `permissions`
namespaces.

## Modes

| Mode | Behavior |
| --- | --- |
| **Ask** | Answer questions about the page. No actions taken. |
| **Agentic** | Act on the page, with approvals for anything unreviewed. |
| **Watch** | Observe and narrate without acting. |
| **Handoff** | Hand the live tab to the desktop app to continue. |

`Only current tab` is on by default, so the extension never reaches beyond the tab you
invoked it on unless you turn it off.

## Troubleshooting

**"OpenBurnBar is not running."** — the daemon is not reachable on loopback. Start the
Mac app. The extension retries the native attach on the next popup open rather than
staying offline until Safari restarts.

**Answers stop after the first word.** — a DOM global reached the background service
worker. `npm run typecheck --prefix extensions/safari` reproduces it; see the
service-worker typecheck above.

**A site never gets access.** — Safari grants website access per your action; re-run
**Complete setup** and choose Allow in Safari's sheet.

## Related

- [`AGENTS.md`](../AGENTS.md) — repository agent contract
- [`docs/CI_RELEASE_RUNBOOK.md`](CI_RELEASE_RUNBOOK.md) — release and CI gates
