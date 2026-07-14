#!/usr/bin/env bash
# Phase-2 WS-A public-API budget (docs/CORE_DECOMPOSITION_PROGRAM.md, packet A0).
#
# The decomposition made module BOUNDARIES real; this gate makes the module
# API SURFACES real. Every first-party OpenBurnBarCore module gets a per-module
# {publicTypes, publicMembers} count and a shrink-only ratchet, so WS-A API
# curation (dead-symbol deletion + own-module internalization, see
# docs/API_CURATION_REPORT.md and plans/core-decomposition2/packets/A*.md) can
# only make progress and new code cannot silently widen a module's public API.
#
# Modes:
#   (default)  ratchet: FAIL if any module's publicTypes or publicMembers count
#              exceeds its baselined count (or its plannedCeiling, when one is
#              declared below — planned wins, mirroring
#              check-core-target-membership-budget.sh). Shrink is NON-FATAL
#              ("Improved: ... run --update") so parallel internalization
#              packets merge without a baseline race; the integrator lands
#              JSON-only ratchet-down PRs per wave.
#   --update   regenerate budgets/public-api-baseline.json from live sources.
#   --report   print a markdown classification report (per-module tables of
#              cross-module / test-only / own-module-only / dead public types,
#              via repo-wide git grep). This is the WS-A work-list generator;
#              it is NOT run in CI.
#
# MEASUREMENT HONESTY (regex classifier, house bash+node style — read before
# trusting a number):
#   - Declarations are extracted by regex from comment- and string-stripped
#     source (a real tokenizer handles nested /* */, // and "..."/"""...""",
#     so commented-out API does not count). `import` lines (incl. @_exported)
#     never match the declaration regexes.
#   - TYPES = public|open struct/class/enum/protocol/actor/typealias.
#     MEMBERS = public|open func/var/let/init/subscript (any modifier order the
#     regex knows: static/final/override/class/mutating/... and
#     private(set)-style accessor scopes).
#   - KNOWN UNDERCOUNT: members declared inside a `public extension` block
#     without an explicit `public` keyword are implicitly public but are NOT
#     counted (regex cannot track brace scope). Associated `case`s of public
#     enums are likewise not counted as members. The ratchet is still sound:
#     the same rule is applied to baseline and live, so growth in the COUNTED
#     surface always fails.
#   - KNOWN OVERCOUNT: nested public types (e.g. a public enum CodingKeys
#     inside a public struct) count as types. That is intentional — nested
#     public types are API surface too.
#   - CLASSIFICATION (--report only) greps each public TYPE name repo-wide with
#     word boundaries, excluding docs/plans/markdown. Name collisions (two
#     modules both declaring `Snapshot`) make a symbol look cross-module used
#     when only its twin is: names declared by MORE THAN ONE module, plus a
#     stoplist of ubiquitous Swift names (CodingKeys, Error, ID, ...), are
#     classified AMBIGUOUS and excluded from the dead/internalize work-lists
#     rather than risking a false "dead" verdict. Treat "dead" as "no
#     word-boundary hit outside the declaring file(s)" — an A-packet executor
#     must still confirm before deleting (string-based reflection/Codable keys
#     would not show up).
#
# The canonical budget is budgets/public-api-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/public-api-baseline.json"
mode="check"
if [[ "${1:-}" == "--update" ]]; then
  mode="update"
elif [[ "${1:-}" == "--report" ]]; then
  mode="report"
fi

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);
const sourcesRoot = path.join(repoRoot, "OpenBurnBarCore", "Sources");

// First-party modules under WS-A curation, enumerated from
// OpenBurnBarCore/Package.swift (packet A0). Deliberately EXCLUDED:
// OpenBurnBarKernel (the @_exported umbrella shim — its API is the union of
// the 4 sub-targets), the dissolving OpenBurnBarCore main target (covered by
// the membership gate; it dies, not curates), vendored C targets, FFI/
// generated targets, and the Signal/Data/Firestore/LinuxSecurity cluster
// (separate program).
const MODULES = [
  "OpenBurnBarKernelPlatform",
  "OpenBurnBarKernelModels",
  "OpenBurnBarKernelCrypto",
  "OpenBurnBarKernelContracts",
  "OpenBurnBarLogParsers",
  "OpenBurnBarQuota",
  "OpenBurnBarInsights",
  "OpenBurnBarUI",
  "OpenBurnBarHermes",
  "OpenBurnBarPretext",
  "OpenBurnBarVectorKit",
  "OpenBurnBarLaunchServices",
  "OpenBurnBarTextExpansion",
  "OpenBurnBarSQLiteReader",
  "OpenBurnBarEngine",
  "OpenBurnBarMedia",
  "OpenBurnBarComputerUseCore",
  "OpenBurnBarIrohRelay",
  "OpenBurnBarAnalytics",
];

// PLANNED ceilings (mirrors check-core-target-membership-budget.sh): a module
// that a queued packet will legitimately WIDEN gets an end-state ceiling here
// so the filling packet passes while growth past the plan still fails. A
// --update never ratchets a planned ceiling down. Empty today — WS-A only
// shrinks API; add entries with rationale when a program packet needs one.
const PLANNED_CEILINGS = {
  // "OpenBurnBarExample": { publicTypes: 10, publicMembers: 40 },
};

// Ubiquitous names whose repo-wide grep says nothing about THIS module's
// symbol (nested-type collisions). Classified AMBIGUOUS, never "dead".
const STOPLIST = new Set([
  "CodingKeys", "Error", "ID", "Kind", "Mode", "State", "Status", "Action",
  "Configuration", "Config", "Options", "Result", "Response", "Request",
  "Snapshot", "Entry", "Item", "Event", "Key", "Value", "Payload", "Context",
  "Metadata", "Info", "Body", "Row", "Record", "Delegate", "Handler",
]);

// Swift keywords that the type regex could capture as a "name" (e.g.
// `public class func` would otherwise read as a class named `func`).
const KEYWORDS = new Set([
  "func", "var", "let", "init", "subscript", "static", "final", "override",
  "class", "struct", "enum", "protocol", "actor", "typealias", "extension",
  "import", "case", "where", "some", "any", "in", "is", "as", "throws",
]);

// ── tokenizer: blank out comments (nested /* */), // lines, and string
// literals (incl. """multiline""" and #"raw"#) so regexes only see code.
// Newlines are preserved so nothing shifts.
function stripNonCode(text) {
  const out = text.split("");
  let i = 0;
  const n = text.length;
  const blank = (from, to) => {
    for (let k = from; k < to; k++) if (out[k] !== "\n") out[k] = " ";
  };
  while (i < n) {
    const c = text[i];
    if (c === "/" && text[i + 1] === "/") {
      const start = i;
      while (i < n && text[i] !== "\n") i++;
      blank(start, i);
    } else if (c === "/" && text[i + 1] === "*") {
      const start = i;
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (text[i] === "/" && text[i + 1] === "*") { depth++; i += 2; }
        else if (text[i] === "*" && text[i + 1] === "/") { depth--; i += 2; }
        else i++;
      }
      blank(start, i);
    } else if (c === "#" || c === '"') {
      // raw strings: #"..."#, ##"..."##; plain: "..." or """..."""
      let hashes = 0;
      let j = i;
      while (text[j] === "#") { hashes++; j++; }
      if (text[j] !== '"') { i++; continue; }
      const start = i;
      const triple = text.startsWith('"""', j);
      const open = (triple ? '"""' : '"');
      const close = open + "#".repeat(hashes);
      let k = j + open.length;
      while (k < n) {
        if (text[k] === "\\" && hashes === 0 && !triple) { k += 2; continue; }
        if (text.startsWith(close, k)) { k += close.length; break; }
        k++;
      }
      blank(start, k);
      i = k;
    } else {
      i++;
    }
  }
  return out.join("");
}

const MODIFIER = "(?:(?:static|final|override|mutating|nonmutating|convenience|required|lazy|weak|dynamic|class|indirect|optional|distributed|consuming|borrowing|prefix|postfix|infix|nonisolated(?:\\([^)]*\\))?|unowned(?:\\([^)]*\\))?|(?:private|internal|fileprivate|package)\\(set\\))\\s+)*";
const TYPE_RE = new RegExp(
  "(?:^|[\\s;{}()])(?:public|open)\\s+" + MODIFIER +
    "(struct|class|enum|protocol|actor|typealias)\\s+([A-Za-z_][A-Za-z0-9_]*)",
  "g"
);
const MEMBER_RE = new RegExp(
  "(?:^|[\\s;{}()])(?:public|open)\\s+" + MODIFIER +
    "(func|var|let|init|subscript)\\b",
  "g"
);

function scanModule(module) {
  const root = path.join(sourcesRoot, module);
  const decls = []; // { name, kind, file }
  let members = 0;
  if (!fs.existsSync(root)) return { decls, members };
  for (const entry of fs.readdirSync(root, { recursive: true })) {
    const rel = String(entry);
    if (!rel.endsWith(".swift")) continue;
    const abs = path.join(root, rel);
    if (!fs.statSync(abs).isFile()) continue;
    const code = stripNonCode(fs.readFileSync(abs, "utf8"));
    const fileRel = path.relative(repoRoot, abs);
    for (const m of code.matchAll(TYPE_RE)) {
      if (KEYWORDS.has(m[2])) continue;
      decls.push({ name: m[2], kind: m[1], file: fileRel });
    }
    for (const m of code.matchAll(MEMBER_RE)) {
      // `public class func`/`public class var` are members; TYPE_RE's keyword
      // guard already refused them as types. Nothing double-counts: TYPE_RE
      // requires a type keyword + name, MEMBER_RE a member keyword.
      void m;
      members++;
    }
  }
  return { decls, members };
}

const live = {};
for (const m of MODULES) {
  const s = scanModule(m);
  live[m] = { publicTypes: s.decls.length, publicMembers: s.members, decls: s.decls };
}

// ── update ─────────────────────────────────────────────────────────────────
if (mode === "update") {
  const modules = {};
  for (const m of MODULES) {
    modules[m] = {
      publicTypes: live[m].publicTypes,
      publicMembers: live[m].publicMembers,
    };
    if (PLANNED_CEILINGS[m]) {
      modules[m].plannedCeiling = { ...PLANNED_CEILINGS[m], planned: true };
    }
  }
  const baseline = {
    note:
      "Per-module public-API surface counts (publicTypes = public|open " +
      "struct/class/enum/protocol/actor/typealias; publicMembers = public|open " +
      "func/var/let/init/subscript) for the WS-A curation modules " +
      "(docs/CORE_DECOMPOSITION_PROGRAM.md, docs/API_CURATION_REPORT.md). " +
      "Shrink-only ratchet: growth past a module's count (or plannedCeiling, " +
      "which --update never ratchets down) fails CI; shrink is non-fatal (run " +
      "scripts/debt/check-public-api-budget.sh --update to ratchet down).",
    modules,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(
    `Wrote ${path.relative(repoRoot, baselinePath)}: ${MODULES.length} module(s), ` +
      `${MODULES.reduce((a, m) => a + live[m].publicTypes, 0)} public types / ` +
      `${MODULES.reduce((a, m) => a + live[m].publicMembers, 0)} public members total.`
  );
  process.exit(0);
}

// ── check (default ratchet) ────────────────────────────────────────────────
if (mode === "check") {
  if (!fs.existsSync(baselinePath)) {
    console.error(`Missing public-API baseline: ${baselinePath}`);
    console.error("Run scripts/debt/check-public-api-budget.sh --update to capture the current budget.");
    process.exit(1);
  }
  const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
  let failed = false;
  const improved = [];
  for (const m of MODULES) {
    const base = baseline.modules[m];
    if (!base) {
      // Modules added after the baseline are covered on the next --update
      // (mirrors check-core-target-membership-budget.sh's sibling handling).
      console.log(`note: ${m} has no baseline entry yet — run --update to cover it.`);
      continue;
    }
    const ceiling = base.plannedCeiling || base;
    const l = live[m];
    if (l.publicTypes > ceiling.publicTypes) {
      failed = true;
      console.error(
        `\nFAIL: ${m} public TYPE count grew (${base.publicTypes} baselined` +
          `${base.plannedCeiling ? `, planned ceiling ${ceiling.publicTypes}` : ""} -> ${l.publicTypes} live). ` +
          "New public API needs a curation rationale — prefer internal(-by-default) or land the type in the consuming module (docs/API_CURATION_REPORT.md)."
      );
    }
    if (l.publicMembers > ceiling.publicMembers) {
      failed = true;
      console.error(
        `\nFAIL: ${m} public MEMBER count grew (${base.publicMembers} baselined` +
          `${base.plannedCeiling ? `, planned ceiling ${ceiling.publicMembers}` : ""} -> ${l.publicMembers} live). ` +
          "New public API needs a curation rationale — prefer internal(-by-default) (docs/API_CURATION_REPORT.md)."
      );
    }
    if (l.publicTypes < base.publicTypes || l.publicMembers < base.publicMembers) {
      improved.push(`${m} (${base.publicTypes}t/${base.publicMembers}m -> ${l.publicTypes}t/${l.publicMembers}m)`);
    }
  }
  console.log(
    `Public-API budget: ${MODULES.length} module(s), live total ` +
      `${MODULES.reduce((a, m) => a + live[m].publicTypes, 0)} types / ` +
      `${MODULES.reduce((a, m) => a + live[m].publicMembers, 0)} members.`
  );
  if (improved.length && !failed) {
    console.log(
      "\nImproved: public API shrank — run scripts/debt/check-public-api-budget.sh --update to ratchet down:"
    );
    for (const line of improved) console.log(`  ${line}`);
  }
  if (failed) {
    console.error("\nThe canonical budget is budgets/public-api-baseline.json.");
    process.exit(1);
  }
  console.log("OK: no module widened its public API surface.");
  process.exit(0);
}

// ── report (classification) ────────────────────────────────────────────────
// Names declared by more than one module cannot be attributed by grep.
const declaringModules = new Map(); // name -> Set(module)
for (const m of MODULES) {
  for (const d of live[m].decls) {
    if (!declaringModules.has(d.name)) declaringModules.set(d.name, new Set());
    declaringModules.get(d.name).add(m);
  }
}

// Batched repo-wide word-boundary grep, attributable per name: `git grep -I -o`
// emits path:match lines, so one grep per 120-name chunk classifies everything.
// Excludes prose/planning dirs so a doc mention does not count as a code usage.
const GREP_EXCLUDES = [":!*.md", ":!docs", ":!plans", ":!droid-wiki", ":!budgets", ":!*.json"];
function grepUsagesAttributed(names) {
  const usage = new Map(names.map((n) => [n, new Set()]));
  const CHUNK = 120;
  for (let i = 0; i < names.length; i += CHUNK) {
    const chunk = names.slice(i, i + CHUNK);
    // -w -E (word-boundary on the whole match) instead of PCRE \b: works on
    // both Apple git (no PCRE) and CI git.
    const pattern = "(" + chunk.join("|") + ")";
    let out;
    try {
      out = execFileSync(
        "git",
        ["grep", "-I", "-o", "-w", "-E", "-e", pattern, "--", ".", ...GREP_EXCLUDES],
        { cwd: repoRoot, encoding: "utf8", maxBuffer: 1024 * 1024 * 256 }
      );
    } catch (e) {
      if (e.status === 1) continue;
      throw e;
    }
    for (const line of out.split("\n")) {
      if (!line) continue;
      const idx = line.lastIndexOf(":");
      if (idx < 0) continue;
      const file = line.slice(0, idx);
      const name = line.slice(idx + 1);
      const set = usage.get(name);
      if (set) set.add(file);
    }
  }
  return usage;
}

function isTestPath(p) {
  if (/(^|\/)Tests?(\/|$)/.test(p)) return true;
  if (/(^|\/)[^/]*Tests(\/|$)/.test(p)) return true;
  if (/Tests?\.swift$/.test(p)) return true;
  return false;
}

const allNames = [...declaringModules.keys()].sort();
process.stderr.write(`Classifying ${allNames.length} unique public type name(s) via git grep...\n`);
const usages = grepUsagesAttributed(allNames);

const CLASSES = ["cross-module", "test-only", "own-module-only", "dead", "ambiguous"];
const report = {};
for (const m of MODULES) {
  const perType = [];
  const seen = new Set();
  for (const d of live[m].decls) {
    if (seen.has(d.name)) continue; // one verdict per name per module
    seen.add(d.name);
    const declFiles = new Set(live[m].decls.filter((x) => x.name === d.name).map((x) => x.file));
    let cls;
    if (STOPLIST.has(d.name) || declaringModules.get(d.name).size > 1) {
      cls = "ambiguous";
    } else {
      const files = [...(usages.get(d.name) || [])];
      const ownPrefix = `OpenBurnBarCore/Sources/${m}/`;
      const external = files.filter((f) => !f.startsWith(ownPrefix));
      const externalNonTest = external.filter((f) => !isTestPath(f));
      const ownBeyondDecl = files.filter((f) => f.startsWith(ownPrefix) && !declFiles.has(f));
      if (externalNonTest.length) cls = "cross-module";
      else if (external.length) cls = "test-only";
      else if (ownBeyondDecl.length) cls = "own-module-only";
      else cls = "dead";
    }
    perType.push({ name: d.name, kind: d.kind, file: d.file, cls });
  }
  report[m] = perType;
}

// Markdown out.
const totals = Object.fromEntries(CLASSES.map((c) => [c, 0]));
let grand = 0;
console.log("# API curation report (WS-A / packet A0)");
console.log("");
console.log("Generated by `scripts/debt/check-public-api-budget.sh --report`. See that");
console.log("script's header for the measurement-honesty caveats (regex classifier,");
console.log("word-boundary grep, ambiguity handling). Classes:");
console.log("");
console.log("- **cross-module** — used outside its module by non-test code: keep public.");
console.log("- **test-only** — only external references are tests: internalize once WS-B");
console.log("  per-module `@testable` lands (**WAIT-FOR-WS-B**).");
console.log("- **own-module-only** — used only inside its own module: make `internal`.");
console.log("- **dead** — no word-boundary reference outside its declaring file(s):");
console.log("  deletion candidate (executor must re-verify — reflection/strings hide).");
console.log("- **ambiguous** — name declared by >1 module or on the stoplist; grep");
console.log("  cannot attribute it. Excluded from work-lists.");
console.log("");
console.log("| Module | public types | members | cross-module | test-only | own-module-only | dead | ambiguous |");
console.log("|---|---:|---:|---:|---:|---:|---:|---:|");
for (const m of MODULES) {
  const counts = Object.fromEntries(CLASSES.map((c) => [c, 0]));
  for (const t of report[m]) counts[t.cls]++;
  for (const c of CLASSES) totals[c] += counts[c];
  grand += report[m].length;
  console.log(
    `| ${m} | ${live[m].publicTypes} | ${live[m].publicMembers} | ${counts["cross-module"]} | ` +
      `${counts["test-only"]} | ${counts["own-module-only"]} | ${counts["dead"]} | ${counts["ambiguous"]} |`
  );
}
console.log(
  `| **Total (unique names)** | | | **${totals["cross-module"]}** | **${totals["test-only"]}** | ` +
    `**${totals["own-module-only"]}** | **${totals["dead"]}** | **${totals["ambiguous"]}** |`
);
console.log("");
const pct = (c) => ((100 * totals[c]) / Math.max(1, grand)).toFixed(1);
console.log(
  `Distribution over ${grand} classified name(s): cross-module ${pct("cross-module")}%, ` +
    `test-only ${pct("test-only")}%, own-module-only ${pct("own-module-only")}%, ` +
    `dead ${pct("dead")}%, ambiguous ${pct("ambiguous")}%.`
);
console.log("");
for (const m of MODULES) {
  const lists = {
    dead: report[m].filter((t) => t.cls === "dead"),
    "own-module-only": report[m].filter((t) => t.cls === "own-module-only"),
    "test-only": report[m].filter((t) => t.cls === "test-only"),
  };
  if (!lists.dead.length && !lists["own-module-only"].length && !lists["test-only"].length) continue;
  console.log(`## ${m}`);
  console.log("");
  for (const [label, arr] of Object.entries(lists)) {
    if (!arr.length) continue;
    const suffix = label === "test-only" ? " (WAIT-FOR-WS-B)" : "";
    console.log(`### ${label}${suffix} — ${arr.length}`);
    console.log("");
    console.log("| Type | Kind | Declared in |");
    console.log("|---|---|---|");
    for (const t of arr.sort((a, b) => a.name.localeCompare(b.name))) {
      console.log(`| \`${t.name}\` | ${t.kind} | \`${t.file}\` |`);
    }
    console.log("");
  }
}
NODE
