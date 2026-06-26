"use client";

import * as React from "react";

// Brand mark file extensions vary across the roster, so we try the common ones
// in order and fall back to a tinted monogram if none load. This keeps the
// provider list robust on a static export (no guaranteed asset path).
const CANDIDATE_EXTS = ["svg", "png"] as const;

function tint(id: string): string {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 52% 52%)`;
}

export function ProviderMark({
  id,
  label,
  size = 22,
}: {
  id: string;
  label: string;
  size?: number;
}) {
  const [attempt, setAttempt] = React.useState(0);
  // Only ever build an asset path from a plain slug — never trust an id from the
  // (future) live data feed enough to interpolate it raw into a URL.
  const isSlug = /^[a-z0-9-]+$/i.test(id);
  const failed = !isSlug || attempt >= CANDIDATE_EXTS.length;
  const ext = CANDIDATE_EXTS[attempt];

  if (failed || !ext) {
    return (
      <span
        aria-hidden
        className="grid shrink-0 place-items-center rounded-md font-display text-[0.7rem] text-white"
        style={{ width: size, height: size, background: tint(id) }}
      >
        {label.charAt(0).toUpperCase()}
      </span>
    );
  }

  return (
    <img
      src={`/brand/logos/${id}.${ext}`}
      alt=""
      aria-hidden
      width={size}
      height={size}
      className="shrink-0 rounded-md object-contain"
      style={{ width: size, height: size }}
      onError={() => setAttempt((a) => a + 1)}
    />
  );
}
