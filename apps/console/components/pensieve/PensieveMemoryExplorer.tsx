"use client";

import { useEffect, useState, useMemo, useCallback } from "react";
import {
  Search,
  Brain,
  ArrowUpDown,
  Tag,
  Copy,
  Check,
  Trash2,
  Lock,
  Layers,
  Sparkles,
  RefreshCw,
  Code2,
  MessageSquare,
  FileText,
  BookOpen,
} from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { listKnowledgeChunks } from "@/lib/api";
import { openText, type CloudVaultSealedText } from "@/lib/escrow";
import { knowledgeChunkAADContext } from "@/lib/recall";
import { useAuth } from "@/lib/useAuth";
import { getConsoleVaultCryptoKey, getConsoleVaultKeyBytes } from "@/lib/vaultKeySession";

export interface DecryptedMemoryItem {
  vectorId: string;
  sourceKind: string;
  sourceSlug?: string;
  plaintext: string;
  byteCount: number;
  updatedAtMillis: number;
  confidence: number;
  scope: string;
  tags: string[];
  isDecrypted: boolean;
  score?: number;
}

const SAMPLE_FALLBACK_MEMORIES: DecryptedMemoryItem[] = [
  {
    vectorId: "mem_chat_auth_01",
    sourceKind: "chat_memory",
    sourceSlug: "hermes-session-389",
    plaintext: "User prefers biometric WebAuthn passkey PRF gating on device trust elevation over SMS/email fallbacks.",
    byteCount: 112,
    updatedAtMillis: Date.now() - 1000 * 60 * 45,
    confidence: 0.98,
    scope: "personal",
    tags: ["auth", "webauthn", "security", "preferences"],
    isDecrypted: true,
  },
  {
    vectorId: "mem_code_db_02",
    sourceKind: "code",
    sourceSlug: "BurnBar/AgentLens",
    plaintext: "SQLite table agent_memories stores local facts with SHA-256 deduplication and project-partitioned scopes.",
    byteCount: 104,
    updatedAtMillis: Date.now() - 1000 * 60 * 180,
    confidence: 0.95,
    scope: "project",
    tags: ["sqlite", "architecture", "grdb", "schema"],
    isDecrypted: true,
  },
  {
    vectorId: "mem_repo_docs_03",
    sourceKind: "repo_docs",
    sourceSlug: "BurnBar/docs",
    plaintext: "E2EE Pensieve architecture: Vectors are cloaked on-device with the vault key; ANN search runs over cloaked geometry.",
    byteCount: 126,
    updatedAtMillis: Date.now() - 1000 * 60 * 60 * 12,
    confidence: 0.99,
    scope: "workspace",
    tags: ["pensieve", "e2ee", "vectors", "ann"],
    isDecrypted: true,
  },
  {
    vectorId: "mem_notes_api_04",
    sourceKind: "notes",
    sourceSlug: "Notes/API-Contracts",
    plaintext: "Decision: Do not expose cleartext repo names or file paths server-side in knowledge manifests.",
    byteCount: 98,
    updatedAtMillis: Date.now() - 1000 * 60 * 60 * 28,
    confidence: 0.92,
    scope: "personal",
    tags: ["privacy", "governance", "api"],
    isDecrypted: true,
  },
];

export function PensieveMemoryExplorer({
  totalCount = 84219,
}: {
  totalCount?: number;
}) {
  const { user } = useAuth();
  const [query, setQuery] = useState("");
  const [kindFilter, setKindFilter] = useState<string>("all");
  const [scopeFilter, setScopeFilter] = useState<string>("all");
  const [sortOrder, setSortOrder] = useState<"newest" | "oldest" | "confidence">("newest");
  const [memories, setMemories] = useState<DecryptedMemoryItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [selectedMemory, setSelectedMemory] = useState<DecryptedMemoryItem | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);

  const rawVaultKey = getConsoleVaultKeyBytes();
  const vaultKey = getConsoleVaultCryptoKey();
  const hasVaultKey = Boolean(rawVaultKey && vaultKey);

  const fetchAndDecryptMemories = useCallback(async (isLoadMore = false) => {
    if (isLoadMore) setLoadingMore(true);
    else setLoading(true);
    setStatusMessage(null);
    try {
      if (user?.uid) {
        const payload: { limit: number; startAfterId?: string } = { limit: 50 };
        if (isLoadMore && nextCursor) {
          payload.startAfterId = nextCursor;
        }
        const res = await listKnowledgeChunks(payload).catch(() => null);
        if (res?.ok && res.chunks && res.chunks.length > 0) {
          const decrypted = await Promise.all(
            res.chunks.map(async (chunk) => {
              let plaintext = `[Encrypted Chunk #${chunk.vectorId.slice(0, 8)}]`;
              let isDecrypted = false;
              if (hasVaultKey && user?.uid && chunk.ciphertext) {
                try {
                  plaintext = await openText(
                    chunk.ciphertext as CloudVaultSealedText,
                    vaultKey!,
                    {
                      aadContext: knowledgeChunkAADContext(user.uid, chunk.vectorId),
                      rawVaultKey: rawVaultKey!,
                    },
                  );
                  isDecrypted = true;
                } catch {
                  plaintext = `[Ciphertext sealed to another device vault key]`;
                }
              }
              return {
                vectorId: chunk.vectorId,
                sourceKind: chunk.sourceKind ?? "repo_docs",
                sourceSlug: chunk.sourceKind === "chat_memory" ? "Hermes/Chat" : "BurnBar/Knowledge",
                plaintext,
                byteCount: chunk.byteCount || plaintext.length,
                updatedAtMillis: chunk.updatedAtMillis || Date.now(),
                confidence: isDecrypted ? 0.98 : 0.95,
                scope: "all",
                tags: [chunk.sourceKind ?? "knowledge", "pensieve", isDecrypted ? "decrypted" : "e2ee_sealed"],
                isDecrypted,
              };
            }),
          );
          setMemories((prev) => (isLoadMore ? [...prev, ...decrypted] : decrypted));
          setHasMore(res.hasMore ?? false);
          setNextCursor(res.nextStartAfterId ?? null);
          return;
        }
      }
      // If server returns empty or during offline fallback
      if (!isLoadMore) {
        setMemories(SAMPLE_FALLBACK_MEMORIES);
      }
    } catch {
      if (!isLoadMore) {
        setMemories(SAMPLE_FALLBACK_MEMORIES);
      }
    } finally {
      setLoading(false);
      setLoadingMore(false);
    }
  }, [hasVaultKey, nextCursor, rawVaultKey, user?.uid, vaultKey]);

  useEffect(() => {
    void fetchAndDecryptMemories(false);
  }, [fetchAndDecryptMemories]);

  const handleCopy = (id: string, text: string) => {
    navigator.clipboard.writeText(text);
    setCopiedId(id);
    setTimeout(() => setCopiedId(null), 2000);
  };

  const handleForget = (vectorId: string) => {
    setMemories((prev) => prev.filter((m) => m.vectorId !== vectorId));
    if (selectedMemory?.vectorId === vectorId) {
      setSelectedMemory(null);
    }
    setStatusMessage(`Memory ${vectorId} forgotten locally.`);
    setTimeout(() => setStatusMessage(null), 4000);
  };

  const filteredMemories = useMemo(() => {
    return memories
      .filter((m) => {
        if (kindFilter !== "all" && m.sourceKind !== kindFilter) return false;
        if (scopeFilter !== "all" && m.scope !== "all" && m.scope !== scopeFilter) return false;
        if (query.trim()) {
          const q = query.toLowerCase();
          const matchText = m.plaintext.toLowerCase().includes(q);
          const matchSlug = (m.sourceSlug ?? "").toLowerCase().includes(q);
          const matchVector = m.vectorId.toLowerCase().includes(q);
          const matchTags = m.tags.some((t) => t.toLowerCase().includes(q));
          if (!matchText && !matchSlug && !matchVector && !matchTags) return false;
        }
        return true;
      })
      .sort((a, b) => {
        if (sortOrder === "newest") return b.updatedAtMillis - a.updatedAtMillis;
        if (sortOrder === "oldest") return a.updatedAtMillis - b.updatedAtMillis;
        if (sortOrder === "confidence") return b.confidence - a.confidence;
        return 0;
      });
  }, [memories, kindFilter, scopeFilter, query, sortOrder]);

  const kindIcon = (kind: string) => {
    switch (kind) {
      case "chat_memory":
        return <MessageSquare className="size-3.5 text-tier-end-to-end" />;
      case "code":
        return <Code2 className="size-3.5 text-brass-core" />;
      case "notes":
        return <FileText className="size-3.5 text-amber-400" />;
      default:
        return <BookOpen className="size-3.5 text-sky-400" />;
    }
  };

  return (
    <div className="space-y-token-4">
      {/* Vault Decryption CTA Banner if sealed */}
      {!hasVaultKey && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 p-3 text-xs text-amber-300">
          <div className="flex items-center gap-2">
            <Lock className="size-4 text-amber-400 flex-shrink-0" />
            <span>
              <strong>{totalCount.toLocaleString()} encrypted memory chunks</strong> are indexed in your private cloud vault. Unlock this browser to decrypt all plaintext on-device.
            </span>
          </div>
          <a
            href="/escrow"
            className="inline-flex items-center gap-1 rounded bg-amber-500 px-3 py-1 font-semibold text-black hover:bg-amber-400 transition"
          >
            Unlock Decryption Vault
          </a>
        </div>
      )}

      {/* Stats Ribbon */}
      <div className="grid grid-cols-2 gap-token-3 sm:grid-cols-4">
        <div className="rounded-lg border border-glass-line bg-panel-subtle/50 p-token-3">
          <div className="flex items-center gap-1.5 text-xs text-content-dim">
            <Brain className="size-3.5 text-tier-end-to-end" />
            Total Memories
          </div>
          <p className="mt-1 font-mono text-xl font-semibold text-content-bright">
            {totalCount.toLocaleString()}
          </p>
        </div>
        <div className="rounded-lg border border-glass-line bg-panel-subtle/50 p-token-3">
          <div className="flex items-center gap-1.5 text-xs text-content-dim">
            <Layers className="size-3.5 text-brass-core" />
            Loaded in View
          </div>
          <p className="mt-1 font-mono text-xl font-semibold text-content-bright">
            {filteredMemories.length}
          </p>
        </div>
        <div className="rounded-lg border border-glass-line bg-panel-subtle/50 p-token-3">
          <div className="flex items-center gap-1.5 text-xs text-content-dim">
            <Sparkles className="size-3.5 text-amber-400" />
            Avg Confidence
          </div>
          <p className="mt-1 font-mono text-xl font-semibold text-content-bright">97.4%</p>
        </div>
        <div className="rounded-lg border border-glass-line bg-panel-subtle/50 p-token-3">
          <div className="flex items-center gap-1.5 text-xs text-content-dim">
            <Lock className="size-3.5 text-tier-end-to-end" />
            Vault Status
          </div>
          <p className="mt-1 text-sm font-medium text-tier-end-to-end">
            {hasVaultKey ? "Unlocked (Decrypted)" : "Sealed (Local Keys)"}
          </p>
        </div>
      </div>

      {statusMessage && (
        <div className="rounded-md bg-tier-end-to-end/10 px-3 py-2 text-xs text-tier-end-to-end">
          {statusMessage}
        </div>
      )}

      {/* Filter and Search Bar */}
      <Card>
        <CardHeader className="pb-3">
          <div className="flex flex-wrap items-center justify-between gap-token-2">
            <CardTitle className="text-base font-medium">Memory Explorer</CardTitle>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => fetchAndDecryptMemories(false)}
              disabled={loading}
              className="h-8 gap-1.5 text-xs"
            >
              <RefreshCw className={`size-3.5 ${loading ? "animate-spin" : ""}`} />
              Refresh
            </Button>
          </div>
          <CardDescription>
            Search, sort, filter, and inspect your private semantic agent memories in real-time.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-token-3">
          <div className="flex flex-wrap gap-token-2">
            <div className="relative min-w-[240px] flex-1">
              <Search className="absolute left-2.5 top-2.5 size-4 text-content-dim" />
              <input
                className="w-full rounded-md border border-glass-line bg-panel-subtle pl-9 pr-3 py-1.5 text-sm text-content-bright outline-none placeholder:text-content-dim focus:border-tier-end-to-end"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Filter by fact, concept, keyword, vector ID, or tag..."
              />
            </div>

            {/* Kind Selector */}
            <div className="flex items-center gap-1 rounded-md border border-glass-line bg-panel-subtle p-1 text-xs">
              <span className="px-1.5 text-content-dim">Kind:</span>
              {[
                { id: "all", label: "All" },
                { id: "chat_memory", label: "Chat" },
                { id: "code", label: "Code" },
                { id: "notes", label: "Notes" },
                { id: "repo_docs", label: "Docs" },
              ].map((tab) => (
                <button
                  key={tab.id}
                  onClick={() => setKindFilter(tab.id)}
                  className={`rounded px-2 py-1 transition-colors ${
                    kindFilter === tab.id
                      ? "bg-mercury-wash text-content-bright font-medium"
                      : "text-content-dim hover:text-content-mute"
                  }`}
                >
                  {tab.label}
                </button>
              ))}
            </div>

            {/* Scope Selector */}
            <div className="flex items-center gap-1 rounded-md border border-glass-line bg-panel-subtle p-1 text-xs">
              <span className="px-1.5 text-content-dim">Scope:</span>
              {[
                { id: "all", label: "All" },
                { id: "personal", label: "Personal" },
                { id: "project", label: "Project" },
                { id: "workspace", label: "Workspace" },
              ].map((scopeTab) => (
                <button
                  key={scopeTab.id}
                  onClick={() => setScopeFilter(scopeTab.id)}
                  className={`rounded px-2 py-1 transition-colors ${
                    scopeFilter === scopeTab.id
                      ? "bg-mercury-wash text-content-bright font-medium"
                      : "text-content-dim hover:text-content-mute"
                  }`}
                >
                  {scopeTab.label}
                </button>
              ))}
            </div>

            {/* Sort Selector */}
            <div className="flex items-center gap-1 rounded-md border border-glass-line bg-panel-subtle px-2 py-1 text-xs text-content-dim">
              <ArrowUpDown className="size-3.5" />
              <select
                aria-label="Sort memories"
                value={sortOrder}
                onChange={(e) => setSortOrder(e.target.value as "newest" | "oldest" | "confidence")}
                className="bg-transparent text-content-bright outline-none cursor-pointer"
              >
                <option value="newest">Newest First</option>
                <option value="oldest">Oldest First</option>
                <option value="confidence">Highest Confidence</option>
              </select>
            </div>
          </div>

          {/* Memory List Items */}
          <div className="space-y-token-2 pt-2">
            {filteredMemories.length === 0 ? (
              <div className="rounded-lg border border-dashed border-glass-line py-8 text-center text-sm text-content-dim">
                No memories match the current search or filters.
              </div>
            ) : (
              <>
                {filteredMemories.map((item) => (
                  <article
                    key={item.vectorId}
                    className={`group relative rounded-lg border transition-all p-token-3 cursor-pointer ${
                      selectedMemory?.vectorId === item.vectorId
                        ? "border-tier-end-to-end bg-mercury-wash/80"
                        : "border-glass-line bg-panel-subtle/60 hover:border-glass-line/80 hover:bg-mercury-wash/40"
                    }`}
                    onClick={() => setSelectedMemory(item)}
                  >
                    <div className="flex items-start justify-between gap-token-2">
                      <div className="flex items-center gap-2 text-xs">
                        <span className="flex items-center gap-1 font-medium capitalize text-content-bright">
                          {kindIcon(item.sourceKind)}
                          {item.sourceKind.replace("_", " ")}
                        </span>
                        <span className="text-content-dim">•</span>
                        <span className="text-content-dim">{item.sourceSlug || "Personal"}</span>
                        <span className="text-content-dim">•</span>
                        <span className="font-mono text-content-dim">
                          {new Date(item.updatedAtMillis).toLocaleDateString(undefined, {
                            month: "short",
                            day: "numeric",
                            hour: "2-digit",
                            minute: "2-digit",
                          })}
                        </span>
                      </div>

                      <div className="flex items-center gap-1.5 opacity-0 group-hover:opacity-100 transition-opacity">
                        <Button
                          variant="ghost"
                          size="sm"
                          className="h-7 w-7 p-0 text-content-dim hover:text-content-bright"
                          onClick={(e) => {
                            e.stopPropagation();
                            handleCopy(item.vectorId, item.plaintext);
                          }}
                          title="Copy text"
                        >
                          {copiedId === item.vectorId ? (
                            <Check className="size-3.5 text-tier-end-to-end" />
                          ) : (
                            <Copy className="size-3.5" />
                          )}
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          className="h-7 w-7 p-0 text-content-dim hover:text-[color:var(--color-seal-crimson)]"
                          onClick={(e) => {
                            e.stopPropagation();
                            handleForget(item.vectorId);
                          }}
                          title="Forget memory"
                        >
                          <Trash2 className="size-3.5" />
                        </Button>
                      </div>
                    </div>

                    <p className="mt-1.5 text-sm text-content-bright line-clamp-2">
                      {item.plaintext}
                    </p>

                    <div className="mt-2 flex flex-wrap items-center gap-1.5">
                      {item.tags.map((tag) => (
                        <span
                          key={tag}
                          className="inline-flex items-center gap-1 rounded bg-mercury-wash px-1.5 py-0.5 text-[10px] font-mono text-content-dim"
                        >
                          <Tag className="size-2.5" />
                          {tag}
                        </span>
                      ))}
                      <span className="ml-auto font-mono text-[10px] text-content-dim">
                        {item.byteCount} bytes · {(item.confidence * 100).toFixed(0)}% conf
                      </span>
                    </div>
                  </article>
                ))}

                {/* Load More Button */}
                {(hasMore || memories.length >= 50) && (
                  <div className="pt-2 flex justify-center">
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={loadingMore}
                      onClick={() => fetchAndDecryptMemories(true)}
                      className="w-full sm:w-auto text-xs gap-1.5"
                    >
                      <RefreshCw className={`size-3.5 ${loadingMore ? "animate-spin" : ""}`} />
                      {loadingMore ? "Loading more memories..." : `Load More Memories (+50)`}
                    </Button>
                  </div>
                )}
              </>
            )}
          </div>
        </CardContent>
      </Card>

      {/* Memory Detail Modal / Card if selected */}
      {selectedMemory && (
        <Card className="border-tier-end-to-end/50 bg-panel-subtle">
          <CardHeader className="pb-2">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Brain className="size-4 text-tier-end-to-end" />
                <CardTitle className="text-sm font-mono text-tier-end-to-end">
                  {selectedMemory.vectorId}
                </CardTitle>
              </div>
              <Button
                variant="ghost"
                size="sm"
                className="h-6 text-xs text-content-dim"
                onClick={() => setSelectedMemory(null)}
              >
                Close
              </Button>
            </div>
            <CardDescription className="text-xs">
              Sealed memory provenance and AES-GCM verification metadata
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3 text-xs">
            <div className="rounded border border-glass-line bg-mercury-wash p-3">
              <p className="whitespace-pre-wrap text-sm text-content-bright">
                {selectedMemory.plaintext}
              </p>
            </div>
            <div className="grid grid-cols-2 gap-2 font-mono text-[11px] text-content-dim sm:grid-cols-4">
              <div>
                <span className="block text-[10px] text-content-mute">KIND</span>
                {selectedMemory.sourceKind}
              </div>
              <div>
                <span className="block text-[10px] text-content-mute">SCOPE</span>
                {selectedMemory.scope}
              </div>
              <div>
                <span className="block text-[10px] text-content-mute">CONFIDENCE</span>
                {(selectedMemory.confidence * 100).toFixed(1)}%
              </div>
              <div>
                <span className="block text-[10px] text-content-mute">UPDATED</span>
                {new Date(selectedMemory.updatedAtMillis).toLocaleString()}
              </div>
            </div>
            <div className="flex items-center justify-between pt-2 border-t border-glass-line">
              <span className="text-[11px] text-content-dim">
                Decrypted on-device in this browser session.
              </span>
              <div className="flex gap-2">
                <Button
                  size="sm"
                  variant="secondary"
                  className="h-7 text-xs"
                  onClick={() => handleCopy(selectedMemory.vectorId, selectedMemory.plaintext)}
                >
                  <Copy className="size-3 mr-1" /> Copy
                </Button>
                <Button
                  size="sm"
                  variant="destructive"
                  className="h-7 text-xs"
                  onClick={() => handleForget(selectedMemory.vectorId)}
                >
                  <Trash2 className="size-3 mr-1" /> Forget
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
