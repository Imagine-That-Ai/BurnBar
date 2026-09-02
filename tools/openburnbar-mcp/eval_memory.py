#!/usr/bin/env python3
"""
Retrieval quality eval for the local memory engine.

Seeds a gold set of durable memories (the kind of thing a coding agent should
remember about a project and its owner), then asks paraphrased questions that
deliberately avoid the memory's own keywords, and scores lexical / semantic /
hybrid recall with Recall@1, Recall@5 and MRR.

Usage:
    .venv/bin/python eval_memory.py                # auto: Ollama nomic-embed-text if reachable
    .venv/bin/python eval_memory.py --provider none  # lexical only
    .venv/bin/python eval_memory.py --model mxbai-embed-large

The eval never touches the real memory store: it runs in a temp directory.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import memory_engine as me  # noqa: E402

GOLD: list[dict[str, object]] = [
    {
        "id": "pr",
        "text": "Alberto prefers fewer, fatter PRs with one theme each instead of many thin slices.",
        "kind": "preference",
    },
    {
        "id": "swear",
        "text": "Alberto is fine with swearing when it lands; no corporate tone, no sycophancy.",
        "kind": "preference",
    },
    {
        "id": "brevity",
        "text": "Answers should be brief: if it fits in one sentence, one sentence is what Alberto gets.",
        "kind": "preference",
    },
    {
        "id": "peer",
        "text": "The daemon rejects RPC peers that fail first-party code-signature verification with error -32001.",
        "kind": "gotcha",
    },
    {
        "id": "sqlcipher",
        "text": "openburnbar.sqlite is SQLCipher-encrypted; stdlib sqlite3 cannot open it and reads must go through the daemon.",
        "kind": "architecture",
    },
    {
        "id": "cli",
        "text": "openburnbar-cli exposes search-sql and recall but has no memory write subcommand.",
        "kind": "fact",
    },
    {
        "id": "corpus",
        "text": "The shared secret scanner corpus lives at tools/project-code-memory/secret-pattern-corpus.json and tags patterns as secret or pii.",
        "kind": "architecture",
    },
    {
        "id": "fk",
        "text": "The fix for silently-off foreign keys was adding PRAGMA foreign_keys=ON inside ensure_schema.",
        "kind": "gotcha",
    },
    {
        "id": "ci",
        "text": "CI runs pytest for tools/openburnbar-mcp on Python 3.11 in agent-tools-ci.yml.",
        "kind": "architecture",
    },
    {
        "id": "ruff",
        "text": "ruff.toml targets py311, line length 120, and selects E, F, W, B, UP plus a few S rules.",
        "kind": "fact",
    },
    {
        "id": "factory",
        "text": "Codex is the independent reviewer and approval gate; Cursor Bugbot output is never approval evidence.",
        "kind": "decision",
    },
    {
        "id": "mac",
        "text": "The Mac app build is nightly and is not a merge ticket; only fast checks gate the door.",
        "kind": "decision",
    },
    {
        "id": "cheap",
        "text": "Long low-value jobs like bulk tests go to Agy with Gemini Flash at medium effort, not Claude Opus.",
        "kind": "decision",
    },
    {
        "id": "mem0",
        "text": "mem0 is an advisory retrieval cache for the wiki mirror, not policy and not source of truth.",
        "kind": "fact",
    },
    {
        "id": "pensieve",
        "text": "Pensieve is the member-facing name for the end-to-end-encrypted cloud memory; the provider never sees plaintext.",
        "kind": "architecture",
    },
    {
        "id": "nlembed",
        "text": "The daemon embeds code chunks with Apple NLEmbedding so no model file has to ship.",
        "kind": "architecture",
    },
    {
        "id": "hnsw",
        "text": "The app's vector backend is a pure-Swift HNSW index with persistent snapshots under VectorIndexes.",
        "kind": "architecture",
    },
    {
        "id": "castle",
        "text": "Castle runtime wrappers write status.json sentinels under Application Support/OpenBurnBar/castle/runs/<run-id>/.",
        "kind": "fact",
    },
    {
        "id": "landed",
        "text": "A Castle worker only counts as landed when the done marker exists and worktree HEAD differs from the base SHA.",
        "kind": "gotcha",
    },
    {
        "id": "hermes",
        "text": "hermes_proxy.py is a stdlib-only OpenAI-compatible proxy that records usage rows for every chat completion.",
        "kind": "architecture",
    },
    {
        "id": "ledger",
        "text": "When the daemon is offline, usage rows fall back to a file-locked append on usage-events.jsonl.",
        "kind": "gotcha",
    },
    {
        "id": "idem",
        "text": "Re-sending the same idempotency_key to the usage ledger never double-counts spend.",
        "kind": "fact",
    },
    {
        "id": "toolset",
        "text": "BURNBAR_MCP_TOOLSET=memory narrows the local MCP to the corpus and memory tools; ops keeps FinOps only.",
        "kind": "fact",
    },
    {
        "id": "stash",
        "text": "Never use bare git stash in worktrees; the stash stack is shared and another session may pop it.",
        "kind": "gotcha",
    },
    {
        "id": "worktree",
        "text": "Each Claude session works in an isolated git worktree under .claude/worktrees and must not cd to the main checkout.",
        "kind": "procedure",
    },
    {
        "id": "context7",
        "text": "Use Context7 for current library docs before answering API questions; never put secrets in its queries.",
        "kind": "procedure",
    },
    {
        "id": "semble",
        "text": "Repo exploration uses semble for semantic search, serena for symbols, and rg for exact strings; not Warp.",
        "kind": "procedure",
    },
    {
        "id": "receipt",
        "text": "When agents react to each other they leave a Cross-agent receipt in the PR: saw, reaction, status, next owner.",
        "kind": "procedure",
    },
    {
        "id": "email",
        "text": "Alberto's email is alberto8793@gmail.com and it is only used for attribution.",
        "kind": "profile",
    },
    {
        "id": "mixedbread",
        "text": "Mixedbread's store API uploads files with metadata and searches with filters like {key, operator, value}.",
        "kind": "fact",
    },
    {
        "id": "mem0add",
        "text": "mem0's add() extracts facts with an LLM and decides ADD, UPDATE, DELETE or NONE against similar memories.",
        "kind": "fact",
    },
    {
        "id": "ollama",
        "text": "Ollama on this Mac runs under Rosetta via arch -x86_64 and serves embeddings on port 11434.",
        "kind": "fact",
    },
    {
        "id": "nomic",
        "text": "nomic-embed-text produces 768-dimensional embeddings and is the default local embedding model.",
        "kind": "fact",
    },
    {
        "id": "walkthrough",
        "text": "The in-app memory tour is MemoryMCPWalkthroughView with five spotlight pages reachable via Help or Shift-Command-M.",
        "kind": "fact",
    },
    {
        "id": "quarantine",
        "text": "New chat memories default to review status quarantined and cannot be injected until approved.",
        "kind": "architecture",
    },
    {
        "id": "untrusted",
        "text": "Every retrieved snippet is wrapped between OPENBURNBAR_UNTRUSTED_CODE_V1 markers so prompts treat it as data.",
        "kind": "architecture",
    },
    {
        "id": "budget",
        "text": "BudgetGate is a per-credential USD gate that throws BudgetBlockedError and must not gate subscription credentials.",
        "kind": "gotcha",
    },
    {
        "id": "version",
        "text": "Vectors carry an embedding version and are never compared across versions; a model swap re-embeds.",
        "kind": "architecture",
    },
    {
        "id": "release",
        "text": "Release bumps CURRENT_PROJECT_VERSION and binds the owner-emergency packet to the tagged build.",
        "kind": "procedure",
    },
    {
        "id": "timezone",
        "text": "Alberto works from Chicago, so timestamps in reports should be shown in Central time.",
        "kind": "profile",
    },
]

QUERIES: list[tuple[str, str]] = [
    ("how does Alberto like pull requests sized", "pr"),
    ("is profanity acceptable in replies", "swear"),
    ("how long should my answers be", "brevity"),
    ("why does the socket call fail with a signature error", "peer"),
    ("can python read the main database file directly", "sqlcipher"),
    ("does the command line tool let me write memories", "cli"),
    ("where are the credential detection regexes kept", "corpus"),
    ("what fixed the constraint enforcement bug in the schema setup", "fk"),
    ("which python version runs the MCP tests in CI", "ci"),
    ("who has final say on merging a pull request", "factory"),
    ("does a failing macOS build block merges", "mac"),
    ("which model should run cheap bulk test jobs", "cheap"),
    ("is the wiki cache authoritative for policy", "mem0"),
    ("what is the customer-facing name of the encrypted memory product", "pensieve"),
    ("which embedding model does the daemon use for source code", "nlembed"),
    ("what approximate nearest neighbour structure does the app use", "hnsw"),
    ("where do worker run status files get written", "castle"),
    ("what proves a worker actually committed something", "landed"),
    ("what happens to spend records when the background service is down", "ledger"),
    ("can I safely retry a usage event", "idem"),
    ("how do I shrink the tool list for coding agents", "toolset"),
    ("why is stashing dangerous here", "stash"),
    ("where should I look up the latest SDK documentation", "context7"),
    ("what should I include when responding to another agent's review", "receipt"),
    ("what is Alberto's email address", "email"),
    ("how does the competing memory library decide to overwrite an old fact", "mem0add"),
    ("what vector size does the default embedder emit", "nomic"),
    ("are freshly extracted memories immediately usable in prompts", "quarantine"),
    ("how are search results protected against prompt injection", "untrusted"),
    ("what timezone should reports use", "timezone"),
]


def _provider(name: str, model: str) -> me.EmbeddingProvider:
    if name == "none":
        return me.NullEmbeddingProvider("eval: lexical only")
    if name == "fake":
        return me.FakeEmbeddingProvider()
    os.environ[me.EMBEDDING_PROVIDER_ENV] = "ollama"
    os.environ[me.EMBEDDING_MODEL_ENV] = model
    me.reset_provider_cache_for_tests()
    provider = me.embedding_provider()
    if not provider.available:
        print(f"embedding provider unavailable: {provider.describe()}", file=sys.stderr)
        return me.NullEmbeddingProvider("eval: ollama unavailable")
    return provider


def run(provider_name: str, model: str, verbose: bool) -> dict[str, object]:
    provider = _provider(provider_name, model)
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp) / "repo"
        repo.mkdir()
        engine = me.MemoryEngine.open(Path(tmp) / "eval.sqlite", provider=provider)
        id_map: dict[str, str] = {}
        started = time.perf_counter()
        for item in GOLD:
            result = engine.remember(str(item["text"]), project_path=str(repo), kind=str(item["kind"]))
            assert result["event"] == "ADD", (item["id"], result)
            id_map[result["memoryID"]] = str(item["id"])
        seed_ms = (time.perf_counter() - started) * 1000
        modes = ["lexical", "hybrid"] + (["semantic"] if provider.available else [])
        report: dict[str, object] = {
            "provider": provider.describe(),
            "memories": len(GOLD),
            "queries": len(QUERIES),
            "seedMs": round(seed_ms, 1),
            "modes": {},
        }
        for mode in modes:
            hits1 = hits5 = 0
            rr_total = 0.0
            latencies: list[float] = []
            misses: list[tuple[str, str, list[str]]] = []
            for query, expected in QUERIES:
                t0 = time.perf_counter()
                results = engine.recall(query, project_path=str(repo), limit=5, mode=mode, reinforce=False)["results"]
                latencies.append((time.perf_counter() - t0) * 1000)
                ranked = [id_map.get(item["memoryID"], "?") for item in results]
                if ranked and ranked[0] == expected:
                    hits1 += 1
                if expected in ranked:
                    hits5 += 1
                    rr_total += 1.0 / (ranked.index(expected) + 1)
                else:
                    misses.append((query, expected, ranked))
            n = len(QUERIES)
            latencies.sort()
            report["modes"][mode] = {  # type: ignore[index]
                "recall@1": round(hits1 / n, 3),
                "recall@5": round(hits5 / n, 3),
                "mrr": round(rr_total / n, 3),
                "p50Ms": round(latencies[len(latencies) // 2], 1),
                "p95Ms": round(latencies[int(len(latencies) * 0.95) - 1], 1),
                "misses": [{"query": q, "expected": e, "got": g} for q, e, g in misses] if verbose else len(misses),
            }
        engine.close()
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--provider", choices=["auto", "none", "fake"], default="auto")
    parser.add_argument("--model", default=me.DEFAULT_EMBEDDING_MODEL)
    parser.add_argument("--verbose", action="store_true", help="list misses per mode")
    parser.add_argument("--json", action="store_true", help="print the raw report as JSON")
    args = parser.parse_args()
    report = run(args.provider, args.model, args.verbose)
    if args.json:
        print(json.dumps(report, indent=2))
        return
    provider = report["provider"]
    print(
        f"provider: {provider.get('provider')} model={provider.get('model')} dim={provider.get('dimension')} available={provider.get('available')}"
    )
    print(f"memories: {report['memories']}  queries: {report['queries']}  seed: {report['seedMs']} ms")
    print(f"{'mode':<10}{'R@1':>8}{'R@5':>8}{'MRR':>8}{'p50ms':>9}{'p95ms':>9}{'misses':>8}")
    for mode, stats in report["modes"].items():  # type: ignore[union-attr]
        misses = stats["misses"] if isinstance(stats["misses"], int) else len(stats["misses"])
        print(
            f"{mode:<10}{stats['recall@1']:>8}{stats['recall@5']:>8}{stats['mrr']:>8}{stats['p50Ms']:>9}{stats['p95Ms']:>9}{misses:>8}"
        )
        if args.verbose and not isinstance(stats["misses"], int):
            for miss in stats["misses"]:
                print(f"    miss: {miss['query']!r} expected={miss['expected']} got={miss['got']}")


if __name__ == "__main__":
    main()
