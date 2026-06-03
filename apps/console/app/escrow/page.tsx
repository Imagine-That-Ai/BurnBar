"use client";

import { useCallback } from "react";
import { EscrowFlow } from "@/components/escrow/EscrowFlow";
import { exportUserData } from "@/lib/api";
import { setConsoleVaultKey } from "@/lib/vaultKeySession";

export default function EscrowPage() {
  /**
   * Poll the user's device_trust_keys facet for a wrapper minted to this browser
   * escrow device. The wrapper is an end-to-end domain, so exportUserData returns
   * it inline (the wrapped ciphertext blob is itself opaque to the server). Field
   * names must match the real cloud_vault_key_wrappers schema (firestore.rules):
   * the wrapper is addressed by `targetDeviceId`, the wrapped key is
   * `wrappedVaultKey`, and an active wrapper has status === "active".
   */
  const fetchWrappedKey = useCallback(async (escrowDeviceId: string): Promise<string | null> => {
    const res = await exportUserData(["device_trust_keys"]);
    const domain = res.domains.find((d) => d.id === "device_trust_keys");
    const wrappers = (domain?.inlineJson?.cloud_vault_key_wrappers ?? []) as Array<{
      targetDeviceId?: string;
      wrappedVaultKey?: string;
      status?: string;
    }>;
    const match = wrappers.find((w) => w.targetDeviceId === escrowDeviceId && w.status === "active");
    return match?.wrappedVaultKey ?? null;
  }, []);

  return (
    <div className="mx-auto max-w-2xl space-y-token-6">
      <header className="space-y-token-2">
        <h1 className="font-display text-2xl text-content-bright">Device trust</h1>
        <p className="text-content-mute">
          End-to-end content is sealed with a vault key only your trusted devices hold. Trust this
          browser to read sealed content here — the key is unwrapped in memory and never uploaded.
        </p>
      </header>

      <EscrowFlow
        fetchWrappedKey={fetchWrappedKey}
        onVaultKeyReady={(vaultKey, rawVaultKey) => {
          // The in-memory vault key is now available to decrypt sealed content
          // and cloak Pensieve recall queries. It remains tab-local.
          setConsoleVaultKey(vaultKey, rawVaultKey);
        }}
      />
    </div>
  );
}
