"use client";

import { useState } from "react";
import { ShieldAlert } from "lucide-react";
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
import { revokeAllAccess, type RevokeAllAccessResponse } from "@/lib/api";

/**
 * PANIC — revokeAllAccess. Aggregates the per-surface revoke callables. "Sync"
 * cuts cloud sync clients; "all" additionally drops devices, escrow trust, and
 * providers. Only place beyond delete where the crimson destructive token shows.
 */
export function PanicButton() {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<"sync" | "all" | null>(null);
  const [result, setResult] = useState<RevokeAllAccessResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const run = async (scope: "sync" | "all") => {
    setBusy(scope);
    setError(null);
    try {
      setResult(await revokeAllAccess(scope));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Revoke failed.");
    } finally {
      setBusy(null);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => { setOpen(o); if (!o) { setResult(null); setError(null); } }}>
      <DialogTrigger asChild>
        <Button variant="destructive" size="sm">
          <ShieldAlert className="size-3.5" />
          Panic
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Cut off access</DialogTitle>
          <DialogDescription>
            Instantly revoke access across your account. Your sealed data stays sealed; you
            re-grant trust to each device or agent afterwards.
          </DialogDescription>
        </DialogHeader>

        {result ? (
          <ul className="space-y-1 text-sm text-content-base">
            <li>MCP clients revoked: <b className="font-mono">{result.revoked.mcpClients}</b></li>
            <li>Devices revoked: <b className="font-mono">{result.revoked.devices}</b></li>
            <li>Escrow devices revoked: <b className="font-mono">{result.revoked.escrowDevices}</b></li>
            <li>Providers revoked: <b className="font-mono">{result.revoked.providers}</b></li>
          </ul>
        ) : (
          <div className="space-y-token-3">
            <p className="text-sm text-content-mute">
              <b className="text-content-base">Stop sync</b> cuts cloud sync clients only.{" "}
              <b className="text-content-base">Revoke everything</b> also drops paired devices,
              browser/device trust, and connected providers.
            </p>
            {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}
          </div>
        )}

        <DialogFooter>
          {result ? (
            <DialogClose asChild>
              <Button variant="secondary" size="sm">Done</Button>
            </DialogClose>
          ) : (
            <>
              <Button variant="ghost" size="sm" disabled={!!busy} onClick={() => run("sync")}>
                {busy === "sync" ? "Stopping…" : "Stop sync"}
              </Button>
              <Button variant="destructive" size="sm" disabled={!!busy} onClick={() => run("all")}>
                {busy === "all" ? "Revoking…" : "Revoke everything"}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
