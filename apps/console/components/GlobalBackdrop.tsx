"use client";

import * as React from "react";

import { KernelBackdrop } from "@/components/dashboard/KernelBackdrop";
import { useBackdrop } from "@/lib/useBackdrop";
import type { KernelId } from "@/lib/gl/engine/types";
import { inkFor, INK_FG, INK_MUTE, INK_DIM, INK_HALO } from "@/lib/kernelInk";

/**
 * The console-wide living backdrop + per-kernel legibility ink layer.
 *
 * Mounted once in AppShell. The animated kernel renders behind EVERY route
 * (z:-2) — the dashboard's glass cards and every editorial page share it. On
 * top of that:
 *
 *  - On ink routes (every route except /dashboard) we paint a two-zone scrim
 *    (z:-1, under content) and publish the active kernel's ink as CSS custom
 *    props on <body data-ink="on">. The `body[data-ink="on"]` scope in
 *    globals.css remaps the editorial text/accent tokens to the light ink ramp,
 *    so every component flips to light-on-dark with zero per-page edits, plus a
 *    universal per-glyph halo as the AA backstop the flat scrim can't guarantee.
 *  - On /dashboard, `inkEnabled` is false: no scrim, no token remap. The
 *    dashboard's `.lg-card` glass owns its own legibility, untouched.
 *
 * `onResolve` reports the kernel actually shown (post GL-fallback), so the ink
 * we publish — and `body[data-kernel]` for the inspector — match what renders.
 */
export function GlobalBackdrop() {
  const { kernelId, inkEnabled } = useBackdrop();
  const [resolved, setResolved] = React.useState<KernelId>(kernelId);

  // Keep `resolved` honest when the kernel switches with no GL fallback (the
  // engine only fires onResolve on mount + switch; this covers fast switches).
  React.useEffect(() => {
    setResolved(kernelId);
  }, [kernelId]);

  // Publish ink vars + the data-ink/data-kernel flags on <body> so the token
  // remap (globals.css) and the inspector both work. Cleared off ink routes.
  React.useEffect(() => {
    const body = document.body;
    if (!inkEnabled) {
      body.setAttribute("data-ink", "off");
      delete body.dataset.kernel;
      return () => {
        body.removeAttribute("data-ink");
      };
    }

    const ink = inkFor(resolved);
    const s = body.style;
    body.setAttribute("data-ink", "on");
    body.dataset.kernel = resolved; // inspector reads this
    s.setProperty("--ink-fg", INK_FG);
    s.setProperty("--ink-mute", INK_MUTE);
    s.setProperty("--ink-dim", INK_DIM);
    s.setProperty("--ink-accent", ink.accent);
    s.setProperty("--ink-halo", INK_HALO[ink.haloTier]);
    s.setProperty("--ink-scrim-hero", String(ink.scrim.hero));
    s.setProperty("--ink-scrim-read", String(ink.scrim.read));
    // Optional top-strip nav darken — published only when this kernel needs it,
    // removed otherwise so it never leaks onto the next (passing) kernel.
    if (ink.scrim.nav != null) s.setProperty("--ink-scrim-nav", String(ink.scrim.nav));
    else s.removeProperty("--ink-scrim-nav");

    return () => {
      body.removeAttribute("data-ink");
      delete body.dataset.kernel;
      body.style.removeProperty("--ink-scrim-nav");
    };
  }, [resolved, inkEnabled]);

  return (
    <>
      {/* The animated kernel — behind everything, on every route. On
          /experimental it doubles as the in-place preview: picking a tile sets
          the global kernel, so the gallery's own background IS the selection. */}
      <KernelBackdrop
        kernelId={kernelId}
        className="ink-backdrop"
        onResolve={setResolved}
      />
      {/* The legibility scrim — only on ink routes, above the kernel, under content. */}
      {inkEnabled && <div className="ink-scrim" aria-hidden />}
    </>
  );
}
