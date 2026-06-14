#!/usr/bin/env bash
#
# Permanence meta-gate (plan Phase 6) — stop lint/type debt from re-entering.
#
# Fail-closed: no NEW lint/type suppression or checked-in baseline may enter the
# tree without an explicit, greppable justification. There is no separate
# baseline file to drift; the single source of truth for what is deliberately
# allowed is docs/LINT_RATIONALE.md.
#
# A flagged occurrence passes iff ONE of:
#   • a `reason: <text>` (or `reason = <text>`) token sits in a COMMENT on the
#     directive's line, or on a comment line directly above it (the rustfmt spot);
#   • Python: a coded `# noqa: <CODE>` (a bare `# noqa` is rejected);
#   • ESLint: the directive carries its native `-- <description>`;
#   • the file path is allowlisted in docs/LINT_RATIONALE.md — exact paths only
#     (no globs), and for source files scoped to the named token kind(s).
#
# Supersedes the former blunt source-suppression check: this gate adds escape
# hatches AND closes baseline re-introduction (budget files, baseline files, and
# config-level `--baseline` / `baseline = file()` re-pointing).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

exec python3 - <<'PY'
import fnmatch
import os
import re
import subprocess
import sys

RATIONALE = "docs/LINT_RATIONALE.md"

# Occurrence kinds that an allowlist entry may scope a source file to.
KNOWN_KINDS = {
    "eslint-disable", "ts-suppress", "noqa",
    "kotlin-suppress", "detekt", "swiftlint-disable", "rust-allow",
}


def fatal(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


# ── 1. Read the rationale doc ─────────────────────────────────────────────────
try:
    doc_lines = open(RATIONALE, encoding="utf-8").read().splitlines()
except OSError as exc:
    fatal(f"cannot read {RATIONALE}: {exc}")

# ── 2. Parse the allowlist: the FIRST block only, delimited by anchored,
#       whole-line HTML-comment markers. Anything malformed fails closed so the
#       parser cannot be re-opened by a stray BEGIN phrase in prose. ──────────
begin_re = re.compile(r"^\s*<!--\s*BEGIN:suppression-allowlist\s*-->\s*$")
end_re = re.compile(r"^\s*<!--\s*END:suppression-allowlist\s*-->\s*$")
begins = [i for i, ln in enumerate(doc_lines) if begin_re.match(ln)]
ends = [i for i, ln in enumerate(doc_lines) if end_re.match(ln)]
if len(begins) != 1 or len(ends) != 1 or ends[0] <= begins[0]:
    fatal(
        f"{RATIONALE} must contain exactly one BEGIN:suppression-allowlist and one "
        "END:suppression-allowlist marker (each on its own line, BEGIN first)."
    )

file_allow = set()      # exact paths whose budget/baseline ARTIFACT is permitted
inline_allow = {}       # exact path -> set of permitted occurrence kinds
for raw in doc_lines[begins[0] + 1:ends[0]]:
    s = raw.strip()
    if not s or s.startswith("```"):
        continue
    s = s.split("#", 1)[0].strip()  # trailing/full-line `# rationale`
    if not s:
        continue
    if "|" in s:
        path, kinds = s.split("|", 1)
        path = path.strip()
        kindset = {k.strip() for k in kinds.split(",") if k.strip()}
        bad_kinds = kindset - KNOWN_KINDS
        if bad_kinds:
            fatal(f"allowlist entry '{path}' names unknown kind(s): {sorted(bad_kinds)}")
        inline_allow.setdefault(path, set()).update(kindset)
    else:
        file_allow.add(s)

# Globs are forbidden in the allowlist — a single broad glob would silently
# neutralise the gate. Every entry must be an exact, currently-tracked path, so a
# stale entry (e.g. after a file is deleted) fails closed and forces cleanup.
tracked = subprocess.run(
    ["git", "ls-files"], capture_output=True, text=True, check=True
).stdout.splitlines()
tracked_set = set(tracked)
if not tracked:
    fatal("git ls-files returned no tracked files (not a git work tree?)")

allow_errors = []     # fatal: a glob could mask suppressions across the tree
allow_warnings = []   # non-fatal: a stale exact path grants nothing
for p in sorted(file_allow | set(inline_allow)):
    if any(c in p for c in "*?[]"):
        allow_errors.append(f"  {p}  — globs are not allowed; list the exact path")
    elif p not in tracked_set:
        # Harmless: an entry that matches no tracked file grants no amnesty. This
        # happens routinely when another PR deletes an allowlisted artifact (e.g.
        # a debt budget hitting zero), so it warns instead of breaking the build.
        allow_warnings.append(p)
if allow_errors:
    print(f"FATAL: invalid entries in {RATIONALE} allowlist:", file=sys.stderr)
    print("\n".join(allow_errors), file=sys.stderr)
    sys.exit(2)
for p in allow_warnings:
    print(f"warning: stale allowlist path (remove it from {RATIONALE}): {p}", file=sys.stderr)

# ── 3. Matchers ───────────────────────────────────────────────────────────────
# A justification must carry real text (≥ ~8 chars) so `reason:` / `reason:x`
# cannot be gamed into a no-op.
REASON = re.compile(r"reason\s*[:=]\s*\S[^\n]{6,}", re.IGNORECASE)
# A reason on the comment line directly above (rustfmt relocates an attribute's
# comment there). `#(?!\[)` accepts a Python comment but never a Rust attribute,
# so an adjacent *suppression* line is never mistaken for the next one's reason.
PREV_REASON = re.compile(r"^\s*(?://|/\*|\*|#(?!\[)).*reason\s*[:=]\s*\S[^\n]{6,}", re.IGNORECASE)
NOQA_CODED = re.compile(r"#\s*noqa\s*:\s*\S")
# ESLint's own sanctioned justification: `eslint-disable… -- <description>`.
ESLINT_DESC = re.compile(r"eslint-disable[\w-]*\b[^\n]*?--\s*\S[^\n]{2,}")

ESLINT_RE = re.compile(r"eslint-disable(?:-next-line|-line)?\b")
# @ts-* counts only as a leading comment directive (so prose like
# `// under @ts-nocheck because…` is ignored). `/{2,3}` also catches the
# triple-slash form, which TypeScript still honours.
TS_RE = re.compile(r"^\s*(?:/{2,3}|/\*|\*)\s*@ts-(?:ignore|expect-error|nocheck)\b")
NOQA_RE = re.compile(r"#\s*noqa\b")
KSUP_RE = re.compile(r"@(?:file:)?Suppress(?:Lint|Warnings)?\s*\(")
DETEKT_RE = re.compile(r"//\s*detekt:")
SLD_RE = re.compile(r"swiftlint:disable\b")
RALLOW_RE = re.compile(r"#!?\[\s*allow\s*\(")

TS_EXTS = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs",
           ".astro", ".vue", ".svelte")
EXT_PATTERNS = {
    TS_EXTS: [("eslint-disable", ESLINT_RE), ("ts-suppress", TS_RE)],
    (".py", ".pyi"): [("noqa", NOQA_RE)],
    (".kt", ".kts", ".java", ".gradle"): [("kotlin-suppress", KSUP_RE), ("detekt", DETEKT_RE)],
    (".swift",): [("swiftlint-disable", SLD_RE)],
    (".rs",): [("rust-allow", RALLOW_RE)],
}

# Config-level baseline re-introduction (the predecessor's protection).
CONFIG_BASELINE_RE = re.compile(r"--baseline\b|detekt-baseline|swiftlint-baseline|baseline\s*=\s*file")


def patterns_for(path):
    ext = os.path.splitext(path)[1]
    for exts, pats in EXT_PATTERNS.items():
        if ext in exts:
            return pats, ext
    return None, None


def comment_start(line, ext):
    """Index of the real comment start, skipping markers that appear inside a
    string/char literal — so a decoy string like `"// reason: x"` earlier on the
    line can never masquerade as a justification."""
    markers = ("#",) if ext in (".py", ".pyi", ".yml", ".yaml") else ("//", "/*")
    quote = None
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"', "`"):
            quote = c
            i += 1
            continue
        for mk in markers:
            if line.startswith(mk, i):
                return i
        i += 1
    return -1


def reason_in_comment(line, ext):
    """True iff a `reason:` token sits in the line's real comment (not in code/args)."""
    i = comment_start(line, ext)
    return i != -1 and bool(REASON.search(line[i:]))


def is_config_file(path):
    base = os.path.basename(path)
    if base.endswith(".gradle") or base.endswith(".gradle.kts"):
        return True
    if base == ".swiftlint.yml":
        return True
    if re.match(r"detekt.*\.ya?ml$", base):
        return True
    if path.startswith(".github/workflows/") and path.endswith((".yml", ".yaml")):
        return True
    return False


def justified(kind, line, prev, ext, path):
    if kind in inline_allow.get(path, ()):
        return True
    if reason_in_comment(line, ext) or PREV_REASON.match(prev):
        return True
    if kind == "eslint-disable" and ESLINT_DESC.search(line):
        return True
    if kind == "noqa" and NOQA_CODED.search(line):
        return True
    return False


violations = []  # (path, lineno, kind, text)

# ── 4. File-level artifacts: budget jsons + baseline files ───────────────────
for f in tracked:
    base = os.path.basename(f).lower()
    if fnmatch.fnmatch(f, "budgets/*.json"):
        if f not in file_allow:
            violations.append((f, 0, "budget-json", "checked-in debt budget not in allowlist"))
    elif any(fnmatch.fnmatch(base, f"*baseline*{ext}") for ext in (".xml", ".yml", ".yaml")):
        if f not in file_allow:
            violations.append((f, 0, "baseline-file", "checked-in lint baseline not in allowlist"))

# ── 5. Inline directive checks (per occurrence, token-scoped) ────────────────
for f in tracked:
    pats, ext = patterns_for(f)
    if pats is None:
        continue
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as exc:
        violations.append((f, 0, "unreadable", f"cannot scan file: {exc}"))
        continue
    for idx, line in enumerate(lines):
        prev = lines[idx - 1] if idx > 0 else ""
        for kind, rx in pats:
            if not rx.search(line):
                continue
            if justified(kind, line, prev, ext, f):
                continue
            violations.append((f, idx + 1, kind, line.strip()[:160]))
            break  # one finding per line

# ── 6. Config-level baseline re-introduction ─────────────────────────────────
for f in tracked:
    if not is_config_file(f):
        continue
    cext = ".yml" if f.endswith((".yml", ".yaml")) else "//"
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as exc:
        violations.append((f, 0, "unreadable", f"cannot scan file: {exc}"))
        continue
    for idx, line in enumerate(lines):
        if not CONFIG_BASELINE_RE.search(line):
            continue
        if f in file_allow or reason_in_comment(line, cext):
            continue
        violations.append((f, idx + 1, "baseline-config", line.strip()[:160]))

# ── 7. Report ────────────────────────────────────────────────────────────────
if violations:
    print("✗ check-no-suppressions: unjustified suppressions / baselines found:", file=sys.stderr)
    print("", file=sys.stderr)
    for path, lineno, kind, text in violations:
        loc = f"{path}:{lineno}" if lineno else path
        print(f"  [{kind}] {loc}", file=sys.stderr)
        if lineno and text:
            print(f"      {text}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Each occurrence must be justified. Choose one:", file=sys.stderr)
    print("  • put a `reason: <why>` token in a comment on the line (or directly above it),", file=sys.stderr)
    print("  • Python: use a coded `# noqa: <CODE>` (not a bare `# noqa`),", file=sys.stderr)
    print("  • ESLint: use its native `-- <description>`,", file=sys.stderr)
    print(f"  • or allowlist the exact path in {RATIONALE} (scoped to the token kind).", file=sys.stderr)
    print("", file=sys.stderr)
    print(f"Total: {len(violations)} unjustified occurrence(s).", file=sys.stderr)
    sys.exit(1)

print("✓ check-no-suppressions: no unjustified suppressions or baselines.")
print(f"  allowlist: {len(file_allow)} artifact path(s), {len(inline_allow)} scoped source file(s)")
sys.exit(0)
PY
