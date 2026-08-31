"use client";

import { useState } from "react";
import {
  Clock,
  MessageSquare,
  Code2,
  FileText,
  BookOpen,
  Copy,
  Check,
  Tag,
} from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";

interface FeedMemoryItem {
  id: string;
  kind: "chat_memory" | "code" | "notes" | "repo_docs";
  sourceName: string;
  timeAgo: string;
  summary: string;
  tags: string[];
  confidence: number;
}

const SAMPLE_FEED_ITEMS: FeedMemoryItem[] = [
  {
    id: "feed-1",
    kind: "chat_memory",
    sourceName: "Hermes CLI Session #1042",
    timeAgo: "12m ago",
    summary: "Recorded preference: User prefers fewer, fatter PRs (one cohesive theme) over fragmented slice PRs.",
    tags: ["workflow", "github", "prs"],
    confidence: 0.99,
  },
  {
    id: "feed-2",
    kind: "code",
    sourceName: "OpenBurnBarCore / SharedModels",
    timeAgo: "45m ago",
    summary: "Indexed struct EscrowDeviceSafetyCode: formats P-256 public key data into 8 human-comparable hex groups.",
    tags: ["escrow", "crypto", "safety_code"],
    confidence: 0.97,
  },
  {
    id: "feed-3",
    kind: "notes",
    sourceName: "Architecture Decisions / ADR-009",
    timeAgo: "2h ago",
    summary: "Control plane trust root: approveEscrowDeviceTrust enforces out-of-band fingerprint binding.",
    tags: ["adr", "security", "trust_root"],
    confidence: 0.98,
  },
  {
    id: "feed-4",
    kind: "chat_memory",
    sourceName: "Claude Code / OpenBurnBarDaemon",
    timeAgo: "4h ago",
    summary: "Extracted fact: Daemon connects over local socket at /tmp/openburnbar-daemon.sock for non-extractable keychain ops.",
    tags: ["daemon", "socket", "keychain"],
    confidence: 0.95,
  },
  {
    id: "feed-5",
    kind: "repo_docs",
    sourceName: "BurnBar / AGENTS.md",
    timeAgo: "6h ago",
    summary: "The completion bar: 'Do the whole thing. Do it right. Do it with tests. Do it with documentation.'",
    tags: ["agents", "principles", "standards"],
    confidence: 1.0,
  },
];

export function PensieveMemoryFeed() {
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const handleCopy = (id: string, text: string) => {
    navigator.clipboard.writeText(text);
    setCopiedId(id);
    setTimeout(() => setCopiedId(null), 2000);
  };

  const getKindBadge = (kind: FeedMemoryItem["kind"]) => {
    switch (kind) {
      case "chat_memory":
        return (
          <span className="flex items-center gap-1 text-tier-end-to-end font-medium">
            <MessageSquare className="size-3.5" /> Chat Memory
          </span>
        );
      case "code":
        return (
          <span className="flex items-center gap-1 text-brass-core font-medium">
            <Code2 className="size-3.5" /> Code Fact
          </span>
        );
      case "notes":
        return (
          <span className="flex items-center gap-1 text-amber-400 font-medium">
            <FileText className="size-3.5" /> Note
          </span>
        );
      case "repo_docs":
        return (
          <span className="flex items-center gap-1 text-sky-400 font-medium">
            <BookOpen className="size-3.5" /> Repo Doc
          </span>
        );
    }
  };

  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between">
          <div>
            <CardTitle className="text-base font-medium flex items-center gap-2">
              <Clock className="size-4 text-tier-end-to-end" />
              Live Memory Stream
            </CardTitle>
            <CardDescription>
              Chronological timeline of private memories captured from your AI sessions, repositories, and notes.
            </CardDescription>
          </div>
          <span className="rounded-full bg-tier-end-to-end/10 px-2.5 py-1 text-xs font-medium text-tier-end-to-end flex items-center gap-1.5">
            <span className="size-1.5 rounded-full bg-tier-end-to-end animate-pulse" />
            Live Sync Active
          </span>
        </div>
      </CardHeader>
      <CardContent>
        <div className="relative pl-6 before:absolute before:left-2 before:top-2 before:bottom-2 before:w-0.5 before:bg-glass-line space-y-token-4">
          {SAMPLE_FEED_ITEMS.map((item) => (
            <div key={item.id} className="relative group">
              {/* Timeline marker */}
              <div className="absolute -left-[27px] top-1.5 size-3 rounded-full border-2 border-tier-end-to-end bg-panel-subtle" />

              <div className="rounded-lg border border-glass-line bg-panel-subtle/80 p-token-3 transition-colors hover:border-tier-end-to-end/50 hover:bg-mercury-wash/30">
                <div className="flex items-center justify-between gap-token-2 text-xs">
                  <div className="flex items-center gap-2">
                    {getKindBadge(item.kind)}
                    <span className="text-content-dim">•</span>
                    <span className="text-content-dim font-mono">{item.sourceName}</span>
                  </div>
                  <div className="flex items-center gap-2">
                    <span className="text-content-dim font-mono">{item.timeAgo}</span>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-6 w-6 p-0 text-content-dim hover:text-content-bright"
                      onClick={() => handleCopy(item.id, item.summary)}
                    >
                      {copiedId === item.id ? (
                        <Check className="size-3 text-tier-end-to-end" />
                      ) : (
                        <Copy className="size-3" />
                      )}
                    </Button>
                  </div>
                </div>

                <p className="mt-2 text-sm text-content-bright">{item.summary}</p>

                <div className="mt-2 flex items-center gap-2">
                  <div className="flex flex-wrap gap-1">
                    {item.tags.map((tag) => (
                      <span
                        key={tag}
                        className="inline-flex items-center gap-0.5 rounded bg-mercury-wash px-1.5 py-0.5 text-[10px] font-mono text-content-dim"
                      >
                        <Tag className="size-2.5" />
                        {tag}
                      </span>
                    ))}
                  </div>
                  <span className="ml-auto text-[10px] font-mono text-content-dim">
                    {(item.confidence * 100).toFixed(0)}% confidence
                  </span>
                </div>
              </div>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}
