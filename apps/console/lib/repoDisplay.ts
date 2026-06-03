/**
 * Pensieve connected-repo display name, sealed end-to-end.
 *
 * A `knowledge_repos/{id}` row stores only an opaque server-keyed `repoMatchToken`
 * (used by the GitHub push webhook to route an inbound event) plus a vault-sealed
 * `sealedRepoFullName` envelope. The cleartext repo name is NEVER stored: the
 * server observes it transiently only when the webhook arrives, and the console
 * supplies its own sealed copy at connect time for its own later display.
 *
 * The console holds the vault key in-session (escrow → vaultKeySession), so the
 * repo name is sealed before it is sent and decrypted client-side for the UI —
 * the server row is never the display source. This reuses the same
 * AES-256-GCM CloudVaultSealedText envelope (`escrow.ts`) every BurnBar platform
 * speaks, so the sealed name round-trips byte-identically across web / Swift /
 * Kotlin.
 */
import { importVaultKey, openText, sealText, type CloudVaultSealedText } from "./escrow";
import { getConsoleVaultCryptoKey, getConsoleVaultKeyBytes } from "./vaultKeySession";

/** Thrown when the console vault key is not loaded in-session. */
export class RepoDisplayError extends Error {
  constructor(
    readonly code: "vault_key_missing" | "decrypt_failed",
    message: string,
  ) {
    super(message);
    this.name = "RepoDisplayError";
  }
}

/** Resolve the in-session vault `CryptoKey`, importing from raw bytes if needed. */
async function vaultKey(): Promise<CryptoKey> {
  const existing = getConsoleVaultCryptoKey();
  if (existing) return existing;
  const raw = getConsoleVaultKeyBytes();
  if (!raw) {
    throw new RepoDisplayError(
      "vault_key_missing",
      "Unlock this device's vault key to read or seal repository names.",
    );
  }
  return importVaultKey(raw);
}

/**
 * Seal a repo full name (e.g. `owner/private-repo`) into the wire envelope the
 * `connectKnowledgeRepo` callable stores as `sealedRepoFullName`. Call this
 * before invoking the callable; never send the cleartext name for storage.
 */
export async function sealRepoFullName(repoFullName: string): Promise<CloudVaultSealedText> {
  return sealText(repoFullName, await vaultKey());
}

/**
 * Decrypt a `sealedRepoFullName` envelope for display. Returns null when the row
 * has no sealed name (legacy/in-flight rows written before this migration), so
 * callers can fall back to a neutral placeholder rather than the server row.
 */
export async function openRepoFullName(
  sealedRepoFullName: CloudVaultSealedText | null | undefined,
): Promise<string | null> {
  if (!sealedRepoFullName) return null;
  try {
    return await openText(sealedRepoFullName, await vaultKey());
  } catch (error) {
    if (error instanceof RepoDisplayError) throw error;
    throw new RepoDisplayError("decrypt_failed", "Failed to decrypt the sealed repository name.");
  }
}
