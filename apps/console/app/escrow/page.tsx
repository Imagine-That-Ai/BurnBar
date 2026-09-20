"use client";

import { useCallback } from "react";
import { collection, query, where, getDocs } from "firebase/firestore";
import { EscrowFlow } from "@/components/escrow/EscrowFlow";
import { db, auth } from "@/lib/firebaseClient";
import { setConsoleVaultKey } from "@/lib/vaultKeySession";

export default function EscrowPage() {
  /**
   * Poll the user's cloud_vault_key_wrappers for a wrapper minted to this browser
   * escrow device. Reads directly from Firestore `users/{uid}/cloud_vault_key_wrappers`
   * which rules permit for authenticated owner, avoiding exportUserData high-risk gating.
   */
  const fetchWrappedKey = useCallback(async (escrowDeviceId: string): Promise<string | null> => {
    const user = auth().currentUser;
    if (!user) return null;
    try {
      const q = query(
        collection(db(), "users", user.uid, "cloud_vault_key_wrappers"),
        where("targetDeviceId", "==", escrowDeviceId),
      );
      const snap = await getDocs(q);
      for (const docSnap of snap.docs) {
        const data = docSnap.data();
        if (data.status === "active" && typeof data.wrappedVaultKey === "string") {
          return data.wrappedVaultKey;
        }
      }
      return null;
    } catch {
      return null;
    }
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
