# OpenBurnBar — Windows feature integrations

Home for the Windows port's **feature-integration seams** — the surfaces that bridge a
macOS product feature onto Windows-native platform APIs. Each integration follows the same
two-project shape proven by the rest of the Windows tree:

1. **A portable `net8.0` library** — the dependency-free half: protocol / wire codecs, state
   machines, consent / budget stores, and the platform-seam *interfaces*. No Windows or WinUI
   dependency, so the SAME assembly is unit-tested on the macOS authoring host today via
   `dotnet test` and shipped unchanged on Windows.
2. **A `net8.0-windows` adapter library** — the Windows-native half: implements the portable
   lib's seam interfaces over WinRT projections (Windows.Graphics.Capture, Windows.Media.*,
   Windows.Networking.PushNotifications, …). With `EnableWindowsTargeting=true` the adapter
   *compiles* on macOS against the Windows SDK projection ref pack (Roslyn-clean); the projected
   APIs have no macOS runtime, so nothing here *executes* off Windows — runtime behavior is
   Windows dev-host / CI deferred.

## Integrations

| Path | Feature | Portable lib | Windows adapter |
|------|---------|--------------|-----------------|
| [`mercury/`](mercury/) | **Mercury media pipeline** — screen mirror, audio/mic/camera capture, RFB/VNC remote control, file transfer, consent + media-budget enforcement, VoIP wake. | `OpenBurnBar.Integrations.Mercury` (RFB/ARD + media-packet wire codecs, media-session state machine, consent ledger, media-budget capability gate + fail-closed status store, file-transfer chunker) | `OpenBurnBar.Integrations.Mercury.Windows` (Windows.Graphics.Capture screen, WASAPI AudioGraph, MediaCapture camera, MediaFoundation encode, WNS raw-push VoIP substitute) |

Tests live under [`windows/tests/`](../tests/) (e.g. `tests/mercury`), matching the rest of the tree.

## Where new integration source goes

`integrations` is a registered top-level Windows sub-tree
([`windows/README.md`](../README.md), [`budgets/windows-tree-baseline.json`](../../budgets/windows-tree-baseline.json),
[`scripts/debt/check-windows-tree-budget.sh`](../../scripts/debt/check-windows-tree-budget.sh)).
Every integration source file (`.cs`, …) must live under `windows/integrations/<name>/` so the
per-tree size ratchet keeps counting it in the `integrations` bucket.
