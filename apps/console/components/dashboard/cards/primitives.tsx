/**
 * Shared, presentational building blocks for dashboard cards.
 *
 * Formatters are hand-rolled (no Intl) on purpose: the console is a static
 * export, and ICU differences between the build-time prerender and the client
 * could otherwise produce a hydration mismatch. All output is deterministic.
 */

import * as React from "react";
import type { CostSample } from "@/lib/dashboard/types";

function withThousands(intPart: string): string {
  return intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/** "$1,234.56" (2dp under 10k, 0dp above for compactness). */
export function formatUsd(n: number): string {
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  if (abs >= 10_000) {
    return "$" + withThousands(Math.round(n).toString());
  }
  const fixed = n.toFixed(2);
  const [int, frac] = fixed.split(".");
  return "$" + withThousands(int ?? "0") + "." + (frac ?? "00");
}

/** "1.2M", "12.3K", "742". */
export function formatCompact(n: number): string {
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  if (abs >= 1_000_000) return (n / 1_000_000).toFixed(abs >= 10_000_000 ? 0 : 1) + "M";
  if (abs >= 1_000) return (n / 1_000).toFixed(abs >= 10_000 ? 0 : 1) + "K";
  return withThousands(Math.round(n).toString());
}

/** 0..1 → "62%". */
export function formatPct(n: number, dp = 0): string {
  if (!Number.isFinite(n)) return "—";
  return (n * 100).toFixed(dp) + "%";
}

/** A big headline number with an eyebrow label and optional sub-line. */
export function Stat({
  value,
  label,
  sub,
}: {
  value: React.ReactNode;
  label: string;
  sub?: React.ReactNode;
}) {
  return (
    <div className="flex h-full flex-col justify-center">
      <span className="eyebrow">{label}</span>
      <span className="mt-1 font-display text-4xl leading-none text-content-bright tabular-nums">
        {value}
      </span>
      {sub != null && <span className="mt-2 text-sm text-content-mute">{sub}</span>}
    </div>
  );
}

/**
 * A filled area sparkline rendered from cumulative cost samples. Uses a 0..100
 * viewBox so it scales fluidly to any card size (preserveAspectRatio none).
 */
export function Sparkline({
  samples,
  className,
}: {
  samples: CostSample[];
  className?: string;
}) {
  const pts = samples.length
    ? samples
    : [
        { t: 0, cumulativeUsd: 0 },
        { t: 1, cumulativeUsd: 0 },
      ];
  const max = Math.max(...pts.map((p) => p.cumulativeUsd), 1);
  const coords = pts.map((p) => {
    const x = p.t * 100;
    const y = 100 - (p.cumulativeUsd / max) * 92 - 4;
    return [x, y] as const;
  });
  const line = coords.map(([x, y], i) => `${i === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`).join(" ");
  const area = `${line} L100,100 L0,100 Z`;
  return (
    <svg
      viewBox="0 0 100 100"
      preserveAspectRatio="none"
      className={className}
      aria-hidden
      style={{ display: "block", width: "100%", height: "100%" }}
    >
      <defs>
        <linearGradient id="lg-spark-fill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.34" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={area} fill="url(#lg-spark-fill)" />
      <path
        d={line}
        fill="none"
        stroke="var(--accent)"
        strokeWidth="1.6"
        strokeLinejoin="round"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

/** Small horizontal proportion bar (0..1). */
export function ProportionBar({ value }: { value: number }) {
  const pct = Math.min(100, Math.max(0, value * 100));
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-pill bg-mercury-wash">
      <div
        className="h-full rounded-pill"
        style={{ width: pct + "%", background: "var(--accent)" }}
      />
    </div>
  );
}

/** "demo data" pill — shown when a card is backed by the mock seam. */
export function DemoBadge() {
  return (
    <span
      className="rounded-pill px-2 py-0.5 font-mono text-[0.6rem] uppercase tracking-[0.14em] text-content-dim"
      style={{ border: "1px solid var(--color-glass-line)" }}
      title="Synthetic demo data — no live usage feed is wired yet."
    >
      demo data
    </span>
  );
}
