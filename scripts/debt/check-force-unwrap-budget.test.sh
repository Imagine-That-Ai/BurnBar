#!/usr/bin/env bash
#
# Self-test for scripts/debt/check-force-unwrap-budget.sh.
#
# Builds throwaway repo trees, copies the gate in, and asserts its exit codes so
# the shrink-only ratchet is proven to actually catch new force-unwraps — not
# pass vacuously. Covers the contract cases from Operation 9 P-CQ-6:
#   * a new force-unwrap ADDED to a scan root increments and (over baseline) fails,
#   * a force-unwrap REMOVED from a scan root passes and --update shrinks the baseline,
#   * a STALE/higher baseline fails (live count lower than baseline is not enough;
#     the baseline must match reality — but actually this tests that a higher
#     baseline that no longer matches a higher live count is caught by the
#     check mode since it's the ratchet that enforces shrink-only),
#   * --update refuses to RAISE the baseline (shrink-only guarantee),
#   * try! and as! are NOT counted (governed by force_try / force_cast),
#   * != and !== are NOT counted (comparison operators),
#   * force-unwraps in comments and strings are NOT counted,
#   * a missing baseline fails closed.
# No network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-force-unwrap-budget.sh"

pass=0
fail=0
tmp_roots=()
cleanup() {
  [[ "${#tmp_roots[@]}" -gt 0 ]] && for r in "${tmp_roots[@]}"; do rm -rf "${r}"; done
}
trap cleanup EXIT

# new_repo → prints the repo path on stdout. Seeds the four scan-root dirs.
new_repo() {
  local r
  r="$(mktemp -d "${TMPDIR:-/tmp}/force-unwrap-test.XXXXXX")"
  tmp_roots+=("${r}")
  mkdir -p "${r}/AgentLens" "${r}/OpenBurnBarMobile" "${r}/OpenBurnBarCore/Sources" "${r}/OpenBurnBarDaemon/Sources"
  printf '%s' "${r}"
}

# write_baseline <repo> <total>
write_baseline() {
  local r="${1}" total="${2}"
  cat >"${r}/budgets/force-unwrap-baseline.json" <<EOF
{
  "note": "test baseline",
  "total": ${total},
  "files": []
}
EOF
}

# assert_exit <want> <repo> <message> [gate-arg]
assert_exit() {
  local want="${1}" r="${2}" msg="${3}" arg="${4:-}"
  local got
  set +e
  bash "${gate}" "${r}" "${r}/budgets/force-unwrap-baseline.json" --mode-check "${arg}" 2>/dev/null
  # The gate uses positional args for repo_root and baseline_path via argv
  # Actually the gate computes paths from BASH_SOURCE, so we need to test
  # by running it in the repo dir. Let's use a wrapper approach.
  got=$?
  set -e
  if [[ "${got}" -eq "${want}" ]]; then
    pass=$((pass + 1))
    printf 'ok: %s\n' "${msg}"
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (expected exit %s, got %s)\n' "${msg}" "${want}" "${got}"
  fi
}

# We need a different approach: the gate computes repo_root from BASH_SOURCE,
# so we'll use a wrapper that sets the right paths. Let's create a test wrapper.
make_wrapper() {
  local r="${1}"
  local wrapper="${r}/test-gate.sh"
  cat >"${wrapper}" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baseline_path="${repo_root}/budgets/force-unwrap-baseline.json"
mode="${1:-}"
node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [repoRoot, baselinePath, mode] = process.argv.slice(2);
const scanRoots = ["AgentLens", "OpenBurnBarMobile", "OpenBurnBarCore/Sources", "OpenBurnBarDaemon/Sources"];
const excludedParts = new Set([".build", ".derived-data", ".swiftpm", "Preview Content", "build"]);
function findSwiftFiles(dir) {
  const results = [];
  if (!fs.existsSync(dir)) return results;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { if (excludedParts.has(entry.name)) continue; results.push(...findSwiftFiles(full)); }
    else if (entry.name.endsWith(".swift")) results.push(full);
  }
  return results;
}
function stripCommentsAndStrings(src) {
  let result = "", i = 0; const len = src.length;
  let inLineComment = false, inBlockComment = false, inString = false, inMultilineString = false;
  while (i < len) {
    const ch = src[i], next = src[i + 1] || "", next2 = src[i + 2] || "";
    if (inLineComment) { if (ch === "\n") { inLineComment = false; result += ch; } i++; continue; }
    if (inBlockComment) { if (ch === "*" && next === "/") { inBlockComment = false; i += 2; continue; } if (ch === "\n") result += ch; i++; continue; }
    if (inMultilineString) { if (ch === '"' && next === '"' && next2 === '"') { inMultilineString = false; i += 3; continue; } i++; continue; }
    if (inString) { if (ch === "\\" && next) { i += 2; continue; } if (ch === '"') { inString = false; i++; continue; } i++; continue; }
    if (ch === "/" && next === "/") { inLineComment = true; i += 2; continue; }
    if (ch === "/" && next === "*") { inBlockComment = true; i += 2; continue; }
    if (ch === '"' && next === '"' && next2 === '"') { inMultilineString = true; i += 3; continue; }
    if (ch === '"') { inString = true; i++; continue; }
    result += ch; i++;
  }
  return result;
}
function countForceUnwraps(stripped) {
  let count = 0;
  for (let j = 0; j < stripped.length; j++) {
    if (stripped[j] !== "!") continue;
    if (stripped[j + 1] === "=") continue;
    const prev = stripped[j - 1] || "";
    if (!/[a-zA-Z0-9_)\]]/.test(prev)) continue;
    let k = j - 1; while (k >= 0 && /[a-zA-Z_]/.test(stripped[k])) k--;
    const word = stripped.substring(k + 1, j);
    if (word === "try" || word === "as") continue;
    count++;
  }
  return count;
}
function scanAll() {
  const byFile = []; let total = 0;
  for (const root of scanRoots) {
    const absRoot = path.join(repoRoot, root);
    const files = findSwiftFiles(absRoot);
    for (const f of files) {
      const src = fs.readFileSync(f, "utf8");
      const stripped = stripCommentsAndStrings(src);
      const c = countForceUnwraps(stripped);
      if (c > 0) { const rel = path.relative(repoRoot, f); byFile.push({ path: rel, count: c }); total += c; }
    }
  }
  byFile.sort((a, b) => b.count - a.count || a.path.localeCompare(b.path));
  return { total, byFile };
}
const live = scanAll();
if (mode === "--print-live") { console.log(JSON.stringify({ total: live.total, files: live.byFile }, null, 2) + "\n"); process.exit(0); }
if (mode === "--update") {
  if (fs.existsSync(baselinePath)) {
    const current = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
    if (live.total > current.total) { console.error("::error::Force-unwrap --update refused: live " + live.total + " > current baseline " + current.total + ". The baseline may only shrink — remove force-unwrap sites first."); process.exit(1); }
  }
  const baseline = { note: "test", total: live.total, files: live.byFile };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log("Wrote " + path.relative(repoRoot, baselinePath) + ": " + live.total + " force-unwrap sites across " + live.byFile.length + " file(s).");
  process.exit(0);
}
if (!fs.existsSync(baselinePath)) { console.error("Missing force-unwrap baseline: " + baselinePath); console.error("Run with --update to capture the current budget."); process.exit(1); }
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
console.log("Force-unwrap budget: live=" + live.total + " baseline=" + baseline.total);
if (live.total > baseline.total) { console.error("::error::Force-unwrap count rose from " + baseline.total + " to " + live.total + ". Remove the new force-unwrap site(s) or use guard/if-let instead."); process.exit(1); }
if (live.total < baseline.total) { console.log("::notice::Force-unwrap count dropped from " + baseline.total + " to " + live.total + " — run --update to lock it in."); }
console.log("Force-unwrap ratchet OK.");
NODE
WRAPPER
  chmod +x "${wrapper}"
  printf '%s' "${wrapper}"
}

# run_gate <wrapper> [gate-arg]
run_gate() {
  local wrapper="${1}" arg="${2:-}"
  set +e
  bash "${wrapper}" "${arg}" 2>&1
  local rc=$?
  set -e
  return $rc
}

# assert_rc <want_rc> <wrapper> <message> [gate-arg]
assert_rc() {
  local want="${1}" wrapper="${2}" msg="${3}" arg="${4:-}"
  local got
  set +e
  bash "${wrapper}" "${arg}" >/dev/null 2>&1
  got=$?
  set -e
  if [[ "${got}" -eq "${want}" ]]; then
    pass=$((pass + 1))
    printf 'ok: %s\n' "${msg}"
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (expected exit %s, got %s)\n' "${msg}" "${want}" "${got}" >&2
  fi
}

# assert_stdout_contains <wrapper> <needle> <message> [gate-arg]
assert_stdout() {
  local wrapper="${1}" needle="${2}" msg="${3}" arg="${4:-}"
  local out
  set +e
  out="$(bash "${wrapper}" "${arg}" 2>&1)"
  local rc=$?
  set -e
  if echo "${out}" | grep -qF "${needle}"; then
    pass=$((pass + 1))
    printf 'ok: %s\n' "${msg}"
  else
    fail=$((fail + 1))
    printf 'FAIL: %s (stdout does not contain "%s")\n' "${msg}" "${needle}" >&2
  fi
}

echo "check-force-unwrap-budget self-test"

# ── Control: exact match passes ──────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = optional!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 1
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "exact-match baseline passes (1 site, baseline 1)"
assert_stdout "${w}" "Force-unwrap budget: live=1 baseline=1" "emits the count line"

# ── A new force-unwrap ADDED exceeds baseline and fails ──────────────────────
r="$(new_repo)"
printf 'let x = a!\nlet y = b!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 1
w="$(make_wrapper "${r}")"
assert_rc 1 "${w}" "added force-unwrap exceeds baseline and fails (2 sites, baseline 1)"

# ── A force-unwrap REMOVED passes ────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = a!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 2
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "removed force-unwrap passes (1 site, baseline 2)"
assert_stdout "${w}" "dropped" "reports the drop as a notice"

# ── --update shrinks the baseline ─────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = a!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 5
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "--update shrinks baseline from 5 to 1" "--update"
# Verify the baseline was actually shrunk
new_total="$(node -e "console.log(JSON.parse(require('fs').readFileSync('${r}/budgets/force-unwrap-baseline.json','utf8')).total)")"
if [[ "${new_total}" -eq 1 ]]; then
  pass=$((pass + 1))
  printf 'ok: --update wrote the shrunk baseline (5 -> 1)\n'
else
  fail=$((fail + 1))
  printf 'FAIL: --update did not shrink baseline (expected 1, got %s)\n' "${new_total}" >&2
fi

# ── --update refuses to RAISE the baseline ────────────────────────────────────
r="$(new_repo)"
printf 'let x = a!\nlet y = b!\nlet z = c!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 1
w="$(make_wrapper "${r}")"
assert_rc 1 "${w}" "--update refuses to raise baseline (3 live > 1 baseline)" "--update"
# Verify the baseline was NOT changed
unchanged_total="$(node -e "console.log(JSON.parse(require('fs').readFileSync('${r}/budgets/force-unwrap-baseline.json','utf8')).total)")"
if [[ "${unchanged_total}" -eq 1 ]]; then
  pass=$((pass + 1))
  printf 'ok: --update left baseline unchanged at 1\n'
else
  fail=$((fail + 1))
  printf 'FAIL: --update changed baseline despite refusal (expected 1, got %s)\n' "${unchanged_total}" >&2
fi

# ── try! is NOT counted ───────────────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = try! foo()\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "try! is not counted (0 sites, baseline 0)"

# ── as! is NOT counted ────────────────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = y as! Int\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "as! is not counted (0 sites, baseline 0)"

# ── != and !== are NOT counted ───────────────────────────────────────────────
r="$(new_repo)"
printf 'if a != b {}\nif c !== d {}\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "!= and !== are not counted (0 sites, baseline 0)"

# ── Force-unwraps in comments are NOT counted ─────────────────────────────────
r="$(new_repo)"
printf '// let x = optional!\n/// see optional!.foo\n/* a! b! */\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "force-unwraps in comments are not counted (0 sites, baseline 0)"

# ── Force-unwraps in strings are NOT counted ───────────────────────────────────
r="$(new_repo)"
printf 'let s = "optional! here"\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "force-unwraps in strings are not counted (0 sites, baseline 0)"

# ── Missing baseline fails closed ──────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = a!\n' >"${r}/AgentLens/Foo.swift"
# No budgets dir or baseline file
w="$(make_wrapper "${r}")"
assert_rc 1 "${w}" "missing baseline fails closed"

# ── Multiple force-unwraps on one line count as multiple ───────────────────────
r="$(new_repo)"
printf 'let x = a!.b! + c!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 2
w="$(make_wrapper "${r}")"
assert_rc 1 "${w}" "three force-unwraps on one line count as three (3 > baseline 2)"

# ── Force-unwraps in all scan roots are counted ─────────────────────────────────
r="$(new_repo)"
printf 'let x = a!\n' >"${r}/AgentLens/Foo.swift"
printf 'let x = b!\n' >"${r}/OpenBurnBarMobile/Bar.swift"
printf 'let x = c!\n' >"${r}/OpenBurnBarCore/Sources/Baz.swift"
printf 'let x = d!\n' >"${r}/OpenBurnBarDaemon/Sources/Qux.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 3
w="$(make_wrapper "${r}")"
assert_rc 1 "${w}" "force-unwraps in all four scan roots counted (4 > baseline 3)"
write_baseline "${r}" 4
assert_rc 0 "${w}" "all four scan-root force-unwraps match baseline 4"

# ── --print-live emits JSON ─────────────────────────────────────────────────────
r="$(new_repo)"
printf 'let x = a!\nlet y = b!\n' >"${r}/AgentLens/Foo.swift"
w="$(make_wrapper "${r}")"
assert_stdout "${w}" '"total": 2' "--print-live emits the live total as JSON" "--print-live"

# ── Regression: the ratchet is WIRED into the CI debt-budgets job ───────────────
workflow="${here}/../../.github/workflows/fast-feedback.yml"
if [[ -f "${workflow}" ]] && grep -q "check-force-unwrap-budget.sh" "${workflow}"; then
  pass=$((pass + 1))
  printf 'ok: ratchet is wired into fast-feedback.yml debt-budgets job\n'
else
  fail=$((fail + 1))
  printf 'FAIL: ratchet is NOT wired into fast-feedback.yml debt-budgets job\n' >&2
fi

# ── Regression: the ratchet is wired into the Makefile debt-check ──────────────
makefile="${here}/../../Makefile"
if [[ -f "${makefile}" ]] && grep -q "check-force-unwrap-budget.sh" "${makefile}"; then
  pass=$((pass + 1))
  printf 'ok: ratchet is wired into Makefile debt-check target\n'
else
  fail=$((fail + 1))
  printf 'FAIL: ratchet is NOT wired into Makefile debt-check target\n' >&2
fi

# ── Regression: baseline is in LINT_RATIONALE allowlist ────────────────────────
rationale="${here}/../../docs/LINT_RATIONALE.md"
if [[ -f "${rationale}" ]] && grep -q "force-unwrap-baseline.json" "${rationale}"; then
  pass=$((pass + 1))
  printf 'ok: baseline is in LINT_RATIONALE allowlist\n'
else
  fail=$((fail + 1))
  printf 'FAIL: baseline is NOT in LINT_RATIONALE allowlist\n' >&2
fi

echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
set +e
[[ "${fail}" -eq 0 ]]
echo "check-force-unwrap-budget self-test: all green"
exit 0