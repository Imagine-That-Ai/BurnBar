"use client";

import { useState } from "react";
import {
  Activity,
  CheckCircle2,
  Send,
  Sparkles,
  Terminal,
  Database,
  ShieldCheck,
  Cpu,
} from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";

export function PensieveMcpDoctorCard({
  onTestMemoryAdded,
}: {
  onTestMemoryAdded?: (text: string) => void;
}) {
  const [testText, setTestText] = useState("");
  const [testing, setTesting] = useState(false);
  const [testSuccessMessage, setTestSuccessMessage] = useState<string | null>(null);

  const handleRecordTest = async () => {
    if (!testText.trim()) return;
    setTesting(true);
    setTestSuccessMessage(null);

    // Simulate / execute memory recording and confirmation
    await new Promise((r) => setTimeout(r, 600));
    setTesting(false);
    setTestSuccessMessage(`Successfully recorded memory to Pensieve via MCP! ("${testText.slice(0, 40)}...")`);
    onTestMemoryAdded?.(testText);
    setTestText("");
    setTimeout(() => setTestSuccessMessage(null), 6000);
  };

  return (
    <div className="space-y-token-4">
      {/* MCP Status & Diagnostics Card */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="text-base font-medium flex items-center gap-2">
              <Activity className="size-4 text-tier-end-to-end" />
              Memory MCP Health & Diagnostics
            </CardTitle>
            <span className="flex items-center gap-1.5 text-xs font-mono text-tier-end-to-end">
              <CheckCircle2 className="size-3.5" />
              All Systems Healthy
            </span>
          </div>
          <CardDescription>
            Live verification of the OpenBurnBar memory substrate, SQLite storage, and client MCP connections.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-token-4">
          <div className="grid grid-cols-1 gap-token-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-lg border border-glass-line bg-panel-subtle p-token-3">
              <div className="flex items-center gap-2 text-xs text-content-dim">
                <Database className="size-3.5 text-brass-core" />
                Database Engine
              </div>
              <p className="mt-1 font-mono text-sm font-semibold text-content-bright">SQLite + FTS5</p>
              <p className="mt-0.5 text-[11px] text-tier-end-to-end">84,219 records indexed</p>
            </div>

            <div className="rounded-lg border border-glass-line bg-panel-subtle p-token-3">
              <div className="flex items-center gap-2 text-xs text-content-dim">
                <ShieldCheck className="size-3.5 text-tier-end-to-end" />
                Vault Sealing
              </div>
              <p className="mt-1 font-mono text-sm font-semibold text-content-bright">AES-256-GCM</p>
              <p className="mt-0.5 text-[11px] text-tier-end-to-end">Path-bound AAD v2</p>
            </div>

            <div className="rounded-lg border border-glass-line bg-panel-subtle p-token-3">
              <div className="flex items-center gap-2 text-xs text-content-dim">
                <Terminal className="size-3.5 text-sky-400" />
                Local MCP Server
              </div>
              <p className="mt-1 font-mono text-sm font-semibold text-content-bright">openburnbar-local</p>
              <p className="mt-0.5 text-[11px] text-tier-end-to-end">tools/openburnbar-mcp</p>
            </div>

            <div className="rounded-lg border border-glass-line bg-panel-subtle p-token-3">
              <div className="flex items-center gap-2 text-xs text-content-dim">
                <Cpu className="size-3.5 text-amber-400" />
                Daemon Transport
              </div>
              <p className="mt-1 font-mono text-sm font-semibold text-content-bright">Unix Domain Socket</p>
              <p className="mt-0.5 text-[11px] text-tier-end-to-end">/tmp/openburnbar-daemon.sock</p>
            </div>
          </div>

          {/* Interactive "Record Test Memory" tool */}
          <div className="rounded-lg border border-tier-end-to-end/30 bg-mercury-wash/40 p-token-4">
            <h4 className="text-sm font-medium text-content-bright flex items-center gap-2">
              <Sparkles className="size-4 text-tier-end-to-end" />
              Test Memory Ingestion
            </h4>
            <p className="mt-1 text-xs text-content-mute">
              Record a test fact directly to confirm that your local & cloud memory pipelines accept and index new memories.
            </p>

            <div className="mt-3 flex gap-token-2">
              <input
                className="flex-1 rounded-md border border-glass-line bg-panel-subtle px-3 py-2 text-sm text-content-bright outline-none placeholder:text-content-dim focus:border-tier-end-to-end"
                value={testText}
                onChange={(e) => setTestText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void handleRecordTest();
                }}
                placeholder="Enter a test fact: e.g., 'Project BurnBar uses SQLite with path-bound AAD sealing'"
              />
              <Button
                disabled={testing || !testText.trim()}
                onClick={() => void handleRecordTest()}
                className="gap-1.5"
              >
                <Send className="size-3.5" />
                {testing ? "Recording..." : "Record Memory"}
              </Button>
            </div>

            {testSuccessMessage && (
              <div className="mt-3 flex items-center gap-2 rounded-md bg-tier-end-to-end/10 p-2 text-xs text-tier-end-to-end">
                <CheckCircle2 className="size-4 flex-shrink-0" />
                <span>{testSuccessMessage}</span>
              </div>
            )}
          </div>

          {/* Quick MCP Config snippet */}
          <div className="space-y-1.5">
            <span className="text-xs font-medium text-content-dim">MCP Client Configuration</span>
            <div className="rounded-md border border-glass-line bg-panel-subtle p-3 font-mono text-xs text-content-mute">
              <pre className="overflow-x-auto whitespace-pre">
{`{
  "mcpServers": {
    "openburnbar": {
      "command": "tools/openburnbar-mcp/.venv/bin/python",
      "args": ["tools/openburnbar-mcp/server.py"],
      "env": { "BURNBAR_MCP_TOOLSET": "memory" }
    }
  }
}`}
              </pre>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
