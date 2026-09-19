"use client";

/**
 * Token-mix panel for the active range: input / output / cache-read /
 * cache-write / reasoning shares from bounded event aggregates. The footer
 * admits the rollup cannot answer this; the event path can.
 */

import { formatCompact, ProportionBar } from "@/components/dashboard/cards/primitives";
import type { TokenMix } from "@/lib/profile/profileAggregates";

const SEGMENTS: {
  key: keyof Omit<TokenMix, "total">;
  label: string;
  color: string;
}[] = [
  { key: "input", label: "Input", color: "var(--accent)" },
  { key: "output", label: "Output", color: "#CC785C" },
  { key: "cacheRead", label: "Cache read", color: "#38D898" },
  { key: "cacheWrite", label: "Cache write", color: "#F0C040" },
  { key: "reasoning", label: "Reasoning", color: "#8B7FE8" },
];

export function ProfileMixPanel({
  mix,
  loading,
  error,
}: {
  mix: TokenMix | null;
  loading: boolean;
  error: string | null;
}) {
  const total = mix?.total ?? 0;
  return (
    <section aria-label="Token mix">
      <div className="mb-token-1 flex items-baseline justify-between gap-token-4">
        <h2 className="eyebrow">Token mix</h2>
        <span className="text-xs text-content-dim">
          {loading ? "reading…" : total > 0 ? `${formatCompact(total)} tok` : ""}
        </span>
      </div>
      {error || !mix || total <= 0 ? (
        <p className="rounded-lg border border-glass-line px-token-3 py-token-4 text-sm text-content-dim">
          {error
            ? `Could not read usage events (${error}).`
            : loading
              ? "Reading the active range…"
              : "No token mix in this range yet."}
        </p>
      ) : (
        <>
          <div
            role="img"
            aria-label={SEGMENTS.map(
              (s) => `${s.label} ${Math.round(((mix[s.key] ?? 0) / total) * 100)}%`,
            ).join(", ")}
            className="flex h-2.5 gap-[3px] overflow-hidden rounded-pill"
          >
            {SEGMENTS.map((s) => {
              const v = mix[s.key] ?? 0;
              if (v <= 0) return null;
              return (
                <span
                  key={s.key}
                  title={`${s.label} — ${formatCompact(v)} tok`}
                  className="h-full"
                  style={{ width: `${(v / total) * 100}%`, background: s.color }}
                />
              );
            })}
          </div>
          <ul className="mt-token-3 space-y-token-2">
            {SEGMENTS.map((s) => {
              const v = mix[s.key] ?? 0;
              if (v <= 0) return null;
              return (
                <li key={s.key} className="flex items-center gap-2 text-sm">
                  <span
                    aria-hidden
                    className="h-[10px] w-[10px] shrink-0 rounded-pill"
                    style={{ background: s.color }}
                  />
                  <span className="truncate text-content-bright">{s.label}</span>
                  <span className="min-w-0 flex-1">
                    <ProportionBar value={v / total} color={s.color} />
                  </span>
                  <span className="min-w-[4rem] shrink-0 whitespace-nowrap text-right text-content-mute tabular-nums">
                    {formatCompact(v)}
                  </span>
                </li>
              );
            })}
          </ul>
        </>
      )}
    </section>
  );
}
