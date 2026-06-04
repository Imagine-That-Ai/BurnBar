"use client";

import { useState } from "react";
import { GitBranch, Lock, Loader2, Laptop } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { connectKnowledgeRepo } from "@/lib/api";
import { RepoDisplayError, sealRepoFullName } from "@/lib/repoDisplay";
import { getConsoleVaultCryptoKey, getConsoleVaultKeyBytes } from "@/lib/vaultKeySession";

/** Stable, deterministic source slug from a repo full name (manifest doc id). */
function repoSourceSlug(repoFullName: string): string {
  return `repo-${repoFullName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")}`;
}

const REPO_PATTERN = /^[^/\s]+\/[^/\s]+$/;

/** Map a connect failure to a member-readable message. */
function connectErrorMessage(err: unknown): string {
  if (err instanceof RepoDisplayError) return err.message;
  const code = (err as { code?: string }).code ?? "";
  const message = (err as { message?: string }).message ?? "";
  if (code.includes("permission-denied") || /cloud pro/i.test(message)) {
    return "Connecting repositories needs an active Cloud Pro plan.";
  }
  if (code.includes("failed-precondition") && message) return message; // e.g. source limit reached
  return "Could not connect the repository. Try again.";
}

export function ConnectRepositoryDialog({
  open,
  onOpenChange,
  onConnected,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConnected: () => void;
}) {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const trimmed = value.trim();
  const valid = REPO_PATTERN.test(trimmed);
  const vaultReady = Boolean(getConsoleVaultKeyBytes() && getConsoleVaultCryptoKey());

  function reset() {
    setValue("");
    setError(null);
    setBusy(false);
  }

  async function submit() {
    if (!valid) {
      setError("Enter a repository as owner/name.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const sealedRepoFullName = await sealRepoFullName(trimmed);
      await connectKnowledgeRepo({
        repoFullName: trimmed,
        sealedRepoFullName,
        sourceSlug: repoSourceSlug(trimmed),
      });
      reset();
      onConnected();
      onOpenChange(false);
    } catch (err) {
      setError(connectErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) reset();
        onOpenChange(next);
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="flex items-center gap-token-2">
            <span className="grid size-7 place-items-center rounded-md bg-tier-end-to-end/10 text-tier-end-to-end">
              <GitBranch className="size-4" />
            </span>
            Connect a repository
          </DialogTitle>
          <DialogDescription>
            Give your agents private memory from a repo&apos;s docs. Connecting registers it for
            push-triggered re-sync — the reading, chunking, and sealing all happen privately on your
            Mac.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-token-3">
          <label className="block space-y-1.5">
            <span className="text-xs font-medium uppercase tracking-wide text-content-mute">
              Repository
            </span>
            <input
              autoFocus
              className="w-full rounded-md border border-glass-line bg-panel-subtle px-token-3 py-2 font-mono text-sm text-content-bright outline-none transition focus:border-tier-end-to-end/60 placeholder:text-content-dim"
              value={value}
              onChange={(event) => {
                setValue(event.target.value);
                if (error) setError(null);
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter" && valid && !busy && vaultReady) void submit();
              }}
              placeholder="owner/name  ·  e.g. acme/handbook"
              spellCheck={false}
              autoComplete="off"
            />
          </label>

          <div className="flex items-start gap-2 rounded-md border border-glass-line bg-mercury-wash p-token-3 text-xs text-content-mute">
            <Lock className="mt-0.5 size-3.5 shrink-0 text-tier-end-to-end" />
            <span>
              We store only a <span className="text-content-bright">sealed name</span> plus an opaque
              keyed match token. The cleartext name is used for a moment to route GitHub webhooks,
              then discarded — never written to your data tree.
            </span>
          </div>

          {!vaultReady && (
            <div className="flex items-start gap-2 rounded-md border border-amber-400/40 bg-amber-400/10 p-token-3 text-xs text-amber-500">
              <Laptop className="mt-0.5 size-3.5 shrink-0" />
              <span>
                Trust this browser first so your vault key can seal the repository name before it
                leaves the page.
              </span>
            </div>
          )}

          {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)} disabled={busy}>
            Cancel
          </Button>
          <Button onClick={() => void submit()} disabled={!valid || busy || !vaultReady}>
            {busy ? <Loader2 className="size-4 animate-spin" /> : <GitBranch className="size-4" />}
            {busy ? "Connecting…" : "Connect repository"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
