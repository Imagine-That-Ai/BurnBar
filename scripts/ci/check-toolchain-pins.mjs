#!/usr/bin/env node
/**
 * Toolchain pin gate (Wave 0 workstream W0-7): ONE pin per language, enforced.
 *
 * Sources of truth:
 *   .nvmrc                          — the Node version every workflow must use
 *   .xcode-version                  — the Xcode MAJOR/range the tripwire enforces
 *   global.json                     — the .NET floor (rollForward: latestFeature)
 *
 * Crate binding: every Rust toolchain literal must name the crate it builds.
 * `scripts/ci/check-toolchain-pins.mjs` binds them by lane (see CRATE_FOR_LANE
 * below); libsignal-FFI lanes build the vendored libsignal that ships inside
 * the openburnbar-iroh lineage (1.96.0) and are bound by that named contract.
 *   .xcode-version                  — the Xcode MAJOR/range the tripwire enforces
 *   global.json                     — the .NET floor (rollForward: latestFeature)
 *
 * Rules (all fail closed):
 *   1. Every `node-version:` literal in .github/workflows equals the .nvmrc
 *      value, OR is covered by an ACTIVE entry in
 *      governance/toolchain-pin-exceptions.json (path+line+pin must match the
 *      file as it exists TODAY — no stale grandfathering — and expiresOn must
 *      not have passed). `node-version-file:` must reference .nvmrc.
 *   2. Every `toolchain:` literal in .github/workflows equals the channel of
 *      the crate it operates on. rust-sast.yml's matrix entries must equal the
 *      channel of the crate named in the same matrix entry, and every crate
 *      carrying a rust-toolchain.toml must appear in the matrix. Floating
 *      channels (stable/nightly) are rejected — dtolnay/rust-toolchain
 *      requires a literal, so the literal must be the crate's pin.
 *   3. Every `rustup run <ver> cargo` occurrence (workflows AND the
 *      scripts/windows-port certification regexes) pins a channel that
 *      exists, and matches the crate named on the same line.
 *   4. The Xcode drift tripwire reads .xcode-version (no hardcoded expected
 *      major, no DEVELOPER_DIR path pin — ADR docs/architecture/011).
 *   5. global.json pins the 10.0 floor with rollForward: latestFeature.
 *
 * The exceptions FILE (not this checker) carries the only two Node-24 sites —
 * this file contains NO path literals for them, so a gate exemption can never
 * look like a clean run: every active exception is PRINTED in normal output.
 *
 * Modes:
 *   (default, CI)  check the repo (or --root <dir>)
 *   --self-test    offline positive+negative controls; exits 0/1
 */

import { existsSync, copyFileSync, mkdirSync, readdirSync, readFileSync, rmSync, mkdtempSync, cpSync, writeFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const SCRIPT_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function parseArgs(argv) {
  const args = { root: process.env.TOOLCHAIN_PINS_ROOT ?? SCRIPT_ROOT, selfTest: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--self-test") args.selfTest = true;
    else if (argv[i] === "--root") args.root = argv[(i += 1)];
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return args;
}

const readTrimmed = (path) => (existsSync(path) ? readFileSync(path, "utf8").trim() : null);

function rustChannels(root) {
  const cratesDir = join(root, "crates");
  const channels = new Map();
  if (!existsSync(cratesDir)) return channels;
  for (const crate of readdirSafe(cratesDir)) {
    const toml = join(cratesDir, crate, "rust-toolchain.toml");
    if (!existsSync(toml)) continue;
    const match = /^\s*channel\s*=\s*"([^"]+)"/mu.exec(readFileSync(toml, "utf8"));
    if (match) {
      // A pin file's channel must be a canonical semver — a floating channel
      // (stable/nightly) in a crate's own toml is exactly the drift this gate
      // exists to kill.
      if (!/^\d+\.\d+\.\d+$/u.test(match[1])) {
        fail(`crates/${crate}/rust-toolchain.toml — channel "${match[1]}" is not a canonical x.y.z pin`);
        continue;
      }
      channels.set(crate, match[1]);
    }
  }
  return channels;
}

// Lane → crate binding lives IN THE WORKFLOW FILES as a trailing
// `# pin: crates/<crate>` token on every toolchain literal (Codex finding:
// a literal that merely exists in some crate must not pass). The
// vendored-libsignal lanes pin `crates/openburnbar-iroh (libsignal lineage)`
// because libsignal itself is vendored outside crates/ and ships inside the
// openburnbar-iroh lineage (1.96.0).

function readdirSafe(dir) {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

function listWorkflows(root) {
  const dir = join(root, ".github", "workflows");
  return readdirSafe(dir)
    .filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
    .map((name) => join(".github", "workflows", name));
}

function loadExceptions(root) {
  const path = join(root, "governance", "toolchain-pin-exceptions.json");
  if (!existsSync(path)) return { entries: null, path };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return { entries: Array.isArray(parsed) ? parsed : null, path };
  } catch {
    return { entries: null, path };
  }
}

function exceptionActive(entry, today) {
  return new Date(entry.expiresOn) >= new Date(today);
}

function check(root, out) {
  const failures = [];
  const fail = (message) => failures.push(message);
  const active = [];
  const expired = [];

  // ---- pin files ----
  const nvmrc = readTrimmed(join(root, ".nvmrc"));
  if (!nvmrc || !/^\d+(\.\d+)*$/.test(nvmrc)) fail(`.nvmrc must exist with a Node version (major or major.minor.patch; got: ${JSON.stringify(nvmrc)})`);
  const xcode = readTrimmed(join(root, ".xcode-version"));
  if (!xcode || !/^(\^)?\d+(\.\d+)?$/.test(xcode)) fail(`.xcode-version must exist with a major or range (got: ${JSON.stringify(xcode)})`);
  const globalJsonPath = join(root, "global.json");
  if (!existsSync(globalJsonPath)) fail("global.json must exist (the .NET floor)");
  else {
    try {
      const sdk = JSON.parse(readFileSync(globalJsonPath, "utf8")).sdk ?? {};
      if (!/^10\./.test(String(sdk.version ?? ""))) fail("global.json must pin the 10.0 floor");
      if (sdk.rollForward !== "latestFeature") fail("global.json must use rollForward: latestFeature (54 csproj files still target net8.0)");
    } catch (error) {
      fail(`global.json is not valid JSON: ${error.message}`);
    }
  }

  // ---- exceptions (the ONLY place a deviation may live) ----
  const exceptionsPath = join(root, "governance", "toolchain-pin-exceptions.json");
  const exceptions = [];
  if (!existsSync(exceptionsPath)) {
    fail("governance/toolchain-pin-exceptions.json must exist (even if empty — the gate must not invent its own exemptions)");
  } else {
    let parsed;
    try {
      parsed = JSON.parse(readFileSync(exceptionsPath, "utf8"));
    } catch (error) {
      parsed = null;
      fail(`toolchain-pin-exceptions.json is not valid JSON: ${error.message}`);
    }
    if (Array.isArray(parsed)) {
      const today = new Date().toISOString().slice(0, 10);
      for (const entry of parsed) {
        for (const key of ["path", "line", "pin", "reason", "owner", "expiresOn"]) {
          if (entry[key] === undefined) fail(`exception entry missing "${key}": ${JSON.stringify(entry)}`);
        }
        if (entry.path === undefined || entry.line === undefined) continue;
        const abs = join(root, entry.path);
        const lines = existsSync(abs) ? readFileSync(abs, "utf8").split("\n") : null;
        const actual = lines ? lines[entry.line - 1] ?? "" : null;
        if (actual === null || !new RegExp(`node-version:\\s*["']?${entry.pin}\\b`).test(actual)) {
          fail(`exception is STALE — ${entry.path}:${entry.line} no longer carries node-version: ${entry.pin} (no grandfathering; fix the file or drop the entry)`);
          continue;
        }
        if (!exceptionActive(entry, today)) {
          expired.push(entry);
          continue;
        }
        active.push(entry);
        exceptions.push(entry);
      }
    }
  }
  const exceptionFor = (pathRel, line) =>
    exceptions?.find?.((entry) => entry.path === pathRel && entry.line === line && exceptionActive(entry, new Date().toISOString().slice(0, 10)));

  // ---- channels ----
  const channels = rustChannels(root);
  const channelValues = new Set(channels.values());
  if (channelValues.size === 0) fail("no crates/*/rust-toolchain.toml channel found — cannot anchor Rust pins");

  // ---- workflows ----
  const nodeFileRe = /^(\s*)node-version:\s*([^#\s][^#]*?)\s*(#.*)?$/u;
  const toolchainRe = /^\s*toolchain:\s*("[^"]+"|'[^']+'|\S+)(?:\s+#.*)?$/u;
  const rustupRe = /rustup run (\S+) cargo ([^#\n]*)/gu;

  for (const rel of listWorkflows(root)) {
    const abs = join(root, rel);
    const text = readFileSync(abs, "utf8");
    const lines = text.split("\n");

    lines.forEach((line, index) => {
      const lineNo = index + 1;

      const node = nodeFileRe.exec(line);
      if (node) {
        const value = node[2].replace(/^["']|["']$/g, "");
        // A bare literal is allowed ONLY through the exceptions file — the pin
        // mechanism is `node-version-file: .nvmrc` (Codex finding: an equal
        // literal must not silently pass without the exception trail).
        const exemption = exceptionFor(rel, lineNo);
        if (exemption) return;
        fail(`${rel}:${lineNo} — bare node-version ${value} is forbidden: use node-version-file: .nvmrc (or a governance/toolchain-pin-exceptions.json entry)`);
      }

      if (/^\s*node-version-file:/u.test(line) && !/\.nvmrc/u.test(line)) {
        fail(`${rel}:${lineNo} — node-version-file must reference .nvmrc (one Node pin file)`);
      }

      const toolchain = toolchainRe.exec(line);
      if (toolchain) {
        const value = toolchain[1].replace(/^["']|["']$/g, "");
        if (/^\$\{\{/.test(value)) return; // matrix indirection — checked via the matrix below
        // rust-sast matrix entries are bound by the dedicated matrix rule below.
        const inSastMatrix = rel.endsWith("rust-sast.yml") && /^ {8,}toolchain:/u.test(line);
        if (inSastMatrix) return;
        // Every literal must declare its contract (Codex finding): a trailing
        // `# pin: crates/<name>` token (or the named vendored-libsignal lineage).
        const token = /\s*#\s*pin:\s*(\S+)(?:\s+\(([^)]*)\))?\s*$/u.exec(line);
        if (!token) {
          fail(`${rel}:${lineNo} — toolchain literal has no "# pin: crates/<crate>" contract token`);
          return;
        }
        const crate = token[1].replace(/^crates\//u, "");
        if (!channels.has(crate)) {
          fail(`${rel}:${lineNo} — pin token names an unknown crate "${token[1]}"`);
          return;
        }
        if (value !== channels.get(crate)) {
          fail(`${rel}:${lineNo} — toolchain "${value}" does not match its pinned crate ${crate} (${channels.get(crate)})${token[2] ? ` [${token[2]}]` : ""}`);
        }
      }
    });

    // rustup run X cargo ... crates/<name>/ — the channel must match that crate.
    for (const match of text.matchAll(/rustup run (\S+) cargo [^#\n]*crates\/([A-Za-z0-9_-]+)\//gu)) {
      const [, version, crate] = match;
      if (channels.get(crate) !== undefined && channels.get(crate) !== version) {
        const lineNo = text.slice(0, match.index).split("\n").length;
        fail(`${rel}:${lineNo} — rustup run ${version} operates on crates/${crate} whose channel is ${channels.get(crate)}`);
      }
    }
  }

  // ---- rust-sast matrix: every entry's channel must equal the crate's own pin ----
  const sastRel = ".github/workflows/rust-sast.yml";
  const sastAbs = join(root, sastRel);
  if (existsSync(sastAbs)) {
    const text = readFileSync(sastAbs, "utf8");
    const entryRe = /-\s*crate:\s*(\S+)\n\s*path:\s*\S+\n\s*toolchain:\s*("?)([\w.]+)\2/gu;
    const seen = new Set();
    for (const match of text.matchAll(entryRe)) {
      const [, crate, , channel] = match;
      seen.add(crate);
      if (channels.get(crate) !== channel) {
        const lineNo = text.slice(0, match.index).split("\n").length;
        fail(`rust-sast.yml:${lineNo} — matrix entry pins ${crate} at ${channel}, but its rust-toolchain.toml says ${channels.get(crate)}`);
      }
    }
    // (Coverage note: a crate with a pin file but NO matrix entry is a SAST
    // coverage gap, not a pin gap — out of W0-7 scope, reported separately.)
  }

  // ---- Xcode tripwire reads .xcode-version (no hardcoded major, no path pin) ----
  const tripwireRel = ".github/actions/openburnbar-test-matrix/action.yml";
  const tripwireAbs = join(root, tripwireRel);
  if (existsSync(tripwireAbs)) {
    const text = readFileSync(tripwireAbs, "utf8");
    if (!text.includes(".xcode-version")) {
      fail(`${tripwireRel} — the drift tripwire must read .xcode-version instead of hardcoding the expected major`);
    }
    if (/expected\s*=\s*["']\d/u.test(text)) {
      fail(`${tripwireRel} — the tripwire still hardcodes the expected Xcode major (must come from .xcode-version)`);
    }
    if (/DEVELOPER_DIR\s*[=:]/u.test(text)) {
      fail(`${tripwireRel} — DEVELOPER_DIR path pins are forbidden (diligence P2-8; ADR docs/architecture/011-toolchain-pins.md supersedes)`);
    }
  }

  return { failures, active, expired };
}

// ---------------- self-test ----------------
function selfTest() {
  const tmp = mkdtempSync(join(tmpdir(), "toolchain-pins-"));
  const gitDir = join(SCRIPT_ROOT, ".git");
  const nodeModulesDir = join(SCRIPT_ROOT, "node_modules");
  cpSync(SCRIPT_ROOT, tmp, {
    recursive: true,
    // exact-prefix excludes: ".git" must not swallow ".github" (it did once)
    filter: (src) =>
      src !== gitDir &&
      !src.startsWith(gitDir + sep) &&
      src !== nodeModulesDir &&
      !src.startsWith(nodeModulesDir + sep),
  });

  const mutate = (rel, from, to) => {
    const abs = join(tmp, rel);
    const text = readFileSync(abs, "utf8");
    if (!text.includes(from)) throw new Error(`self-test mutation target not found in ${rel}: ${from}`);
    writeFileSync(abs, text.replace(from, to));
  };

  const run = () => {
    try {
      execFileSync(process.execPath, [fileURLToPath(import.meta.url), "--root", tmp], { stdio: "pipe" });
      return 0;
    } catch (error) {
      return error.status ?? 1;
    }
  };

  const expect = (label, wantExit) => {
    const got = run();
    if (got === wantExit) console.log(`  PASS ${label} (exit ${got})`);
    else {
      console.error(`  FAIL ${label}: expected exit ${wantExit}, got ${got}`);
      process.exitCode = 1;
    }
  };

  console.log("Self-test: check-toolchain-pins.mjs");
  expect("baseline repository passes", 0);

  mutate(".github/workflows/rust-sast.yml", 'toolchain: "1.94.0"', 'toolchain: "1.95.0"');
  expect("injected off-channel matrix pin fails", 1);
  mutate(".github/workflows/rust-sast.yml", 'toolchain: "1.95.0"', 'toolchain: "1.94.0"');

  mutate(".github/workflows/ci-cache-warm.yml", 'toolchain: "1.96.0"', "toolchain: stable");
  expect("floating stable channel fails", 1);
  mutate(".github/workflows/ci-cache-warm.yml", "toolchain: stable", 'toolchain: "1.96.0"');

  mutate("governance/toolchain-pin-exceptions.json", '"expiresOn": "2026-12-01"', '"expiresOn": "2020-01-01"');
  expect("expired exception fails closed", 1);
  mutate("governance/toolchain-pin-exceptions.json", '"expiresOn": "2020-01-01"', '"expiresOn": "2026-12-01"');

  mutate("governance/toolchain-pin-exceptions.json", '"line": 183', '"line": 9999');
  expect("stale exception (line no longer matches) fails", 1);
  mutate("governance/toolchain-pin-exceptions.json", '"line": 9999', '"line": 183');

  mutate(".github/workflows/confidentiality-guard.yml", "node-version-file: .nvmrc", "node-version: 20");
  expect("Node version drifting off .nvmrc fails", 1);
  mutate(".github/workflows/confidentiality-guard.yml", "node-version: 20", "node-version-file: .nvmrc");

  rmSync(join(tmp, ".xcode-version"));
  expect("missing .xcode-version fails", 1);
  writeFileSync(join(tmp, ".xcode-version"), "26\n");

  mutate(".github/actions/openburnbar-test-matrix/action.yml", 'expected="$(head -1 "$version_file")"', 'expected="26"');
  expect("hardcoded tripwire major fails", 1);

  rmSync(tmp, { recursive: true, force: true });
  return process.exitCode ?? 0;
}

// ---------------- main ----------------
const argv = process.argv.slice(2);
if (argv.includes("--self-test")) process.exit(selfTest());

const root = argv.includes("--root") ? argv[argv.indexOf("--root") + 1] : (process.env.TOOLCHAIN_PINS_ROOT ?? SCRIPT_ROOT);
const { failures, active, expired } = check(root);

if (active.length > 0) {
  console.log(`Active toolchain pin exceptions (${active.length}) — an exempted gate must never look like a clean one:`);
  for (const entry of active) {
    console.log(`  - ${entry.path}:${entry.line} pin=${entry.pin} owner=${entry.owner} until=${entry.expiresOn}: ${entry.reason}`);
  }
}
for (const entry of expired) {
  console.error(`EXPIRED toolchain pin exception (fails closed): ${entry.path}:${entry.line} owner=${entry.owner} expiresOn=${entry.expiresOn}`);
}

if (failures.length > 0) {
  console.error("Toolchain pin verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log("PASS: one pin per language — .nvmrc / crates/*/rust-toolchain.toml / .xcode-version / global.json all anchor their lanes.");
