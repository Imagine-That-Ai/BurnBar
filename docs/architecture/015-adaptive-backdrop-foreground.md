# ADR 015: Adaptive backdrop foreground

## Status

Accepted.

## Context

OpenBurnBar renders animated Canvas2D, WebGL2, and WebGPU kernels behind translucent
dashboard chrome on macOS and Linux. A foreground chosen only from the app theme can
become unreadable as a kernel animates, changes palette, falls back to another
substrate, or crossfades through a spatially varied frame. CSS blend modes are not a
contrast guarantee and make the result dependent on compositor behavior.

## Decision

The shared `BackdropEngine` owns a read-only readability stream derived from the
pixels it actually rendered. Hosts receive a semantic profile, not raw pixels.

- Sample at most every 500 ms, using three sparse points in each visible named
  readability region. If a host cannot publish regions, use a bounded 3 by 3 grid.
  Each live canvas is first reduced to one 24 by 16 `ImageBitmap`, then sampled on
  an `OffscreenCanvas` worker; individual points never trigger separate GPU
  synchronization. Hosts without that worker path use the same bounded buffer on
  the main thread.
- Include both active and outgoing canvases while a kernel crossfade is in flight.
  All substrates use the same tiny Canvas2D readback. No full-frame or per-frame
  readback occurs.
- Compute sRGB linearization, relative luminance, source-over alpha composition,
  and WCAG contrast in the shared engine. Normal text targets 4.5:1. Icons, focus
  indicators, large text, and control boundaries target at least 3:1.
- Compare polished light and dark foreground families against the worst sampled
  background. If neither family passes everywhere, binary-search the minimum
  darkening or lightening scrim that makes the muted text token pass 4.5:1.
- Raise scrim protection immediately. Require a competing tone to remain preferable
  for 900 ms before switching, except when the current tone would require an urgent
  high-opacity correction. Relax scrim opacity gradually to avoid breathing.
- Publish semantic primary, secondary, muted, icon, focus, shadow, scrim, and scrim
  opacity values. Linux uses CSS custom properties at the shell boundary. macOS
  carries the same profile through a WKWebView message handler and SwiftUI
  environment values.
- Engine or sampling failure returns a deterministic palette-derived profile.
  Native flat/editorial backgrounds use matching native fallbacks. Forced-colors
  mode uses system colors, increased-contrast preferences strengthen the scrim,
  and reduced motion disables foreground transition animation.
- Backdrop-exposed command chrome, navigation, and translucent route surfaces use
  the adaptive profile. Opaque dialogs and cards retain their surface-specific
  semantic colors.

## Validation contract

Pure unit tests pin contrast math, compositing, worst-case selection, hysteresis,
fallbacks, and cleanup. The kernel matrix is enumerated from the shared registry, so
new kernels automatically enter the audit. Linux retains the existing axe canvas
exclusion and adds a dedicated rendered-background audit across animation timestamps,
skins, fallbacks, and viewports. The macOS bundle test pins the native readability
bridge in the generated resource.

Performance validation records the Linux shell budget plus browser sampling timing.
The intended steady-state ceiling is one asynchronous 24 by 16 read per live canvas
every 500 ms, including two reads during a crossfade, with no readback between samples.

## Consequences

Foreground changes follow rendered truth instead of theme assumptions, while kernel
identity, pointer behavior, animation, and reduced-motion rendering remain unchanged.
The conservative scrim can slightly reduce backdrop intensity behind text-heavy
regions; this is deliberate and bounded by the minimum opacity needed for WCAG AA.
The change can be contained by removing the host callbacks and semantic token mapping;
the kernel rendering contract itself remains compatible.
