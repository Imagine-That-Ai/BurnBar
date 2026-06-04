"use client";

import { useState } from "react";
import {
  GitBranch,
  RefreshCw,
  Loader2,
  Check,
  Laptop,
  Lock,
  Trash2,
  Plus,
  Sparkles,
} from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { disconnectKnowledgeRepo, requestKnowledgeResync, type DataTier } from "@/lib/api";
import { formatBytes, formatCount, formatRelativeTime } from "@/lib/utils";
import type { PensieveRepo } from "@/lib/usePensieveRepos";
import { ConnectRepositoryDialog } from "./ConnectRepositoryDialog";

type SyncState = "synced" | "queued" | "waiting";

function syncStateOf(repo: PensieveRepo): SyncState {
  if (repo.needsResync) return "queued";
  if (repo.lastSyncAt && repo.chunkCount > 0) return "synced";
  return "waiting";
}

function StatusPill({ repo }: { repo: PensieveRepo }) {
  const state = syncStateOf(repo);
  if (state === "synced") {
    return (
      <Badge tier="end_to_end" title={`Last sealed ${formatRelativeTime(repo.lastSyncAt)}`}>
        <Check className="size-3" /> Synced
      </Badge>
    );
  }
  if (state === "queued") {
    return (
      <span className="inline-flex items-center gap-1.5 rounded-pill border border-amber-400/40 bg-amber-400/10 px-2.5 py-0.5 font-mono text-xs font-medium tracking-tight text-amber-500">
        <RefreshCw className="size-3" /> Re-sync queued
      </span>
    );
  }
  return (
    <Badge tier="neutral" title="Indexing runs on your Mac — open BurnBar there to seal this repo">
      <Laptop className="size-3" /> Waiting for your Mac
    </Badge>
  );
}

function RepoRow({
  repo,
  busy,
  onDisconnect,
}: {
  repo: PensieveRepo;
  busy: boolean;
  onDisconnect: () => void;
}) {
  const name = repo.displayName ?? (repo.nameLocked ? "Locked repository" : "Sealed repository");
  const synced = syncStateOf(repo) === "synced";
  return (
    <div className="flex items-center gap-token-3 rounded-md border border-glass-line bg-mercury-wash px-token-3 py-token-3">
      <span className="grid size-9 shrink-0 place-items-center rounded-md bg-tier-end-to-end/10 text-tier-end-to-end">
        <GitBranch className="size-4" />
      </span>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="truncate font-mono text-sm text-content-bright">{name}</span>
          {repo.nameLocked && <Lock className="size-3 shrink-0 text-content-dim" />}
        </div>
        <p className="mt-0.5 truncate text-xs text-content-mute">
          {synced ? (
            <>
              {formatCount(repo.chunkCount)} chunks · {formatBytes(repo.byteCount)} · sealed{" "}
              {formatRelativeTime(repo.lastSyncAt)}
            </>
          ) : repo.needsResync ? (
            <>Re-sync queued — your Mac will re-seal on its next pass</>
          ) : (
            <>Connected {formatRelativeTime(repo.connectedAt)} · not sealed yet</>
          )}
        </p>
      </div>
      <StatusPill repo={repo} />
      <button
        type="button"
        onClick={onDisconnect}
        disabled={busy}
        title="Disconnect (stops push-sync; already-sealed memory is kept)"
        className="grid size-8 shrink-0 place-items-center rounded-md text-content-dim transition hover:bg-panel-subtle hover:text-[color:var(--color-seal-crimson)] disabled:opacity-50"
      >
        {busy ? <Loader2 className="size-4 animate-spin" /> : <Trash2 className="size-4" />}
      </button>
    </div>
  );
}

export function PensieveSourcesCard({
  tier,
  repos,
  loading,
  reloadRepos,
  reloadUsage,
}: {
  tier: DataTier;
  repos: PensieveRepo[] | null;
  loading: boolean;
  reloadRepos: () => void;
  reloadUsage: () => void;
}) {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [busyRepoId, setBusyRepoId] = useState<string | null>(null);
  const [resyncing, setResyncing] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const isFree = tier === "free";
  const hasRepos = (repos?.length ?? 0) > 0;

  function refresh() {
    reloadRepos();
    reloadUsage();
  }

  async function disconnect(repoId: string) {
    setBusyRepoId(repoId);
    setError(null);
    try {
      await disconnectKnowledgeRepo(repoId);
      refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not disconnect that repo.");
    } finally {
      setBusyRepoId(null);
    }
  }

  async function resync() {
    setResyncing(true);
    setNote(null);
    setError(null);
    try {
      const result = await requestKnowledgeResync();
      setNote(
        result.flagged > 0
          ? `Re-sync queued for ${result.flagged} source${result.flagged === 1 ? "" : "s"} — your Mac will re-seal them.`
          : "No connected repos to re-sync yet.",
      );
      refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not queue a re-sync.");
    } finally {
      setResyncing(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Sources</CardTitle>
        <CardDescription>
          Connect a repository to give your agents private memory. Your Mac reads, chunks, and seals
          it on-device — the browser and our servers never see your code.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-token-4">
        <div className="flex flex-wrap items-center gap-token-2">
          <Button
            onClick={() => setDialogOpen(true)}
            disabled={isFree}
            title={isFree ? "Cloud Pro required" : "Connect a GitHub repository"}
          >
            <Plus className="size-4" /> Connect repository
          </Button>
          <Button variant="ghost" onClick={resync} disabled={resyncing || !hasRepos}>
            {resyncing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
            {resyncing ? "Queuing…" : "Sync now"}
          </Button>
        </div>

        {isFree && (
          <div className="flex items-start gap-2 rounded-md border border-tier-end-to-end/30 bg-tier-end-to-end/5 p-token-3 text-sm text-content-mute">
            <Sparkles className="mt-0.5 size-4 shrink-0 text-tier-end-to-end" />
            <span>
              <span className="text-content-bright">Cloud Pro</span> unlocks private agent memory —
              10 repositories, 50,000 sealed chunks, and 1 GB your agents can recall.
            </span>
          </div>
        )}

        {note && <p className="text-xs text-tier-end-to-end">{note}</p>}
        {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}

        {loading && repos === null ? (
          <div className="flex items-center justify-center gap-2 rounded-md border border-dashed border-glass-line p-token-6 text-sm text-content-mute">
            <Loader2 className="size-4 animate-spin" /> Loading connected repositories…
          </div>
        ) : hasRepos ? (
          <div className="space-y-token-2">
            {repos!.map((repo) => (
              <RepoRow
                key={repo.repoId}
                repo={repo}
                busy={busyRepoId === repo.repoId}
                onDisconnect={() => void disconnect(repo.repoId)}
              />
            ))}
          </div>
        ) : (
          <div className="rounded-md border border-dashed border-glass-line p-token-6 text-center text-sm text-content-mute">
            No repositories connected yet. Connect one to give your agents private memory.
          </div>
        )}

        <p className="flex items-start gap-1.5 text-xs text-content-dim">
          <Lock className="mt-0.5 size-3 shrink-0" />
          Repository names are sealed on your device before they leave the browser. The server stores
          only an opaque keyed match token plus the sealed name; the names above are decrypted locally
          from <code className="font-mono">sealedRepoFullName</code>.
        </p>
      </CardContent>

      <ConnectRepositoryDialog open={dialogOpen} onOpenChange={setDialogOpen} onConnected={refresh} />
    </Card>
  );
}
