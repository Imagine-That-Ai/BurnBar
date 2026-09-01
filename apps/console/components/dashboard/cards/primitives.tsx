/**
 * Shared, presentational building blocks for dashboard cards.
 *
 * Formatters are hand-rolled (no Intl) on purpose: the console is a static
 * export, and ICU differences between the build-time prerender and the client
 * could otherwise produce a hydration mismatch. All output is deterministic.
 */

import * as React from "react";

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

/**
 * Compact count: "742", "12.3K", "1.2M", "1.09B", "1.09T".
 *
 * Million was the old ceiling, so a trillion-token lifetime total rendered as
 * "1085491M". Billion / trillion keep the headline readable. Deterministic
 * (no Intl) so prerender and client stay byte-identical.
 */
export function formatCompact(n: number): string {
  if (!Number.isFinite(n)) return "—";
  const abs = Math.abs(n);
  if (abs < 1_000) return withThousands(Math.round(n).toString());

  const units = [
    { value: 1_000_000_000_000, suffix: "T", smallDp: 2 },
    { value: 1_000_000_000, suffix: "B", smallDp: 2 },
    { value: 1_000_000, suffix: "M", smallDp: 1 },
    { value: 1_000, suffix: "K", smallDp: 1 },
  ] as const;

  for (let i = 0; i < units.length; i++) {
    const unit = units[i]!;
    if (abs < unit.value) continue;
    const formatted = formatCompactUnit(n, unit.value, unit.suffix, unit.smallDp);
    // 999.6M → 1000M after rounding; bump to the next larger suffix.
    if (Math.abs(Number.parseFloat(formatted)) >= 1000 && i > 0) {
      const next = units[i - 1]!;
      return formatCompactUnit(n, next.value, next.suffix, next.smallDp);
    }
    return formatted;
  }
  return withThousands(Math.round(n).toString());
}

function formatCompactUnit(n: number, divisor: number, suffix: string, smallDp: number): string {
  const scaled = Math.abs(n) / divisor;
  const dp = smallDp === 2 ? (scaled >= 100 ? 0 : scaled >= 10 ? 1 : 2) : scaled >= 10 ? 0 : 1;
  const body = (n / divisor).toFixed(dp).replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, "");
  return body + suffix;
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
 * A filled-area sparkline over an arbitrary numeric series (e.g. daily tokens).
 * Uses a 0..100 viewBox so it scales fluidly to any card size
 * (preserveAspectRatio none). Renders flat when there are <2 points.
 */
export function Sparkline({
  values,
  className,
}: {
  values: number[];
  className?: string;
}) {
  const gradientId = "spark-fill-" + React.useId().replace(/:/g, "");
  const pts = values.length >= 2 ? values : [0, 0];
  const max = Math.max(...pts, 1);
  const lastIndex = pts.length - 1;
  const coords = pts.map((v, i) => {
    const x = lastIndex > 0 ? (i / lastIndex) * 100 : 0;
    const y = 100 - (v / max) * 92 - 4;
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
        <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="var(--accent)" stopOpacity="0.34" />
          <stop offset="100%" stopColor="var(--accent)" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={area} fill={`url(#${gradientId})`} />
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

/** A card's empty state — the eyebrow plus a quiet "no data in this window" line. */
export function EmptyHint({ label, hint }: { label: string; hint?: string }) {
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">{label}</span>
      <div className="flex flex-1 items-center justify-center">
        <span className="text-sm text-content-dim">{hint ?? "Nothing in this window yet."}</span>
      </div>
    </div>
  );
}
