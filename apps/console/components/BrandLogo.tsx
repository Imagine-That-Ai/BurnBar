"use client";

import * as React from "react";
import { brandLogo } from "@/lib/brandLogos";

/**
 * A provider/harness logo with a guaranteed graceful fallback: known ids get
 * the brand mark (token-tinted tile behind it, so it reads on every theme);
 * unknown ids get an initial letter. A failed image load swaps to the same
 * fallback instead of a broken glyph.
 */
export function BrandLogo({
  id,
  label,
  size = 20,
}: {
  /** Provider or harness id/name used for the logo lookup. */
  id: string;
  /** Display name — drives the fallback initial. */
  label: string;
  size?: number;
}) {
  const [failed, setFailed] = React.useState(false);
  const src = brandLogo(id);

  if (!src || failed) {
    return (
      <span
        aria-hidden
        className="grid shrink-0 place-items-center rounded-[5px] border border-glass-line font-mono text-[10px] text-content-mute"
        style={{ width: size, height: size, background: "var(--color-mercury-wash)" }}
      >
        {label.trim().charAt(0).toUpperCase() || "?"}
      </span>
    );
  }

  return (
    <span
      aria-hidden
      className="grid shrink-0 place-items-center rounded-[5px] border border-glass-line"
      style={{ width: size, height: size, background: "var(--color-ink-elevated)" }}
    >
      <img
        src={src}
        alt=""
        onError={() => setFailed(true)}
        className="object-contain"
        style={{ width: size - 6, height: size - 6 }}
      />
    </span>
  );
}
