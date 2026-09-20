import type { CardProps } from "../cardTypes";
import type { QuotaBucket, QuotaSnapshot } from "@/lib/usage";
import { ProviderMark } from "./ProviderMark";
import { EmptyHint, ProportionBar, formatCompact } from "./primitives";

function formatProviderName(raw: string): string {
  const lower = raw.toLowerCase().trim();
  if (lower === "claudecode" || lower === "claude-code" || lower === "claude code") return "Claude Code";
  if (lower === "antigravity") return "Antigravity";
  if (lower === "opencode" || lower === "open-code") return "OpenCode";
  if (lower === "codex") return "Codex";
  if (lower === "factory") return "Factory";
  if (lower === "minimax") return "MiniMax";
  if (lower === "zai") return "Zai";
  return raw.replace(/[-_]/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

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
  const rawSnaps = data.quotas.filter((q) => q.buckets.length > 0);
  if (rawSnaps.length === 0) {
    return <EmptyHint label="Provider limits" hint="No provider quotas synced." />;
  }

  // Deduplicate identical quota snapshots from stale or duplicate device syncs
  const snaps = rawSnaps.reduce<QuotaSnapshot[]>((acc, snap) => {
    const pKey = snap.provider.toLowerCase().replace(/[^a-z0-9]/g, "");
    const b = headlineBucket(snap);
    const bKey = b ? `${b.used}_${b.limit}_${b.window ?? ""}` : "empty";
    const key = `${pKey}_${snap.accountLabel ?? ""}_${bKey}`;
    const existingIndex = acc.findIndex((s) => {
      const sPKey = s.provider.toLowerCase().replace(/[^a-z0-9]/g, "");
      const sB = headlineBucket(s);
      const sBKey = sB ? `${sB.used}_${sB.limit}_${sB.window ?? ""}` : "empty";
      return `${sPKey}_${s.accountLabel ?? ""}_${sBKey}` === key;
    });
    if (existingIndex < 0) {
      acc.push(snap);
    } else {
      const existingDate = acc[existingIndex].updatedAt ? new Date(acc[existingIndex].updatedAt!).getTime() : 0;
      const newDate = snap.updatedAt ? new Date(snap.updatedAt).getTime() : 0;
      if (newDate > existingDate) {
        acc[existingIndex] = snap;
      }
    }
    return acc;
  }, []);

  return (
    <div className="flex h-full flex-col">
      <span className="eyebrow">Provider limits</span>
      <ul className="mt-2 min-h-0 flex-1 space-y-3 overflow-y-auto pr-1">
        {snaps.map((snap, idx) => {
          const b = headlineBucket(snap);
          const bounded = b && b.limit > 0;
          const usedFrac = bounded ? Math.min(1, Math.max(0, b.used / b.limit)) : 0;
          const isExceeded = bounded && b.used >= b.limit;
          const name = formatProviderName(snap.provider);
          const subLabel = snap.accountLabel || b?.window || b?.unit;

          return (
            <li key={`${snap.providerID ?? snap.provider}-${idx}`} className="flex items-center gap-token-3">
              <ProviderMark id={snap.provider} label={name} />
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-2">
                  <div className="flex items-center gap-1.5 min-w-0 truncate">
                    <span className="truncate text-xs font-medium text-content-base">
                      {name}
                    </span>
                    {subLabel && (
                      <span className="shrink-0 text-[10px] text-content-dim font-mono">
                        ({subLabel})
                      </span>
                    )}
                  </div>
                  <span className={`shrink-0 font-mono text-xs tabular-nums ${isExceeded ? "text-[color:var(--color-seal-crimson)] font-semibold" : "text-content-mute"}`}>
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
