"use client";

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
import { DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE } from "@/lib/api";
import type { DataDomain } from "@/lib/domains";

/**
 * Scoped-delete entry point. Breaking a wax seal is irreversible, so the
 * `deleteDomainData` callable is gated behind trusted-device step-up (a fresh
 * high-risk nonce + a device action proof) that the web console cannot
 * produce. Rather than exposing a confirm flow that is guaranteed to fail the
 * server's precondition, this dialog keeps the member's deletion right
 * discoverable and points at the surface where it actually completes: BurnBar
 * on a trusted device.
 */
export function DeleteDomainDialog({ domain }: { domain: DataDomain }) {
  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button variant="destructive" size="sm">
          Delete
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Deleting “{domain.title}” needs a trusted device</DialogTitle>
          <DialogDescription>
            Breaking the seal permanently deletes this domain&apos;s data
            {domain.encryptionTier === "end_to_end"
              ? " — including genuine ciphertext deletion of sealed content —"
              : ""}{" "}
            and cannot be undone. {DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <DialogClose asChild>
            <Button variant="secondary" size="sm">
              Got it
            </Button>
          </DialogClose>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
