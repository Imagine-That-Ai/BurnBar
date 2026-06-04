"use client";

import { useCallback, useEffect, useState } from "react";
import { listKnowledgeRepos, type KnowledgeRepoSummary } from "./api";
import { openRepoFullName, RepoDisplayError } from "./repoDisplay";

export interface PensieveRepo extends KnowledgeRepoSummary {
  /** Repo name decrypted locally from `sealedRepoFullName`, or null if unavailable. */
  displayName: string | null;
  /** A sealed name exists but the vault key isn't loaded in this browser yet. */
  nameLocked: boolean;
}

/**
 * Load the member's connected repos and decrypt each `sealedRepoFullName` in the
 * browser for display. The server never holds the cleartext name, so the name
 * resolves only when this device's vault key is unlocked (escrow → vaultKeySession).
 */
export function usePensieveRepos() {
  const [repos, setRepos] = useState<PensieveRepo[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await listKnowledgeRepos();
      const enriched = await Promise.all(
        result.repos.map(async (repo) => {
          let displayName: string | null = null;
          let nameLocked = false;
          if (repo.sealedRepoFullName) {
            try {
              displayName = await openRepoFullName(repo.sealedRepoFullName);
            } catch (err) {
              nameLocked = err instanceof RepoDisplayError && err.code === "vault_key_missing";
            }
          }
          return { ...repo, displayName, nameLocked };
        }),
      );
      setRepos(enriched);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not load connected repos.");
      setRepos([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void reload();
  }, [reload]);

  return { repos, loading, error, reload };
}
