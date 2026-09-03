#!/usr/bin/env python3
"""
Quality eval for the local memory engine: retrieval, extraction, and the gate.

Retrieval (default) seeds a gold set of durable memories (the kind of thing a
coding agent should remember about a project and its owner), then asks
paraphrased questions that deliberately avoid the memory's own keywords, and
scores lexical / semantic / hybrid recall with Recall@1, Recall@5 and MRR.

`--extraction` replays the checked-in gold set of developer conversations
through the heuristic extractor and scores recall, a precision proxy, facts
invented over conversations with nothing durable in them, and forbidden-string
leaks. `--gate` prints the secret detection matrix (raw / base64 / hex /
URL-encoded) so encoded-secret coverage is visible rather than assumed.

Usage:
    .venv/bin/python eval_memory.py                  # auto: Ollama nomic-embed-text if reachable
    .venv/bin/python eval_memory.py --provider none  # lexical only
    .venv/bin/python eval_memory.py --model mxbai-embed-large
    .venv/bin/python eval_memory.py --extraction     # heuristic extraction quality
    .venv/bin/python eval_memory.py --gate           # secret detection matrix

The eval never touches the real memory store: it runs in a temp directory.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import random
import re
import string
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import memory_engine as me  # noqa: E402

EXTRACTION_GOLD = Path(__file__).resolve().parent / "eval" / "extraction_gold.json"

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
        "text": "openburnbar-cli exposes search-sql and recall for reads, and memory-remember / memory-forget as the signed write courier the local memory MCP mirrors through.",
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


SECRET_SHAPE_SEED = 20260902
_ALNUM = string.ascii_letters + string.digits
_B64 = _ALNUM + "+/"
_UPPER = string.ascii_uppercase + string.digits
_URLSAFE = _ALNUM + "-_"
_HEX = string.hexdigits[:16]


_PEM_DASHES = "-" * 5


def _pem_block(kind: str, body: str) -> str:
    """A PEM block assembled from fragments.

    The `BEGIN … PRIVATE KEY` header is never written out as one literal: a
    committed line carrying it matches the repo's own gitleaks `private-key`
    rule even though nothing here is a key.
    """
    return f"{_PEM_DASHES}BEGIN {kind}{_PEM_DASHES}\n{body}\n{_PEM_DASHES}END {kind}{_PEM_DASHES}"


def _b64url_json(payload: dict[str, str]) -> str:
    """One base64url JWT segment, built rather than pasted for the same reason."""
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _openssh_armor() -> str:
    """The fixed head of an OpenSSH key blob, encoded from the bytes it stands for.

    Pasting the base64 would put a high-entropy literal on a source line, which
    gitleaks reads as a committed credential; encoding it here keeps the shape
    the corpus pattern looks for without a literal.
    """
    magic = b"openssh-key-v1\x00\x00\x00\x00\x04none\x00\x00\x00\x04none"
    return base64.b64encode(magic).decode("ascii").rstrip("=")


def _secret_shapes() -> dict[str, str]:
    """One synthetic token per secret shape the shared corpus flags standalone.

    Generated rather than committed: a credential-shaped literal checked into
    the repo would trip the repo's own secret scanners, so both this eval and
    `tests/test_gate_adversarial.py` build their tokens from this seeded RNG.
    That applies to the fixed halves too -- the JWT header/payload and the PEM
    armor are assembled from fragments by the helpers above. Shapes the corpus
    does not detect standalone stay out of the list -- a gap belongs in the
    README, not in a matrix that claims coverage.
    """
    rng = random.Random(SECRET_SHAPE_SEED)

    def tok(length: int, alphabet: str = _ALNUM) -> str:
        return "".join(rng.choice(alphabet) for _ in range(length))

    return {
        "github_pat": "ghp_" + tok(36),
        "github_fine_grained_pat": "github_pat_" + tok(22) + "_" + tok(59),
        "aws_access_key_id": "AKIA" + tok(16, _UPPER),
        "aws_secret_access_key": "aws_secret_access_key=" + tok(40, _B64),
        "slack_bot_token": "xoxb-" + tok(12, string.digits) + "-" + tok(12, string.digits) + "-" + tok(24),
        "openai_api_key": "sk-" + tok(48),
        "anthropic_api_key": "sk-ant-api03-" + tok(95) + "AA",
        "stripe_secret_key": "sk_live_" + tok(24),
        "google_api_key": "AIza" + tok(35),
        "jwt": _b64url_json({"alg": "HS256", "typ": "JWT"})
        + "."
        + _b64url_json({"sub": "12345"})
        + "."
        + tok(43, _URLSAFE),
        "pem_private_key": _pem_block("RSA PRIVATE KEY", tok(64, _B64) + "\n" + tok(64, _B64)),
        "ssh_private_key": _pem_block("OPENSSH PRIVATE KEY", _openssh_armor() + tok(20, _B64)),
        "postgres_uri": "postgres://svc_deploy:" + tok(24) + "@db.internal.example:5432/burnbar",
        "bearer_header": "Authorization: Bearer " + tok(64),
        "npmrc_auth_token": "//registry.npmjs.org/:_authToken=" + tok(36),
        "sendgrid_api_key": "SG." + tok(22, _URLSAFE) + "." + tok(43, _URLSAFE),
        "password_assignment": "password=" + tok(28),
        "gitlab_token": "glpat-" + tok(20),
        "dotenv_secret": "API_SECRET=" + tok(40),
        "vault_token": "hvs." + tok(48),
        "slack_webhook": "https://hooks.slack.com/services/T" + tok(8, _UPPER) + "/B" + tok(10, _UPPER) + "/" + tok(24),
        "xai_api_key": "xai-" + tok(80),
        "kubernetes_secret": "apiVersion: v1\nkind: Secret\nmetadata:\n  name: burnbar\ndata:\n  token: "
        + tok(40, _B64)
        + "=",
        "generic_hex_key": "signing_key=" + tok(64, _HEX),
        # Appended, not inserted: the seeded stream is positional, and a shape in
        # the middle would silently re-roll every token after it.
        "twilio_api_key": "SK" + tok(32, _HEX),
    }


SECRET_SHAPES: dict[str, str] = _secret_shapes()

_SECRET_PLACEHOLDER_RE = re.compile(r"\{\{secret:([a-z0-9_]+)\}\}")


def run_gate_matrix() -> list[dict[str, object]]:
    """Per shape: does the gate still see it raw, base64-encoded, hex-encoded,
    URL-encoded? A False is a real coverage gap, not a test failure."""
    matrix: list[dict[str, object]] = []
    for shape, text in SECRET_SHAPES.items():
        raw = text.encode("utf-8")
        matrix.append(
            {
                "shape": shape,
                "raw": bool(me.scan_text(text).secret_labels),
                "base64": bool(me.scan_text(base64.b64encode(raw).decode("ascii")).secret_labels),
                "hex": bool(me.scan_text(raw.hex()).secret_labels),
                "urlencoded": bool(me.scan_text(urllib.parse.quote(text)).secret_labels),
            }
        )
    return matrix


def _expand_secrets(text: str) -> str:
    """Swap `{{secret:<shape>}}` for its synthetic token, so the gold set can
    carry credential-shaped pastes without committing one."""

    def swap(match: re.Match[str]) -> str:
        shape = match.group(1)
        if shape not in SECRET_SHAPES:
            raise KeyError(f"gold set references unknown secret shape {shape!r}")
        return SECRET_SHAPES[shape]

    return _SECRET_PLACEHOLDER_RE.sub(swap, text)


def _covers(body: str, keywords: list[str]) -> bool:
    lowered = body.lower()
    return all(keyword.lower() in lowered for keyword in keywords)


def run_extraction(gold_path: Path | str = EXTRACTION_GOLD, *, verbose: bool = False) -> dict[str, object]:
    """Score `memory_engine.heuristic_extract` against the checked-in gold set.

    recall     = expected facts an extracted fact covers, over expected facts.
    precision  = extracted facts that cover an expected fact, over facts
                 extracted from the conversations that expect something.
    emptyCaseFacts = facts invented over the "nothing durable here" cases.
    leaks      = forbidden strings that reached an extracted fact.
    """
    gold = json.loads(Path(gold_path).read_text(encoding="utf-8"))
    cases = gold["cases"]
    expected_total = hits = covering = scored_facts = empty_case_facts = 0
    empty_cases = 0
    leaks: list[dict[str, str]] = []
    misses: list[dict[str, object]] = []
    for case in cases:
        messages = [
            {"role": message["role"], "content": _expand_secrets(str(message["content"]))}
            for message in case["messages"]
        ]
        facts = [fact.text for fact in me.heuristic_extract(messages)]
        for forbidden in case.get("forbidden") or []:
            leaks.extend(
                {"case": str(case["id"]), "forbidden": forbidden, "fact": body} for body in facts if forbidden in body
            )
        expected = case.get("expected") or []
        if not expected:
            empty_cases += 1
            empty_case_facts += len(facts)
            continue
        scored_facts += len(facts)
        covering += sum(1 for body in facts if any(_covers(body, want["keywords"]) for want in expected))
        for want in expected:
            expected_total += 1
            if any(_covers(body, want["keywords"]) for body in facts):
                hits += 1
            else:
                miss: dict[str, object] = {"case": str(case["id"]), "keywords": list(want["keywords"])}
                if verbose:
                    miss["facts"] = facts
                misses.append(miss)
    return {
        "gold": str(gold_path),
        "cases": len(cases),
        "emptyCases": empty_cases,
        "expected": expected_total,
        "hits": hits,
        "recall": round(hits / expected_total, 3) if expected_total else 0.0,
        "precision": round(covering / scored_facts, 3) if scored_facts else 0.0,
        "facts": scored_facts,
        "emptyCaseFacts": empty_case_facts,
        "leaks": len(leaks),
        "leakDetails": leaks,
        "misses": misses,
    }


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


def _print_extraction(report: dict[str, object], verbose: bool) -> None:
    print(f"gold: {report['gold']}")
    print(
        f"cases: {report['cases']}  ({report['emptyCases']} with nothing durable)  expected facts: {report['expected']}"
    )
    print(f"{'recall':<18}{report['recall']}   ({report['hits']}/{report['expected']})")
    print(f"{'precision':<18}{report['precision']}   ({report['facts']} facts over the scoring cases)")
    print(f"{'empty-case facts':<18}{report['emptyCaseFacts']}")
    print(f"{'leaks':<18}{report['leaks']}")
    for leak in report["leakDetails"]:  # type: ignore[union-attr]
        print(f"    leak: {leak['case']} {leak['forbidden']!r} in {leak['fact']!r}")
    for miss in report["misses"]:  # type: ignore[union-attr]
        print(f"    miss: {miss['case']} {miss['keywords']}")
        if verbose:
            for fact in miss.get("facts", []):
                print(f"        got: {fact}")


def _print_gate_matrix(matrix: list[dict[str, object]]) -> None:
    print(f"{'shape':<26}{'raw':>7}{'base64':>9}{'hex':>7}{'urlenc':>9}")
    for row in matrix:
        cells = "".join(
            f"{'yes' if row[key] else 'NO':>{width}}"
            for key, width in (("raw", 7), ("base64", 9), ("hex", 7), ("urlencoded", 9))
        )
        print(f"{row['shape']:<26}{cells}")
    gaps = {
        str(row["shape"]): missing
        for row in matrix
        if (missing := [key for key in ("raw", "base64", "hex", "urlencoded") if not row[key]])
    }
    print(f"\nshapes: {len(matrix)}  with an encoding gap: {len(gaps)}")
    for shape, missing in gaps.items():
        print(f"    gap: {shape} undetected as {', '.join(missing)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--provider", choices=["auto", "none", "fake"], default="auto")
    parser.add_argument("--model", default=me.DEFAULT_EMBEDDING_MODEL)
    parser.add_argument("--verbose", action="store_true", help="list misses per mode")
    parser.add_argument("--json", action="store_true", help="print the raw report as JSON")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--extraction", action="store_true", help="score the heuristic extractor against the gold set")
    mode.add_argument("--gate", action="store_true", help="print the secret detection matrix")
    parser.add_argument("--gold", type=Path, default=EXTRACTION_GOLD, help="extraction gold set (with --extraction)")
    args = parser.parse_args()

    if args.extraction:
        extraction = run_extraction(args.gold, verbose=args.verbose)
        if args.json:
            print(json.dumps(extraction, indent=2))
        else:
            _print_extraction(extraction, args.verbose)
        return
    if args.gate:
        matrix = run_gate_matrix()
        if args.json:
            print(json.dumps(matrix, indent=2))
        else:
            _print_gate_matrix(matrix)
        return

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
