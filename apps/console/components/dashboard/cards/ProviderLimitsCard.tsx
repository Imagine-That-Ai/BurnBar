import type { CardProps } from "../cardTypes";
import type { QuotaBucket, QuotaSnapshot } from "@/lib/usage";
import { ProviderMark } from "./ProviderMark";
import { EmptyHint, ProportionBar, formatCompact } from "./primitives";

/** Pick the most meaningful bounded bucket from a snapshot for the headline bar. */
function headlineBucket(snap: QuotaSnapshot): QuotaBucket | undefined {
  const bounded = snap.buckets.filter((b) => b.limit > 0);
  if (bounded.length === 0) return snap.buckets[0];
  // The tightest remaining ratio is the one worth surfacing.
  return bounded.reduce((tight, b) =>
    b.remaining / b.limit < tight.remaining / tight.limit ? b : tight,
  );
}

export function ProviderLimitsCard({ data }: CardProps) {
  const snaps = data.quotas.filter((q) => q.buckets.length > 0);
  if (snaps.length === 0) {
    return <EmptyHint label="Provider limits" hint="No provider quotas synced." />;
  }
  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Provider limits</span>
      <ul className="mt-2 min-h-0 flex-1 space-y-2.5 overflow-y-auto pr-1">
        {snaps.map((snap) => {
          const b = headlineBucket(snap);
          const bounded = b && b.limit > 0;
          const usedFrac = bounded ? Math.min(1, b.used / b.limit) : 0;
          return (
            <li key={`${snap.providerID ?? snap.provider}-${snap.accountLabel ?? ""}`} className="flex items-center gap-token-3">
              <ProviderMark id={snap.provider} label={snap.provider} />
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="truncate text-sm capitalize text-content-base">
                    {snap.provider}
                  </span>
                  <span className="shrink-0 font-mono text-xs text-content-mute tabular-nums">
                    {bounded
                      ? `${formatCompact(b!.used)} / ${formatCompact(b!.limit)}`
                      : "no cap"}
                  </span>
                </div>
                <div className="mt-1">
                  <ProportionBar value={usedFrac} />
                </div>
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
