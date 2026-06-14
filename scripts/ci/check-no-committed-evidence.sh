#!/usr/bin/env bash
#
# Committed-evidence gate (finding M-004) — keep GCP/Firebase recon dumps OUT of git.
#
# Security-evidence bundles produced by
# scripts/ops/collect-firebase-security-evidence.mjs are CI artifacts ONLY. One was
# committed (security/evidence/firebase-security-evidence-latest.json) and leaks a
# complete recon map of the production project: the 12-digit project number, the
# project OWNER identity (a `roles/owner` IAM binding tied to a personal email),
# the service-account → role inventory, the Secret Manager name inventory, and KMS
# key paths. None of that belongs in a (currently public) repo, and it persists in
# history regardless of repo visibility.
#
# This gate FAILS CLOSED (exit 1) when EITHER:
#   • any tracked file matches `security/evidence/*.json`  (the M-004 path rule); or
#   • any tracked text file carries an obvious GCP-IAM-recon SIGNATURE — the literal
#     `roles/owner` (or roles/editor / roles/viewer) co-located with an IAM member
#     email (`user:`/`serviceAccount:`/`group:` …@…), or any email within a few
#     lines of `roles/owner`. The 12-digit project number is reported as
#     corroborating evidence ONLY on a file already flagged by the signature, so
#     legitimate public Firebase config (project.yml, Info.plist, web/console
#     firebaseClient.ts, runbooks — all of which carry the project number but no IAM
#     role bindings) is NOT flagged. That precision is what lets this become a
#     required check.
#
# IMPORTANT — this gate is necessary but NOT sufficient. The already-leaked file is
# still tracked AND in git history; a .gitignore rule does not untrack it. It must
# be `git rm --cached`'d, purged from history (git-filter-repo / BFG), and its
# exposed identifiers rotated, per:
#   docs/security/COMMITTED_EVIDENCE_REMEDIATION.md
# Until that is done this gate is EXPECTED to report the leaked file (exit 1) — that
# is correct behaviour; do not suppress it. Wire it into CI as a required check
# AFTER the file has been removed (see the runbook), or the first CI run fails red.
#
# No network, no credentials, no repo mutation: it reads `git ls-files` and file
# contents only.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

exec python3 - <<'PY'
import os
import re
import subprocess
import sys


def fatal(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


# ── Tracked files (the only thing that can leak via git) ──────────────────────
try:
    tracked = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout.splitlines()
except (OSError, subprocess.CalledProcessError) as exc:
    fatal(f"git ls-files failed (not a git work tree?): {exc}")
if not tracked:
    fatal("git ls-files returned no tracked files (not a git work tree?)")

# This gate and its runbook deliberately QUOTE the recon strings as examples, so
# exempt them — otherwise the gate would flag itself and never pass.
SELF_EXEMPT = {
    "scripts/ci/check-no-committed-evidence.sh",
    "docs/security/COMMITTED_EVIDENCE_REMEDIATION.md",
}

# ── Patterns ──────────────────────────────────────────────────────────────────
# M-004 path rule: any evidence-bundle JSON under security/evidence/.
EVIDENCE_PATH_RE = re.compile(r"^security/evidence/.*\.json$")

# A privileged IAM role binding (the shape `"role": "roles/owner"` and friends).
IAM_ROLE_RE = re.compile(r"roles/(owner|editor|viewer)\b")
# An IAM member identity carrying an email — only ever seen in dumped IAM policies.
IAM_MEMBER_RE = re.compile(r"\b(?:user|serviceAccount|group):[^\s\"']+@[^\s\"']+")
# A bare email (for the task's "email with roles/owner nearby" pattern, covering
# redacted member formats that drop the user:/serviceAccount: prefix).
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
# A 12-digit GCP project number — reported as corroborating evidence ONLY, never a
# standalone trigger (it legitimately appears in committed public Firebase config).
PROJECT_NUMBER_RE = re.compile(r"\b\d{12}\b")

# How close (in lines) an email must be to a roles/owner line to count as the
# "email + roles/owner nearby" recon signature.
NEARBY = 4

# Only sniff plausibly-text source/config/doc/data files for the content signature.
TEXT_EXTS = {
    ".json", ".jsonl", ".ndjson", ".yaml", ".yml", ".txt", ".md", ".markdown",
    ".tf", ".tfvars", ".env", ".ini", ".toml", ".cfg", ".conf", ".log",
    ".csv", ".tsv", ".xml", ".plist", ".properties", ".sh", ".bash",
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".rb", ".go",
    ".kt", ".kts", ".swift", ".gradle", ".java",
}


def is_text_candidate(path):
    return os.path.splitext(path)[1].lower() in TEXT_EXTS


def tracked_content(path):
    """Return the file's content as git would PUBLISH it — the staged/committed
    bytes, never the working tree. A sanitized working-tree copy laid over a
    recon-bearing index/HEAD must not fool the gate (M-004 audit hardening), so read
    the index (`:path`) first, then HEAD, and fall back to the on-disk copy ONLY
    when neither blob is retrievable (e.g. an intent-to-add entry)."""
    for ref in (f":{path}", f"HEAD:{path}"):
        try:
            out = subprocess.run(
                ["git", "show", ref], capture_output=True, check=True
            ).stdout
            return out.decode("utf-8", errors="replace")
        except (OSError, subprocess.CalledProcessError):
            continue
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None


# ── Scan ──────────────────────────────────────────────────────────────────────
# path_violations: files that match the M-004 evidence-bundle path rule.
# content_violations: path -> sorted list of human-readable reasons.
path_violations = [p for p in tracked if EVIDENCE_PATH_RE.match(p)]
content_violations = {}

# Fast pre-filter over the INDEX (staged/committed bytes — immune to a sanitized
# working tree): only files whose committed content carries a privileged IAM role
# binding can be an IAM-policy dump, so only those need the costlier proximity
# vetting. `git grep --cached -I -l` returns matching tracked text files in one pass
# and exits 1 (no error to us) when there are none. Fail safe to scanning all
# tracked files if git grep is unavailable.
try:
    candidates = subprocess.run(
        ["git", "grep", "--cached", "-I", "-l", "-E", r"roles/(owner|editor|viewer)"],
        capture_output=True, text=True
    ).stdout.splitlines()
except (OSError, subprocess.CalledProcessError):
    candidates = list(tracked)

for path in candidates:
    if path in SELF_EXEMPT or not is_text_candidate(path):
        continue
    text = tracked_content(path)
    if text is None:
        # A tracked text file whose committed bytes cannot be read cannot be vetted —
        # that is a finding (fail closed), not a pass.
        content_violations.setdefault(path, []).append(
            "could not read committed bytes (index/HEAD) to vet it"
        )
        continue

    if not IAM_ROLE_RE.search(text):
        # No privileged IAM role binding ⇒ not an IAM-policy dump. The 12-digit
        # project number on its own (public Firebase config) is intentionally fine.
        continue

    lines = text.splitlines()
    reasons = []

    # (a) roles/* binding + an IAM member email anywhere in the file.
    if IAM_MEMBER_RE.search(text):
        m = IAM_ROLE_RE.search(text)
        reasons.append(
            f"IAM role binding ({m.group(0)}) with member email(s) — looks like a "
            "dumped IAM policy"
        )

    # (b) any email within NEARBY lines of a roles/owner line (the task's pattern).
    role_owner_lines = [i for i, ln in enumerate(lines) if "roles/owner" in ln]
    for i in role_owner_lines:
        window = lines[max(0, i - NEARBY): i + NEARBY + 1]
        emails = sorted({e for ln in window for e in EMAIL_RE.findall(ln)})
        if emails:
            reasons.append(
                f"roles/owner near email(s) at line {i + 1}: {', '.join(emails[:3])}"
            )
            break

    # (c) corroborating: 12-digit project number(s), reported only on a flagged file.
    if reasons:
        numbers = sorted(set(PROJECT_NUMBER_RE.findall(text)))
        if numbers:
            reasons.append(
                f"plus 12-digit project number(s): {', '.join(numbers[:3])}"
            )
        content_violations[path] = reasons

# ── Report ────────────────────────────────────────────────────────────────────
if not path_violations and not content_violations:
    print("✓ check-no-committed-evidence: no tracked security-evidence bundles or "
          "GCP-IAM-recon dumps.")
    sys.exit(0)

print("✗ check-no-committed-evidence: GCP/Firebase recon material is committed (M-004).",
      file=sys.stderr)
print("", file=sys.stderr)

if path_violations:
    print("  Tracked security-evidence bundle(s) — CI artifacts, must not be in git:",
          file=sys.stderr)
    for p in sorted(set(path_violations)):
        print(f"    [evidence-bundle] {p}", file=sys.stderr)
    print("", file=sys.stderr)

if content_violations:
    print("  Tracked file(s) matching GCP-IAM-recon patterns:", file=sys.stderr)
    for p in sorted(content_violations):
        print(f"    [iam-recon] {p}", file=sys.stderr)
        for reason in content_violations[p]:
            print(f"        - {reason}", file=sys.stderr)
    print("", file=sys.stderr)

print("These bundles leak the project owner identity, project number, and the full "
      "IAM/Secret/KMS inventory.", file=sys.stderr)
print("Removing/ignoring the file going forward is not enough: the already-leaked "
      "copy is still in git history.", file=sys.stderr)
print("Run the manual remediation (git rm --cached + history purge + identifier "
      "rotation):", file=sys.stderr)
print("    docs/security/COMMITTED_EVIDENCE_REMEDIATION.md", file=sys.stderr)
print("", file=sys.stderr)
total = len(set(path_violations)) + len(content_violations)
print(f"Total: {total} offending path(s).", file=sys.stderr)
sys.exit(1)
PY
