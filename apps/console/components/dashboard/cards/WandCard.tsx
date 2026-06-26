import type { CardProps } from "../cardTypes";
import { EmptyHint, Stat, formatCompact } from "./primitives";

export function WandCard({ data }: CardProps) {
  const fusion = data.fusion;
  if (!fusion) {
    return <EmptyHint label="The Wand" hint="Fusion allowance unavailable." />;
  }
  const usedFrac = fusion.available > 0 ? Math.min(1, fusion.used / fusion.available) : 0;
  return (
    <div className="flex h-full flex-col">
      <Stat
        value={
          <span className="text-tier-end-to-end">{formatCompact(fusion.remaining)}</span>
        }
        label="The Wand · searches left"
        sub={`${formatCompact(fusion.used)} of ${formatCompact(fusion.available)} used · ${fusion.monthKey}`}
      />
      <div className="mt-3">
        <div className="h-2 w-full overflow-hidden rounded-pill bg-mercury-wash">
          <div
            className="h-full rounded-pill"
            style={{ width: Math.max(2, usedFrac * 100) + "%", background: "var(--accent)" }}
          />
        </div>
        {fusion.purchased > 0 && (
          <p className="mt-2 text-xs text-content-mute">
            includes {formatCompact(fusion.purchased)} purchased this month
          </p>
        )}
      </div>
    </div>
  );
}
