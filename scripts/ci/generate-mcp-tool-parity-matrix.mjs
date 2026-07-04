#!/usr/bin/env node
/**
 * D8 — regenerate docs/reviews/MCP_TOOL_PARITY_MATRIX.md from the canonical tool list.
 * Drift fails CI when the committed matrix differs from generator output.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const outPath = path.join(repoRoot, "docs/reviews/MCP_TOOL_PARITY_MATRIX.md");

const rows = [
  ["remember", "daemon.memory.remember", "burnbar_remember", "—", "fail-closed write"],
  ["recall", "daemon.memory.recall", "burnbar_recall", "burnbar_search_knowledge", "version-floored / sealed"],
  ["context_pack", "daemon.code.context_pack", "burnbar_context_pack / burnbar_code_context_pack", "—", "untrusted-wrapped"],
  ["forget", "daemon.memory.forget", "burnbar_forget", "device delete callable", "two-phase + receipts"],
  ["search_code", "daemon.code.search", "burnbar_search_code", "burnbar_search_code", "semanticAvailable honest"],
  ["index_project", "daemon.code.index_project", "burnbar_index_project", "—", "local-only"],
  ["index_status", "daemon.code.index_status", "burnbar_index_status", "burnbar_list_search_index_status", "—"],
  ["doctor", "daemon.code.ops_diagnostics", "burnbar_memory_doctor", "/readyz", "alias documented"],
  ["audit_trail", "daemon.memory.audit_trail", "burnbar_audit_trail", "—", "label-only chain"],
  ["get_symbol", "daemon.code.get_symbol", "burnbar_get_symbol", "—", "lexical/static"],
  ["find_references", "daemon.code.find_references", "burnbar_find_references", "—", "lexical/static"],
  ["call_graph", "daemon.code.call_graph", "burnbar_call_graph", "—", "lexical/static"],
  ["diagnostics", "daemon.code.diagnostics", "burnbar_diagnostics", "—", "cached-file tier"],
  ["memory_analytics", "daemon.memory.analytics", "burnbar_memory_analytics", "—", "—"],
  ["explore", "daemon.code.explore", "burnbar_explore", "—", "repo-map tier"],
  ["get_memory", "— (chat authority read)", "burnbar_get_memory", "—", "B6 chat DB read"],
  ["list_memories", "— (chat authority read)", "burnbar_list_memories", "—", "B6 paged read"],
  ["list_entities", "— (chat authority read)", "burnbar_list_entities", "—", "B6 entity buckets"],
  ["update_memory", "— (Mac-owned)", "burnbar_update_memory", "—", "fail-closed CHAT_MEMORY_WRITE_REQUIRES_MAC"],
  ["forget_all", "— (Mac-owned)", "burnbar_forget_all", "—", "fail-closed CHAT_MEMORY_WRITE_REQUIRES_MAC"],
];

const header = `# MCP tool parity matrix (generated)

> **Do not edit by hand.** Regenerate with \`node scripts/ci/generate-mcp-tool-parity-matrix.mjs\`.
> CI compares this file to generator output (task D8).

| Parity tool | Daemon RPC | Python stdio | Hosted | Tier / notes |
|---|---|---|---|---|
`;

const body = rows
  .map(([tool, daemon, python, hosted, notes]) => `| ${tool} | ${daemon} | ${python} | ${hosted} | ${notes} |`)
  .join("\n");

const footer = `
## Cross-cutting invariants

- \`trace_id\` on hosted tool responses (D6)
- Per-tool rate buckets — no silent \`metadata:standard\` fallback (D3/D4)
- Privileged local writes operator-gated (D6)
- Chat-memory writes Mac-owned; Python read tools use main DB \`agent_memories(source_kind='chat')\`
`;

const content = header + body + footer + "\n";
const checkOnly = process.argv.includes("--check");

if (checkOnly) {
  const existing = readFileSync(outPath, "utf8");
  if (existing !== content) {
    console.error("MCP tool parity matrix drift — run node scripts/ci/generate-mcp-tool-parity-matrix.mjs");
    process.exit(1);
  }
  console.log("MCP tool parity matrix OK");
} else {
  writeFileSync(outPath, content);
  console.log(`Wrote ${outPath}`);
}
