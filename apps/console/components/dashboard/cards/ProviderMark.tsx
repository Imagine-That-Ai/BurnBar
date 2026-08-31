"use client";

import * as React from "react";

// Brand mark file extensions vary across the roster, so we try png and svg
const CANDIDATE_EXTS = ["png", "svg"] as const;

function tint(id: string): string {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 52% 52%)`;
}

export function normalizeProviderSlug(raw: string): string {
  const clean = raw.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-");
  if (clean === "claudecode" || clean === "claude" || clean === "claude-code") return "claude-code";
  if (clean === "chatgpt" || clean === "openai") return "openai";
  if (clean === "gemini") return "google";
  if (clean === "open-code") return "opencode";
  if (clean === "kilo") return "kilo-code";
  if (clean === "roo") return "roo-code";
  return clean;
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
  const slug = normalizeProviderSlug(id);
  const isSlug = /^[a-z0-9-]+$/i.test(slug);
  const failed = !isSlug || attempt >= CANDIDATE_EXTS.length;
  const ext = CANDIDATE_EXTS[attempt];

  if (failed || !ext) {
    return (
      <span
        aria-hidden
        className="grid shrink-0 place-items-center rounded-md font-display text-[0.7rem] font-bold text-white shadow-sm"
        style={{ width: size, height: size, background: tint(slug || id) }}
      >
        {label.charAt(0).toUpperCase()}
      </span>
    );
  }

  return (
    <img
      src={`/brand/logos/${slug}.${ext}`}
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
