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
| [`app/`](app/) | The **WinUI 3 (C#/.NET) shell** — tray flyout, main window, Mica/Acrylic glass, design-token theme, Pretext host. Also hosts `app/OpenBurnBar.App.Presentation` (a **portable net8.0 view-model layer**, no WinUI) with the SessionLogs + Memory + account-**Switcher** view-models, ported record types, grouping/routing/form passes, and transcript parser; the WinUI views under `app/OpenBurnBar.App/SessionLogs/` + `.../Memory/` + `.../Switcher/` render it. Also hosts `app/OpenBurnBar.App.Pet` (a **portable net8.0 PetCompanion core**, no WinUI): the behavior-graph interpreter + seeded RNG, the reaction brain, the petdef parser, the chat-event bridge that drives the graph from the landed Chat state machine, and the transport-agnostic glTF scene controller + embedded three.js shell; the WinUI pet shell under `app/OpenBurnBar.App/Pet/` (overlay window + WebView2 three.js host + chat bubble) renders it. | W6–W7, G4 |
| [`pal/`](pal/) | The **Platform Abstraction Layer** — FS paths, secret store (CNG/TPM + DPAPI), process/ConPTY, named-pipe IPC, toasts, tray, watchers, autolaunch, hotkey, single-instance, mDNS/Bonjour, self-signature check. Includes `pal/overlay` (`OpenBurnBar.Pal.Overlay`, net8.0): the transparent, click-through pet overlay window (`WS_EX_LAYERED\|TRANSPARENT\|TOOLWINDOW\|NOACTIVATE` + per-pixel `UpdateLayeredWindow` + `WM_NCHITTEST`); its portable `OverlayWindowStyle` flag math + `PerPixelHitTest` are macOS-tested, its Win32 host is dev-host-deferred. | W1, G4 |
| [`native/`](native/) | The **native shim** — the C-ABI / FFI bridge that surfaces the Rust crates (`crates/openburnbar-iroh`, `crates/burnbar-remote`) and the DB/crypto engine to the managed shell. | W2 |
| [`storage/`](storage/) | The **SQLCipher storage layer** — opens the *same* Mac-produced encrypted database with the pinned compatibility-4 cipher profile and exposes the read + write DataStore-shaped seam the Engine calls via the PAL. The R2 (DB byte-compat) un-prune. Includes `storage/OpenBurnBar.Storage.SessionLogs`, the net10.0 adapter mapping the read seam onto the presentation `ISessionLogReadSource` for the SessionLogs surface. | W2–W7 |
| [`particles/`](particles/) | The **Win2D particle-engine renderer** — the platform-agnostic swarm/substrate engine library (`OpenBurnBar.Particles`: substrate math, frame model, FFI spec) + a headless perf harness. The WinUI-facing host lives in `app/OpenBurnBar.App/Particles/`. | W6 |
| [`pretext/`](pretext/) | The **Pretext text-layout engine** — the managed `OpenBurnBar.Pretext` engine + JS bridge that drive an offscreen WebView2 host for text metrics, with a Mac-golden metric-parity harness. The WinUI host lives in `app/OpenBurnBar.App/Pretext/`. | W6 |
| [`tests/`](tests/) | **Unit, integration, and parity test projects** for the app, PAL, and native shim. Includes `tests/presentation` (net10.0, xUnit) — the macOS-runnable proof of the SessionLogs + Memory + Switcher view-models: the inbox model, grouping/filter, transcript parser, an end-to-end SessionLogs read through the SQLCipher adapter against the committed byte-compat fixture, and the account-switcher destination routing / grouping / form-validation / add-switch-drain state machine. Includes `tests/pet` (net10.0, xUnit) — the macOS-runnable proof of the PetCompanion core: behavior-graph transitions on the **real committed claudecode petdef**, the chat-event bridge (idle→listen→think→speak→react + idle/active/summon states), the reaction brain, the petdef parser, deterministic RNG, the glTF host protocol against a fake host, and the overlay style/hit-test math. | W7, W11, G4 |

## The aggregating solution

`OpenBurnBar.sln` is an intentionally **empty** Visual Studio solution (standard header +
solution configuration/platform rows, zero `Project(...)` entries). It is the single entry point
`msbuild` / `dotnet` / Visual Studio open. As each workstream lands its project it adds a
`Project(...)` stanza + per-config platform mappings — the WinUI app first (WINUI-016), then the
PAL library, the native shim, and the test projects. Keeping the solution here from day one means
those PRs only *add* to a known-good aggregator rather than inventing the top-level structure.

## Where new Windows source goes

Every Windows **source file** (`.cs`, `.xaml`, `.cpp`, `.cxx`, `.cc`, `.c`, `.h`, `.hpp`, `.rs`)
must live under one of the seven documented sub-trees above. The per-tree budget
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
