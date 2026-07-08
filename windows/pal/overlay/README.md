# `windows/pal/overlay` — transparent click-through pet overlay

The platform half of the desktop PetCompanion's window (Phase 4 · G4, PetCompanion
lane). Windows peer of the borderless, non-activating, per-pixel-shaped NSPanel the
macOS companion uses (`AgentLens/PetCompanion/Shell/PetPanel.swift`).

## What it is

A `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`
per-pixel-alpha overlay window:

| Flag | Why |
|------|-----|
| `WS_EX_LAYERED` | per-pixel alpha via `UpdateLayeredWindow` (the pet is a shaped sprite, not a rectangle) |
| `WS_EX_TRANSPARENT` | click-through — mouse input falls to the app behind the pet; toggled off only while the pet is grabbed / its bubble is open |
| `WS_EX_TOOLWINDOW` | keep the overlay out of Alt-Tab + the taskbar |
| `WS_EX_NOACTIVATE` | the overlay **never** becomes foreground, so it cannot steal keyboard focus from the app the user is working in |
| `WS_EX_TOPMOST` | float above ordinary windows |

## Portable vs Windows-only (verification split)

The project targets **plain `net10.0`** (not `net10.0-windows`) so the whole thing
compiles on the macOS authoring host, exactly like `windows/pal/ipc-windows`.

- **macOS-verified today** (`dotnet build` + `dotnet test` in `windows/tests/pet`):
  - [`OverlayWindowStyle`](OverlayWindowStyle.cs) — the exact extended-style bitmask
    and the click-through enable/disable/query transforms. The focus-safety
    invariant (`WS_EX_NOACTIVATE` survives every click-through toggle) is asserted
    in unit tests.
  - [`PerPixelHitTest`](PerPixelHitTest.cs) — the alpha-buffer hit test that answers
    `WM_NCHITTEST` (opaque body pixel → `HTCLIENT`; transparent/near-transparent
    fringe → `HTTRANSPARENT`, i.e. click-through).
- **Windows dev-host / CI-deferred** (compiles clean on macOS; runs only on Windows):
  - [`LayeredOverlayWindow`](LayeredOverlayWindow.cs) — `CreateWindowEx`,
    `UpdateLayeredWindow`, `SetWindowLongPtr`, `WM_NCHITTEST` WndProc.
  - [`Interop/`](Interop) — the hand-written `user32` / `gdi32` / `kernel32`
    P/Invoke surface, pinned to the System32 search path (R19) and marked
    `[SupportedOSPlatform("windows")]` (CA1416).

## Live proof (Windows dev host)

Build the overlay, `UpdateSurface(...)` a small BGRA sprite, and confirm:
1. the window shows without stealing focus (foreground window is unchanged),
2. it is absent from Alt-Tab,
3. clicks over transparent pixels land on the window behind it, and clicks over the
   opaque body are received by the overlay after `SetClickThrough(false)`.
