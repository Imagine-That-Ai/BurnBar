#!/usr/bin/env bash
# check-docs-freshness.sh — shrink-only stale-docs budget (wave 4).
#
# A doc is stale when it is an orphan (no inbound markdown link from any
# tracked .md, no `docs/...` mention from any other tracked file) last
# touched more than STALE_DAYS ago. Point-in-time trees (audits,
# diligence, evidence, reviews, legal, archive) are records by design
# and excluded. Age comes from git history, never mtime, so fresh
# checkouts measure correctly.
#
# The gate fails when the stale total grows above the baseline. Monthly
# pruning (link it, refresh it, or `git mv` it to docs/archive/YYYY-MM/)
# drives the number down; --update locks in the new floor.
#
# Usage:
#   scripts/ci/check-docs-freshness.sh           # fail on growth
#   scripts/ci/check-docs-freshness.sh --update  # lower the ceiling (never raise)
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys
import time
from pathlib import Path

STALE_DAYS = 90
BASELINE = Path("budgets/docs-freshness-baseline.json")
EXCLUDED_SUBSTRINGS = (
    "audits/", "diligence/", "evidence/", "reviews/", "legal/",
    "/archive/", "Archive", "legacy", "Legacy",
)
LINK_RE = re.compile(r"\]\(([^)#?]*(?:\.md)?)(?:#[^)]*)?\)")
MENTION_RE = re.compile(r"docs/[A-Za-z0-9_][A-Za-z0-9_./-]*\.md")

mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode not in ("", "--check", "--update"):
    print("usage: check-docs-freshness.sh [--check|--update]", file=sys.stderr)
    sys.exit(2)


def git(*args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


tracked_md = git("ls-files", "*.md").splitlines()
docs = [p for p in git("ls-files", "docs/*.md").splitlines() if p.endswith(".md")]
repo = Path(".").resolve()

# Inbound markdown links (repo-wide) + plain mentions from non-md files.
referenced = set()
for md in tracked_md:
    try:
        text = (repo / md).read_text()
    except OSError:
        continue
    base = Path(md).parent
    for match in LINK_RE.findall(text):
        if not match.endswith(".md"):
            continue
        if match.startswith(("http://", "https://", "mailto:", "#", "/")):
            continue
        try:
            target = str((base / match).resolve().relative_to(repo))
        except ValueError:
            continue  # link escapes the repo
        referenced.add(target)
try:
    # Mentions only count from live files: point-in-time trees (evidence
    # manifests inventory every doc path) must not launder orphans.
    mentions = subprocess.run(
        ["git", "grep", "-ohE", r"docs/[A-Za-z0-9_][A-Za-z0-9_./-]*\.md",
         "--", ":!*.md", ":!docs/**/evidence/**", ":!docs/audits/**",
         ":!docs/diligence/**", ":!docs/reviews/**", ":!docs/legal/**",
         ":!docs/archive/**"],
        capture_output=True, text=True, check=True,
    ).stdout
    for mention in MENTION_RE.findall(mentions):
        referenced.add(mention)
except subprocess.CalledProcessError:
    pass  # exit 1 == no mentions at all

now = time.time()
stale = []
for doc in sorted(docs):
    if any(hint in doc for hint in EXCLUDED_SUBSTRINGS):
        continue
    if doc in referenced:
        continue
    try:
        touched = int(git("log", "-1", "--format=%ct", "--", doc).strip())
    except (ValueError, subprocess.CalledProcessError):
        continue  # untracked-in-history (staged but uncommitted): not stale
    age_days = (now - touched) / 86400
    if age_days > STALE_DAYS:
        stale.append(doc)

baseline = json.loads(BASELINE.read_text())
if mode == "--update":
    if len(stale) > baseline["total"]:
        print(
            f"::error::--update refused: live {len(stale)} > baseline "
            f"{baseline['total']}. The ceiling may only shrink.",
            file=sys.stderr,
        )
        sys.exit(1)
    baseline["total"] = len(stale)
    BASELINE.write_text(json.dumps(baseline, indent=2) + "\n")
    print(f"Docs-freshness baseline updated: {len(stale)} stale doc(s).")
    sys.exit(0)

print(f"  Stale docs: live {len(stale)} vs ceiling {baseline['total']}")
if len(stale) > baseline["total"]:
    print(
        f"FAIL: stale docs grew {baseline['total']} -> {len(stale)}. "
        "Link, refresh, or archive them (docs/archive/YYYY-MM/).",
        file=sys.stderr,
    )
    for doc in stale[:30]:
        print(f"  {doc}", file=sys.stderr)
    if len(stale) > 30:
        print(f"  ... and {len(stale) - 30} more", file=sys.stderr)
    sys.exit(1)
print("Docs-freshness ratchet OK.")
PY
