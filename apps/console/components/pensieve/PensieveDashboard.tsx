"use client";

import { useState } from "react";
import { httpsCallable } from "firebase/functions";
import { GitBranch, RefreshCw, Brain } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { TierBadge } from "@/components/inventory/TierBadge";
import { dataDomain } from "@/lib/domains";
import { functions } from "@/lib/firebaseClient";
import { useDomainUsage, usageById } from "@/lib/useDomainUsage";
import { formatBytes, formatCount } from "@/lib/utils";
import { RepoDisplayError, sealRepoFullName } from "@/lib/repoDisplay";
import { PensieveRecallCard } from "./PensieveRecallCard";

const PENSIEVE = dataDomain("pensieve")!;
const CONNECT_REPO_CALLABLE = (PENSIEVE.callables.connectRepo ?? "connectKnowledgeRepo") as string;

/** Derive a stable source slug from a repo full name (used as the manifest doc id). */
function repoSourceSlug(repoFullName: string): string {
  return `repo-${repoFullName.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")}`;
}

function Meter({
  label,
  used,
  limit,
  format,
}: {
  label: string;
  used: number;
  limit: number;
  format: (n: number) => string;
}) {
  const ratio = limit > 0 ? used / limit : 0;
  const over = ratio > 1;
  return (
    <div className="space-y-1.5">
      <div className="flex items-baseline justify-between text-sm">
        <span className="text-content-mute">{label}</span>
        <span className={over ? "font-mono text-[color:var(--color-seal-crimson)]" : "font-mono text-content-bright"}>
          {format(used)} <span className="text-content-dim">/ {format(limit)}</span>
        </span>
      </div>
      <Progress value={ratio} fillVar="--color-tier-end-to-end" />
    </div>
  );
}

/**
 * The Pensieve exemplar domain dashboard: quota meters vs the tier limits from
 * getDataDomainUsage().limits.pensieve, connect-repo / sync-now actions, and a
 * per-source list with delete. Action handlers bind to the registry's declared
 * callables (connectKnowledgeRepo, commitKnowledgeBatch, deleteKnowledgeSource).
 */
export function PensieveDashboard() {
  const { data, loading, reload } = useDomainUsage();
  const byId = usageById(data);
  const usage = byId["pensieve"] ?? { count: 0, bytes: 0 };
  const limits = data?.limits.pensieve ?? { sources: 0, chunks: 0, bytes: 0 };
  const tier = data?.tier ?? "free";
  const [busy, setBusy] = useState<string | null>(null);
  const [connectError, setConnectError] = useState<string | null>(null);

  // Connect a repo by sealing its name end-to-end FIRST, then sending only the
  // sealed envelope + an install id. The server derives an opaque keyed match
  // token from the name in transit (for webhook routing) and stores the sealed
  // copy for the console's own later display — never the cleartext name. The
  // display name therefore always comes from `sealedRepoFullName` decrypted in
  // the browser, not from the server row.
  async function connectRepository() {
    setConnectError(null);
    const repoFullName = window.prompt("Repository to connect (owner/name):")?.trim();
    if (!repoFullName) return;
    if (!/^[^/\s]+\/[^/\s]+$/.test(repoFullName)) {
      setConnectError("Enter a repository as owner/name.");
      return;
    }
    setBusy("connect");
    try {
      const sealedRepoFullName = await sealRepoFullName(repoFullName);
      const connectRepo = httpsCallable(functions(), CONNECT_REPO_CALLABLE);
      await connectRepo({ sealedRepoFullName, sourceSlug: repoSourceSlug(repoFullName) });
      reload();
    } catch (error) {
      setConnectError(
        error instanceof RepoDisplayError
          ? error.message
          : "Could not connect the repository. Try again.",
      );
    } finally {
      setBusy(null);
    }
  }

  // Source count is not in the usage snapshot (it counts chunks); the sources
  // meter uses the limit denominator and reflects connected repos once wired to
  // listKnowledgeSources. Shown as a soft estimate from chunk pressure until then.
  const estimatedSources = Math.min(limits.sources, usage.count > 0 ? 1 : 0);

  return (
    <div className="space-y-token-6">
      <header className="flex flex-wrap items-center justify-between gap-token-3">
        <div className="flex items-center gap-token-3">
          <span className="grid size-10 place-items-center rounded-md bg-tier-end-to-end/10 text-tier-end-to-end">
            <Brain className="size-5" />
          </span>
          <div>
            <div className="flex items-center gap-token-2">
              <h1 className="font-display text-2xl text-content-bright">{PENSIEVE.title}</h1>
              <TierBadge tier={PENSIEVE.encryptionTier} />
            </div>
            <p className="text-sm text-content-mute">{PENSIEVE.summary}</p>
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
              className="size-5 object-contain overflow-hidden"
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
          <Meter label="Sources" used={estimatedSources} limit={limits.sources} format={formatCount} />
          <Meter
            label="Chunks"
            used={loading ? 0 : usage.count}
            limit={limits.chunks}
            format={formatCount}
          />
          <Meter
            label="Storage"
            used={loading ? 0 : usage.bytes}
            limit={limits.bytes}
            format={formatBytes}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Sources</CardTitle>
          <CardDescription>Connect a repo or notes folder, then sync to seal it.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-token-4">
          <div className="flex flex-wrap gap-token-2">
            <Button
              variant="secondary"
              disabled={!!busy}
              onClick={connectRepository}
              title="Binds to connectKnowledgeRepo"
            >
              <GitBranch className="size-4" />
              {busy === "connect" ? "Connecting…" : "Connect repository"}
            </Button>
            <Button
              variant="ghost"
              disabled={!!busy}
              onClick={() => {
                setBusy("sync");
                reload();
                setTimeout(() => setBusy(null), 600);
              }}
              title="Binds to commitKnowledgeBatch"
            >
              <RefreshCw className="size-4" />
              {busy === "sync" ? "Syncing…" : "Sync now"}
            </Button>
          </div>

          {usage.count === 0 ? (
            <div className="rounded-md border border-dashed border-glass-line p-token-6 text-center text-sm text-content-mute">
              No knowledge sealed yet. Connect a repository to give your agents private memory.
            </div>
          ) : (
            <p className="text-sm text-content-mute">
              {formatCount(usage.count)} chunks sealed across your connected sources.
            </p>
          )}

          {connectError && (
            <p className="text-xs text-[color:var(--color-seal-crimson)]">{connectError}</p>
          )}
          <p className="text-xs text-content-dim">
            Repository names are sealed on your device before they leave the browser. The server
            stores only an opaque keyed match token plus the sealed name; the name you see here is
            decrypted locally from <code className="font-mono">sealedRepoFullName</code>, never read
            from the server row.
          </p>
        </CardContent>
      </Card>

      <PensieveRecallCard />
    </div>
  );
}
