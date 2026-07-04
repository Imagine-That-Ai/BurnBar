# OpenBurnBar — Windows source tree

Greenfield home for the Windows port (see [`docs/WINDOWS_PORT_MASTER_PLAN.md`](../docs/WINDOWS_PORT_MASTER_PLAN.md)).
This tree is **new and separate** from the macOS app (`AgentLens/`, `OpenBurnBarCore/`,
`OpenBurnBarDaemon/`), the iOS app (`OpenBurnBarMobile/`), the Android app (`android/`), and the
shared `packages/` — nothing here collides with those trees.

Right now this is a **skeleton**: the layout, the aggregating solution, the CI lane, and the
per-tree budget exist so that later workstreams drop real projects into a place that already
builds, lints, and ratchets. No product code lives here yet.

## Layout

| Path | Contents | Workstream |
|------|----------|------------|
| [`OpenBurnBar.sln`](OpenBurnBar.sln) | The aggregating Visual Studio solution. Now registers the WinUI shell spike (`app/OpenBurnBar.App`, **WINUI-016**); the PAL, native shim, and test projects register into it as they land. | W10 |
| [`app/`](app/) | The **WinUI 3 (C#/.NET) shell** — tray flyout, main window, Mica/Acrylic glass, design-token theme, Pretext host. Also hosts `app/OpenBurnBar.App.Presentation` (a **portable net8.0 view-model layer**, no WinUI) with the SessionLogs + Memory + account-**Switcher** view-models, ported record types, grouping/routing/form passes, and transcript parser; the WinUI views under `app/OpenBurnBar.App/SessionLogs/` + `.../Memory/` + `.../Switcher/` render it. It also carries the **portable provider-quota parse core** (`app/OpenBurnBar.App.Presentation/Quota/`, no WinUI): the four macOS quota mechanisms — the Claude statusline-hook payload, the Cursor `state.vscdb`-sourced usage-summary, the Codex `wham/usage` API response, and the Anthropic `anthropic-ratelimit-*` response headers — each parsed value-for-value into the shared `ProviderQuotaSnapshot`/`ProviderQuotaBucket` model the landed Quota surface under `app/OpenBurnBar.App/Quota/` renders (the `.cmd`/PowerShell statusline wrapper, the Windows file-watch, and the `state.vscdb` SQLite read are net8.0-windows/adapter-deferred). Also hosts `app/OpenBurnBar.App.Pet` (a **portable net8.0 PetCompanion core**, no WinUI): the behavior-graph interpreter + seeded RNG, the reaction brain, the petdef parser, the chat-event bridge that drives the graph from the landed Chat state machine, and the transport-agnostic glTF scene controller + embedded three.js shell; the WinUI pet shell under `app/OpenBurnBar.App/Pet/` (overlay window + WebView2 three.js host + chat bubble) renders it. | W6–W7, G4 |
| [`pal/`](pal/) | The **Platform Abstraction Layer** — FS paths, secret store (CNG/TPM + DPAPI), process/ConPTY, named-pipe IPC, toasts, tray, watchers, autolaunch, hotkey, single-instance, mDNS/Bonjour, self-signature check. Also hosts the **ViGEm virtual-HID computer-use input path** (`pal/input` portable core + `pal/input-windows` ViGEmBus/SendInput adapter, **W5 / R17**): the advisory-vs-non-bypassable action classification + capability-token gate-before-dispatch + Ed25519 token verify + triple kill-switch, unit-tested on macOS (`tests/input`). Includes `pal/overlay` (`OpenBurnBar.Pal.Overlay`, net8.0): the transparent, click-through pet overlay window (`WS_EX_LAYERED\|TRANSPARENT\|TOOLWINDOW\|NOACTIVATE` + per-pixel `UpdateLayeredWindow` + `WM_NCHITTEST`); its portable `OverlayWindowStyle` flag math + `PerPixelHitTest` are macOS-tested, its Win32 host is dev-host-deferred. | W1, W5, G4 |
| [`native/`](native/) | The **native shim** — the C-ABI / FFI bridge that surfaces the Rust crates (`crates/openburnbar-iroh`, `crates/burnbar-remote`) and the DB/crypto engine to the managed shell. | W2 |
| [`storage/`](storage/) | The **SQLCipher storage layer** — opens the *same* Mac-produced encrypted database with the pinned compatibility-4 cipher profile and exposes the read + write DataStore-shaped seam the Engine calls via the PAL. The R2 (DB byte-compat) un-prune. Includes `storage/OpenBurnBar.Storage.SessionLogs`, the net10.0 adapter mapping the read seam onto the presentation `ISessionLogReadSource` for the SessionLogs surface. | W2–W7 |
| [`particles/`](particles/) | The **Win2D particle-engine renderer** — the platform-agnostic swarm/substrate engine library (`OpenBurnBar.Particles`: substrate math, frame model, FFI spec) + a headless perf harness. The WinUI-facing host lives in `app/OpenBurnBar.App/Particles/`. | W6 |
| [`pretext/`](pretext/) | The **Pretext text-layout engine** — the managed `OpenBurnBar.Pretext` engine + JS bridge that drive an offscreen WebView2 host for text metrics, with a Mac-golden metric-parity harness. The WinUI host lives in `app/OpenBurnBar.App/Pretext/`. | W6 |
| [`computeruse/`](computeruse/) | The **Computer-Use subsystem**. `OpenBurnBar.ComputerUse.Core` is the portable (net8.0) policy + crypto core — capability-token issuer/verifier (Ed25519, attestation-bound, single-use nonce), the tamper-evident audit hash-chain + Ed25519 signed head, the triple-independent kill-switch state machine (hotkey + workspace-lock + Remote-Config, **fail-closed-on-RC-error**, R17), the deny-region / scope matcher, the capability-gate decision tree, and the watchdog command protocol. `OpenBurnBar.ComputerUse.Windows` (net10.0-windows) implements the SendInput / IUIAutomation / Windows.Graphics.Capture / named-pipe adapters behind the Core's interfaces (consuming the landed `pal/ipc` peer-auth harness). | W5 |
| [`integrations/`](integrations/) | **Third-party device / service integrations.** Each integration is a portable, dependency-free `net8.0` library (protocol/wire codecs, discovery record parse/build, session + wizard state machines, consent/budget stores) proven by `dotnet test` on macOS, plus a thin `net8.0-windows` adapter (real sockets / OS discovery / capture) behind interfaces. Ships: `integrations/cast/` — **Google Cast** (CASTV2 protobuf framing, `_googlecast._tcp` mDNS parse/build, receiver launch + reconnect state machines, setup-wizard state machine + view-model in `OpenBurnBar.Integrations.Cast`; TLS socket + live Dnssd browser in `OpenBurnBar.Integrations.Cast.Windows`); `integrations/homeassistant/` + `integrations/smarthub/` — **Home Assistant + SmartHub** (HA REST message model + response/error mapping + entity-state→MediaPlayer Cast projection + webhook-id + blueprint installer + token/config stores, with an `HttpClient` transport adapter; the Nest-Hub bridge route dispatcher + `/state.json` contract + constant-time bridge-token auth + snapshot/display-config models + DNS-SD/mDNS record build/parse, with a live `HttpListener` host + `UdpClient` mDNS responder + `NetworkInterface` LAN enumerator; parity `AgentLens/Services/HomeAssistant/*` + `SmartHub/*`); `integrations/mercury/` — **Mercury media pipeline** (RFB/VNC + media-frame packet wire codecs, media-session state machine, consent ledger, media-budget capability gate, file-transfer chunker; Windows.Graphics.Capture / WASAPI / MediaCapture / MediaFoundation / WNS adapters). | W7, W-Mercury |
| [`tests/`](tests/) | **Unit, integration, and parity test projects** for the app, PAL, native shim, and integrations. Includes `tests/presentation` (net10.0, xUnit) — the macOS-runnable proof of the SessionLogs + Memory + Switcher view-models: the inbox model, grouping/filter, transcript parser, an end-to-end SessionLogs read through the SQLCipher adapter against the committed byte-compat fixture, and the account-switcher destination routing / grouping / form-validation / add-switch-drain state machine. Also `tests/quota` (net10.0, xUnit) — the portable provider-quota parse core: one representative adapter per quota mechanism (Claude statusline hook, Cursor `state.vscdb` usage-summary, Codex `wham/usage` API, Anthropic rate-limit headers) parsed value-for-value against committed recorded input + expected-snapshot fixtures (remaining/limit/reset/window/unit). Also `tests/computeruse` (net10.0, xUnit) — the Computer-Use policy/crypto core: token issue→verify→replay-rejected, audit-chain tamper detection, the triple kill-switch (incl. fail-closed-on-RC-error), the scope/deny-region matcher, and the capability-gate decision matrix. Also `tests/pet` (net10.0, xUnit) — the PetCompanion core: behavior-graph transitions on the **real committed claudecode petdef**, the chat-event bridge, the reaction brain, the petdef parser, deterministic RNG, the glTF host protocol, and the overlay style/hit-test math. Also `tests/integrations-cast` — the portable Cast protocol/discovery/wizard libs. Also `tests/integrations` — the HA REST round-trips against recorded fixtures, the SmartHub bridge route dispatch + `/state.json` contract + auth, the DNS-SD/mDNS record bytes, and real HTTP round-trips through the live `HttpListener` host + `HttpClient` transport on loopback. Also `tests/mercury` — byte-exact packet + RFB/ARD wire codecs, the capability/consent/budget invariant, the session state machine, and file-transfer chunk/reassembly. | W5, W7, W11, G4 |

## The aggregating solution

`OpenBurnBar.sln` is an intentionally **empty** Visual Studio solution (standard header +
solution configuration/platform rows, zero `Project(...)` entries). It is the single entry point
`msbuild` / `dotnet` / Visual Studio open. As each workstream lands its project it adds a
`Project(...)` stanza + per-config platform mappings — the WinUI app first (WINUI-016), then the
PAL library, the native shim, and the test projects. Keeping the solution here from day one means
those PRs only *add* to a known-good aggregator rather than inventing the top-level structure.

## Where new Windows source goes

Every Windows **source file** (`.cs`, `.xaml`, `.cpp`, `.cxx`, `.cc`, `.c`, `.h`, `.hpp`, `.rs`)
must live under one of the nine documented sub-trees above. The per-tree budget
([`scripts/debt/check-windows-tree-budget.sh`](../scripts/debt/check-windows-tree-budget.sh))
fails a PR that drops source directly under `windows/` outside those areas, so the layout stays
self-enforcing.

## CI + budgets

- **PR gate (blocking, today):** [`.github/workflows/fast-feedback.yml`](../.github/workflows/fast-feedback.yml)
  → the `debt-budgets` job runs the Windows per-tree ratchet on every PR.
- **PR gate (skeleton lane):** [`.github/workflows/pr-windows-fast.yml`](../.github/workflows/pr-windows-fast.yml)
  → a `windows/`-scoped path filter + a skeleton `windows-latest` build/lint/test lane. Real
  Windows-runner execution is filled in by **CI-003**.
- **Full harness (post-merge / nightly):** [`.github/workflows/openburnbar-pr-harness.yml`](../.github/workflows/openburnbar-pr-harness.yml)
  → the `windows` job mirrors the `android` job (build + lint + unit + coverage + artifact) and is
  registered in `platform-confidence-gate.needs`.
- **Rust crate builds:** the `x86_64-pc-windows-msvc` / `aarch64-pc-windows-msvc` crate workflows
  (`build-iroh-windows.yml`, `build-burnbar-remote-windows.yml`) are owned by **W-RUST / RUST-005**;
  this tree only *references* them.
- **Per-tree budget:** [`budgets/windows-tree-baseline.json`](../budgets/windows-tree-baseline.json),
  partitioned by sub-tree so a macOS/Android change never moves a Windows counter and app growth
  never moves the PAL/native/test counters.

## Ownership

`windows/` is owned in [`.github/CODEOWNERS`](../.github/CODEOWNERS); PRs to this tree carry the
`area: Windows` label ([`.github/labels.yml`](../.github/labels.yml)).
