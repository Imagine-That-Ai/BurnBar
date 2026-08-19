import type { DataTier } from "@/lib/api";

const CRESTS: Partial<Record<DataTier, string>> = {
  pro: "/brand/burnbar_cloud_pro_crest.svg",
  ultra: "/brand/burnbar_cloud_ultra_crest.svg",
};

/**
 * Membership tier lockup. The cloud crest is the visual anchor — large, in an
 * accent-washed tile — with the tier name stacked beside it, container-free.
 * Free tier has no crest and stays a plain quiet pill.
 */
export function PlanBadge({ tier }: { tier: DataTier }) {
  const crest = CRESTS[tier];

  if (!crest) {
    return (
      <span className="rounded-pill border border-glass-line bg-mercury-wash px-token-3 py-1 text-xs uppercase tracking-wide text-content-mute">
        {tier} plan
      </span>
    );
  }

  return (
    <span className="flex items-center gap-2.5">
      <span
        className="grid size-10 shrink-0 place-items-center rounded-lg border border-glass-line-bright"
        style={{ background: "var(--accent-wash)" }}
      >
        <img src={crest} alt="" className="size-8 object-contain" />
      </span>
      <span className="leading-tight">
        <span className="block font-display text-base font-semibold capitalize text-content-bright">
          {tier}
        </span>
        <span className="folio block text-[0.58rem]">plan</span>
      </span>
    </span>
  );
}
