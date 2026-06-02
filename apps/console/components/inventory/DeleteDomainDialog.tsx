"use client";

import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
  DialogClose,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { deleteDomainData, type DeleteDomainDataResponse } from "@/lib/api";
import type { DataDomain } from "@/lib/domains";

/**
 * Scoped-delete confirmation. Breaking a wax seal is irreversible — the only
 * place the crimson destructive token appears. Requires typing the domain title
 * to confirm (defence against fat-finger deletes).
 */
export function DeleteDomainDialog({
  domain,
  onDeleted,
}: {
  domain: DataDomain;
  onDeleted?: (res: DeleteDomainDataResponse) => void;
}) {
  const [open, setOpen] = useState(false);
  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const armed = confirmText.trim().toLowerCase() === domain.title.toLowerCase();

  const onConfirm = async () => {
    if (!armed) return;
    setBusy(true);
    setError(null);
    try {
      const res = await deleteDomainData(domain.id);
      onDeleted?.(res);
      setOpen(false);
      setConfirmText("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Delete failed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="destructive" size="sm">
          Delete
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Break the seal on “{domain.title}”?</DialogTitle>
          <DialogDescription>
            This permanently deletes this domain&apos;s data
            {domain.encryptionTier === "end_to_end"
              ? " — including genuine ciphertext deletion of sealed content."
              : "."}{" "}
            This cannot be undone.
          </DialogDescription>
        </DialogHeader>
        <label className="text-xs text-content-mute">
          Type <span className="font-mono text-content-bright">{domain.title}</span> to confirm
          <input
            value={confirmText}
            onChange={(e) => setConfirmText(e.target.value)}
            className="mt-1 w-full rounded-md border border-glass-line bg-ink-base px-token-3 py-token-2 font-mono text-sm text-content-bright outline-none focus:border-[color:var(--color-seal-crimson)]"
            placeholder={domain.title}
            autoComplete="off"
          />
        </label>
        {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}
        <DialogFooter>
          <DialogClose asChild>
            <Button variant="ghost" size="sm">
              Cancel
            </Button>
          </DialogClose>
          <Button variant="destructive" size="sm" disabled={!armed || busy} onClick={onConfirm}>
            {busy ? "Deleting…" : "Delete permanently"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
