"use client";

import { useState } from "react";
import { Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { openText, type CloudVaultSealedText } from "@/lib/escrow";
import { searchKnowledge, type SearchKnowledgeHit } from "@/lib/api";
import { embedAndCloakQuery } from "@/lib/recall";
import { getConsoleVaultCryptoKey, getConsoleVaultKeyBytes } from "@/lib/vaultKeySession";

interface RecallHit {
  hit: SearchKnowledgeHit;
  plaintext: string;
}

export function PensieveRecallCard() {
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hits, setHits] = useState<RecallHit[]>([]);

  async function runRecall() {
    const rawVaultKey = getConsoleVaultKeyBytes();
    const vaultKey = getConsoleVaultCryptoKey();
    if (!rawVaultKey || !vaultKey) {
      setError("Trust this browser first so the vault key is available in memory.");
      return;
    }
    if (!query.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const request = await embedAndCloakQuery(query, rawVaultKey);
      const result = await searchKnowledge({ ...request, limit: 8 });
      const opened = await Promise.all(
        result.hits.map(async (hit) => ({
          hit,
          plaintext: await openText(hit.ciphertext as CloudVaultSealedText, vaultKey),
        })),
      );
      setHits(opened);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Recall failed.");
      setHits([]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Recall</CardTitle>
        <CardDescription>
          Embed and cloak the query locally, then decrypt matching sealed chunks in this browser.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-token-4">
        <div className="flex gap-token-2">
          <input
            className="min-w-0 flex-1 rounded-md border border-glass-line bg-panel-subtle px-token-3 py-2 text-sm text-content-bright outline-none placeholder:text-content-dim"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") void runRecall();
            }}
            placeholder="Ask Pensieve what it remembers..."
          />
          <Button disabled={busy || !query.trim()} onClick={() => void runRecall()}>
            <Search className="size-4" />
            {busy ? "Searching..." : "Search"}
          </Button>
        </div>
        {error && <p className="text-sm text-[color:var(--color-seal-crimson)]">{error}</p>}
        {hits.length > 0 && (
          <div className="space-y-token-3">
            {hits.map(({ hit, plaintext }) => (
              <article key={hit.vectorId} className="rounded-md border border-glass-line bg-mercury-wash p-token-3">
                <div className="mb-1 flex items-center justify-between gap-token-2 text-xs text-content-dim">
                  <span>{hit.sourceKind} / {hit.sourceSlug}</span>
                  <span className="font-mono">{hit.score.toFixed(3)}</span>
                </div>
                <p className="whitespace-pre-wrap text-sm text-content-bright">{plaintext}</p>
              </article>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
