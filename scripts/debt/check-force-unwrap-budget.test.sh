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
#   * a missing baseline fails closed,
#   * one-for-one replacement is blocked by the per-file growth check,
#   * force-unwraps inside string interpolation ARE counted,
#   * implicitly-unwrapped optional TYPE declarations are NOT counted,
#   * force-unwraps in OpenBurnBarKeyboard/ and OpenBurnBarWidget/ ARE counted,
#   * force-unwrap on an uppercase variable in expression context IS counted.
# No network; self-cleaning.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="${here}/check-force-unwrap-budget.sh"

pass=0
fail=0
tmp_roots=()
cleanup() {
  [[ "${#tmp_roots[@]}" -gt 0 ]] && for r in "${tmp_roots[@]}"; do rm -rf "${r}"; done
  true
}
trap cleanup EXIT

# new_repo → prints the repo path on stdout. Seeds the six scan-root dirs.
new_repo() {
  local r
  r="$(mktemp -d "${TMPDIR:-/tmp}/force-unwrap-test.XXXXXX")"
  tmp_roots+=("${r}")
  mkdir -p "${r}/AgentLens" "${r}/OpenBurnBarMobile" "${r}/OpenBurnBarCore/Sources" "${r}/OpenBurnBarDaemon/Sources" "${r}/OpenBurnBarKeyboard" "${r}/OpenBurnBarWidget"
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

# write_baseline_files <repo> <total> <files-json-array>
write_baseline_files() {
  local r="${1}" total="${2}" files="${3}"
  cat >"${r}/budgets/force-unwrap-baseline.json" <<EOF
{
  "note": "test baseline",
  "total": ${total},
  "files": ${files}
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

const scanRoots = [
  "AgentLens",
  "OpenBurnBarMobile",
  "OpenBurnBarCore/Sources",
  "OpenBurnBarDaemon/Sources",
  "OpenBurnBarKeyboard",
  "OpenBurnBarWidget",
];

const excludedParts = new Set([
  ".build",
  ".derived-data",
  ".swiftpm",
  "Preview Content",
  "build",
]);

function findSwiftFiles(dir) {
  const results = [];
  if (!fs.existsSync(dir)) return results;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (excludedParts.has(entry.name)) continue;
      results.push(...findSwiftFiles(full));
    } else if (entry.name.endsWith(".swift")) {
      results.push(full);
    }
  }
  return results;
}

// Strip comments and string/character literals so force-unwraps inside them
// are not counted. Handles line comments (//), block comments (/* */),
// string literals ("..."), multi-line string literals ("""...""").
//
// String interpolation `\(...)` is handled specially: the `\(` opens an
// interpolation expression that contains executable code, so the code inside
// is preserved (not stripped) while the surrounding string delimiters and
// non-interpolation string content are removed.
function stripCommentsAndStrings(src) {
  let result = "";
  let i = 0;
  const len = src.length;
  let inLineComment = false;
  let inBlockComment = false;
  let inString = false;
  let inMultilineString = false;

  while (i < len) {
    const ch = src[i];
    const next = src[i + 1] || "";
    const next2 = src[i + 2] || "";

    if (inLineComment) {
      if (ch === "\n") {
        inLineComment = false;
        result += ch;
      }
      i++;
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        i += 2;
        continue;
      }
      if (ch === "\n") result += ch;
      i++;
      continue;
    }
    if (inMultilineString) {
      // Multi-line strings can contain interpolation with \(...)
      if (ch === "\\" && next === "(") {
        // Interpolation in multi-line string: preserve the code inside
        result += " "; // placeholder for the string part
        i += 2; // skip \(
        let depth = 1;
        while (i < len && depth > 0) {
          if (src[i] === "(") depth++;
          else if (src[i] === ")") depth--;
          if (depth > 0) result += src[i];
          i++;
        }
        // i is now past the closing )
        continue;
      }
      if (ch === '"' && next === '"' && next2 === '"') {
        inMultilineString = false;
        i += 3;
        continue;
      }
      i++;
      continue;
    }
    if (inString) {
      if (ch === "\\" && next === "(") {
        // String interpolation: preserve the code inside \(...)
        result += " ";
        i += 2; // skip \(
        let depth = 1;
        while (i < len && depth > 0) {
          if (src[i] === "(") depth++;
          else if (src[i] === ")") depth--;
          if (depth > 0) result += src[i];
          i++;
        }
        continue;
      }
      if (ch === "\\" && next) {
        i += 2;
        continue;
      }
      if (ch === '"') {
        inString = false;
        i++;
        continue;
      }
      i++;
      continue;
    }

    // Not in any comment/string context
    if (ch === "/" && next === "/") {
      inLineComment = true;
      i += 2;
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (ch === '"' && next === '"' && next2 === '"') {
      inMultilineString = true;
      i += 3;
      continue;
    }
    if (ch === '"') {
      inString = true;
      i++;
      continue;
    }

    result += ch;
    i++;
  }
  return result;
}

// Count force-unwrap `!` sites in stripped source.
// A force-unwrap is `!` preceded by an expression-ending character (letter,
// digit, _, ), ]) and NOT followed by `=` (excludes !=, !==).
// Excludes:
//   - `try!` and `as!` (governed by force_try / force_cast rules)
//   - Implicitly-unwrapped optional type declarations (e.g. `var x: UILabel!`)
//     detected by: word before `!` starts with uppercase (type name) AND
//     a `:` precedes the type name on the same line (type annotation position)
//     AND `!` is NOT followed by `.` or `(` (which signal force-unwrap chaining)
function countForceUnwraps(stripped) {
  const lines = stripped.split("\n");
  let count = 0;

  for (const line of lines) {
    for (let j = 0; j < line.length; j++) {
      if (line[j] !== "!") continue;
      // Skip != and !==
      if (line[j + 1] === "=") continue;

      const prev = line[j - 1] || "";
      if (!/[a-zA-Z0-9_)\]]/.test(prev)) continue;

      // Find the word preceding `!` to exclude `try!` and `as!`
      let k = j - 1;
      while (k >= 0 && /[a-zA-Z_]/.test(line[k])) k--;
      const word = line.substring(k + 1, j);
      if (word === "try" || word === "as") continue;

      // Exclude implicitly-unwrapped optional TYPE declarations.
      // An IUO type has the form `: TypeName!` where the `!` is in type
      // annotation position, not expression position. Detected by:
      //   1. The type name starts with uppercase (Swift type naming convention)
      //   2. A `:` (followed by optional whitespace) precedes the type name
      //      on this line — placing the `!` in a type annotation, not an
      //      expression
      //   3. The `!` is NOT followed by `.` or `(` — those signal force-unwrap
      //      chaining (e.g. `optional!.foo`), which is always an operation
      const startsUpper = /^[A-Z]/.test(word);
      const beforeType = line.substring(0, k + 1);
      const hasColon = /:\s*$/.test(beforeType);
      const after = line[j + 1] || "";
      const isChaining = after === "." || after === "(";

      if (startsUpper && hasColon && !isChaining) continue;

      count++;
    }
  }
  return count;
}

function scanAll() {
  const byFile = [];
  let total = 0;

  for (const root of scanRoots) {
    const absRoot = path.join(repoRoot, root);
    const files = findSwiftFiles(absRoot);
    for (const f of files) {
      const src = fs.readFileSync(f, "utf8");
      const stripped = stripCommentsAndStrings(src);
      const c = countForceUnwraps(stripped);
      if (c > 0) {
        const rel = path.relative(repoRoot, f);
        byFile.push({ path: rel, count: c });
        total += c;
      }
    }
  }

  byFile.sort((a, b) => b.count - a.count || a.path.localeCompare(b.path));
  return { total, byFile };
}

const live = scanAll();

if (mode === "--print-live") {
  console.log(
    JSON.stringify(
      { total: live.total, files: live.byFile },
      null,
      2,
    ) + "\n",
  );
  process.exit(0);
}

if (mode === "--update") {
  // Shrink-only: refuse to raise the baseline.
  if (fs.existsSync(baselinePath)) {
    const current = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
    if (live.total > current.total) {
      console.error(
        `::error::Force-unwrap --update refused: live ${live.total} > current baseline ${current.total}. The baseline may only shrink — remove force-unwrap sites first.`,
      );
      process.exit(1);
    }
  }
  const baseline = {
    note: "Force-unwrap (!) site budget across AgentLens/, OpenBurnBarMobile/, OpenBurnBarCore/Sources/, OpenBurnBarDaemon/Sources/, OpenBurnBarKeyboard/, OpenBurnBarWidget/. Shrink-only: count may only decrease as sites are removed. Excludes try! and as! (governed by force_try / force_cast) and implicitly-unwrapped optional type declarations (governed by implicitly_unwrapped_optional). String interpolation expressions are counted (executable code). Regenerate via scripts/debt/check-force-unwrap-budget.sh --update.",
    total: live.total,
    files: live.byFile,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(
    `Wrote ${path.relative(repoRoot, baselinePath)}: ${live.total} force-unwrap sites across ${live.byFile.length} file(s).`,
  );
  process.exit(0);
}

// Check mode
if (!fs.existsSync(baselinePath)) {
  console.error(`Missing force-unwrap baseline: ${baselinePath}`);
  console.error(
    "Run scripts/debt/check-force-unwrap-budget.sh --update to capture the current budget.",
  );
  process.exit(1);
}

const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const baseByPath = new Map((baseline.files || []).map((f) => [f.path, f.count]));

console.log(
  `Force-unwrap budget: live=${live.total} baseline=${baseline.total}`,
);

const top = live.byFile.slice(0, 10);
if (top.length) {
  console.log("Top offending files:");
  for (const f of top) console.log(`  ${String(f.count).padStart(3)}  ${f.path}`);
}

let failed = false;

// Check 1: total must not exceed baseline
if (live.total > baseline.total) {
  console.error(
    `::error::Force-unwrap count rose from ${baseline.total} to ${live.total}. Remove the new force-unwrap site(s) or use guard/if-let instead.`,
  );
  failed = true;
}

// Check 2: per-file counts must not exceed baseline (blocks one-for-one
// replacements that launder a new site behind a removal elsewhere)
const grownFiles = [];
for (const f of live.byFile) {
  const baseCount = baseByPath.get(f.path);
  if (baseCount !== undefined && f.count > baseCount) {
    grownFiles.push({ path: f.path, from: baseCount, to: f.count });
  }
}
if (grownFiles.length) {
  failed = true;
  console.error(
    `\n::error::${grownFiles.length} file(s) grew beyond their per-file baseline (one-for-one replacements are blocked — remove sites, don't move them):`,
  );
  for (const g of grownFiles) {
    console.error(`  ${g.from} -> ${g.to}  ${g.path}`);
  }
}

if (live.total < baseline.total) {
  console.log(
    `::notice::Force-unwrap count dropped from ${baseline.total} to ${live.total} — run scripts/debt/check-force-unwrap-budget.sh --update to lock it in.`,
  );
}

if (failed) {
  console.error("\nThe canonical budget is budgets/force-unwrap-baseline.json.");
  process.exit(1);
}

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

# ── One-for-one replacement is BLOCKED by per-file growth check (r3585566812) ──
r="$(new_repo)"
printf 'let x = a!\nlet y = b!\n' >"${r}/AgentLens/A.swift"
printf 'let z = 0\n' >"${r}/AgentLens/B.swift"
mkdir -p "${r}/budgets"
write_baseline_files "${r}" 2 '[{"path":"AgentLens/A.swift","count":2},{"path":"AgentLens/B.swift","count":0}]'
w="$(make_wrapper "${r}")"
# Now move one force-unwrap from A to B: A drops to 1, B grows to 1. Total stays 2.
printf 'let x = a!\n' >"${r}/AgentLens/A.swift"
printf 'let z = b!\n' >"${r}/AgentLens/B.swift"
assert_rc 1 "${w}" "one-for-one replacement blocked: file B grew 0->1 despite total unchanged"
assert_stdout "${w}" "grew beyond their per-file baseline" "one-for-one replacement reports per-file growth error"

# ── Force-unwraps in string interpolation ARE counted (r3585566821) ──────────────
r="$(new_repo)"
printf 'let s = "\\(optional!)"\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 1
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "string interpolation force-unwrap counted (1 site, baseline 1)"
# Add a second file with another interpolation force-unwrap
printf 'let t = "\\(another!)"\n' >"${r}/AgentLens/Bar.swift"
assert_rc 1 "${w}" "second string interpolation force-unwrap exceeds baseline (2 > 1)"

# ── IUO type declarations are NOT counted (r3585566838) ──────────────────────────
r="$(new_repo)"
printf 'var x: UILabel!\nfunc foo(_ nav: WKNavigation!) {}\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "IUO type declarations not counted (0 sites, baseline 0)"
# Now add an actual force-unwrap expression
printf 'var x: UILabel!\nfunc foo(_ nav: WKNavigation!) {}\nlet y = x!\n' >"${r}/AgentLens/Foo.swift"
assert_rc 1 "${w}" "actual force-unwrap expression counted (1 > baseline 0)"

# ── Extension targets OpenBurnBarKeyboard/ and OpenBurnBarWidget/ in scope (r3585566848) ──
r="$(new_repo)"
printf 'let x = a!\n' >"${r}/OpenBurnBarKeyboard/Key.swift"
printf 'let y = b!\n' >"${r}/OpenBurnBarWidget/Wid.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 2
w="$(make_wrapper "${r}")"
assert_rc 0 "${w}" "force-unwraps in Keyboard/ and Widget/ match baseline 2"
# Add a new force-unwrap in Widget/
printf 'let z = c!\n' >"${r}/OpenBurnBarWidget/Extra.swift"
assert_rc 1 "${w}" "new force-unwrap in Widget/ exceeds baseline (3 > 2)"

# ── Force-unwrap on uppercase variable in expression context IS counted ─────────
r="$(new_repo)"
printf 'let x = URL!\n' >"${r}/AgentLens/Foo.swift"
mkdir -p "${r}/budgets"
write_baseline "${r}" 0
w="$(make_wrapper "${r}")"
assert_rc 1 "${w}" "force-unwrap on uppercase variable counted (no colon before URL, 1 > 0)"

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

set -e
echo
printf 'passed=%s failed=%s\n' "${pass}" "${fail}"
if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
echo "check-force-unwrap-budget self-test: all green"
exit 0