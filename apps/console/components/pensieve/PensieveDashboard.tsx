"use client";

import { Brain, GitBranch, Boxes, HardDrive } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { TierBadge } from "@/components/inventory/TierBadge";
import { dataDomain } from "@/lib/domains";
import { useDomainUsage, usageById } from "@/lib/useDomainUsage";
import { usePensieveRepos } from "@/lib/usePensieveRepos";
import { formatBytes, formatCount } from "@/lib/utils";
import { PensieveSourcesCard } from "./PensieveSourcesCard";
import { PensieveRecallCard } from "./PensieveRecallCard";

const PENSIEVE = dataDomain("pensieve")!;

function Meter({
  icon: Icon,
  label,
  used,
  limit,
  format,
}: {
  icon: typeof Boxes;
  label: string;
  used: number;
  limit: number;
  format: (n: number) => string;
}) {
  const ratio = limit > 0 ? used / limit : 0;
  const over = ratio > 1;
  const pct = limit > 0 ? Math.min(999, Math.round(ratio * 100)) : 0;
  return (
    <div className="space-y-1.5">
      <div className="flex items-baseline justify-between gap-token-2 text-sm">
        <span className="flex items-center gap-1.5 text-content-mute">
          <Icon className="size-3.5 text-content-dim" />
          {label}
        </span>
        <span className="flex items-baseline gap-2">
          <span className={over ? "font-mono text-[color:var(--color-seal-crimson)]" : "font-mono text-content-bright"}>
            {format(used)} <span className="text-content-dim">/ {format(limit)}</span>
          </span>
          <span className="w-9 text-right font-mono text-xs text-content-dim">{pct}%</span>
        </span>
      </div>
      <Progress
        value={ratio}
        fillVar={over ? "--color-seal-crimson" : "--color-tier-end-to-end"}
      />
    </div>
  );
}

/**
 * The Pensieve dashboard: quota meters vs the member's tier limits, the connected
 * repo Sources panel (connect / sync / disconnect), and local-only Recall. Repo
 * names are sealed end-to-end and decrypted in the browser; the source count in
 * the quota reflects the live connected-repo list.
 */
export function PensieveDashboard() {
  const { data, loading, reload } = useDomainUsage();
  const { repos, loading: reposLoading, reload: reloadRepos } = usePensieveRepos();

  const byId = usageById(data);
  const usage = byId["pensieve"] ?? { count: 0, bytes: 0 };
  const limits = data?.limits.pensieve ?? { sources: 0, chunks: 0, bytes: 0 };
  const tier = data?.tier ?? "free";
  const sourceCount = repos?.length ?? 0;

  return (
    <div className="space-y-token-6">
      <header className="flex flex-wrap items-start justify-between gap-token-3">
        <div className="flex items-center gap-token-3">
          <span className="grid size-11 place-items-center rounded-lg bg-tier-end-to-end/10 text-tier-end-to-end">
            <Brain className="size-6" />
          </span>
          <div className="max-w-2xl">
            <div className="flex items-center gap-token-2">
              <h1 className="font-display text-2xl text-content-bright">{PENSIEVE.title}</h1>
              <TierBadge tier={PENSIEVE.encryptionTier} />
            </div>
            <p className="mt-0.5 text-sm text-content-mute">{PENSIEVE.summary}</p>
          </div>
        </div>
        <span className="flex items-center gap-1.5 rounded-pill border border-glass-line bg-mercury-wash px-token-3 py-1 text-xs uppercase tracking-wide text-content-mute">
          {(tier === "pro" || tier === "ultra") && (
            <img
              src={
                tier === "ultra"
                  ? "/brand/burnbar_cloud_ultra_crest.svg"
                  : "/brand/burnbar_cloud_pro_crest.svg"
              }
              alt=""
              className="size-5 overflow-hidden object-contain"
            />
          )}
          {tier} plan
        </span>
      </header>

      <Card>
        <CardHeader>
          <CardTitle>Quota</CardTitle>
          <CardDescription>
            Your sealed knowledge against your {tier} limits. Vectors are cloaked and text is
            sealed — the server runs search without reading either.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-token-4">
          <Meter
            icon={GitBranch}
            label="Sources"
            used={reposLoading && repos === null ? 0 : sourceCount}
            limit={limits.sources}
            format={formatCount}
          />
          <Meter
            icon={Boxes}
            label="Chunks"
            used={loading ? 0 : usage.count}
            limit={limits.chunks}
            format={formatCount}
          />
          <Meter
            icon={HardDrive}
            label="Storage"
            used={loading ? 0 : usage.bytes}
            limit={limits.bytes}
            format={formatBytes}
          />
        </CardContent>
      </Card>

      <PensieveSourcesCard
        tier={tier}
        repos={repos}
        loading={reposLoading}
        reloadRepos={reloadRepos}
        reloadUsage={reload}
      />

      <PensieveRecallCard />
    </div>
  );
}
