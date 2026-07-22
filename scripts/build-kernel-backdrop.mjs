#!/usr/bin/env node
/**
 * Build the offline WKWebView kernel-backdrop bundle.
 *
 *   node scripts/build-kernel-backdrop.mjs
 *
 * Bundles `tools/kernel-backdrop/entry.ts` (the standalone bootstrap around
 * `apps/console/lib/gl/engine/`) into the committed minified IIFE at
 * `AgentLens/Resources/KernelBackdrop/kernel-backdrop.js`, which the macOS
 * (`KernelBackdropView`) and iOS (`MobileWebGLKernelBackdropView`) apps share
 * verbatim inside a WKWebView. Run this whenever the engine, a kernel, or the
 * bootstrap changes, and commit the regenerated bundle alongside the source.
 *
 * Uses a locally installed esbuild when one is resolvable, otherwise shells
 * out to `npx --yes esbuild@<PINNED>` (network required on first run only).
 * After building it sanity-checks the output: syntax (`node --check`), the
 * `window.__*` bridge, and that every registry kernel id is present.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ENTRY = join(ROOT, "tools/kernel-backdrop/entry.ts");
const OUTFILE = join(ROOT, "AgentLens/Resources/KernelBackdrop/kernel-backdrop.js");
const REGISTRY = join(ROOT, "apps/console/lib/gl/engine/registry.ts");
const ESBUILD_VERSION = "0.25.5"; // pinned so regenerated bundles stay reproducible

const BANNER =
  "/* GENERATED FILE — do not edit by hand." +
  " Built from tools/kernel-backdrop/entry.ts + apps/console/lib/gl/engine/." +
  " Regenerate: node scripts/build-kernel-backdrop.mjs */";

const args = [
  ENTRY,
  "--bundle",
  "--format=iife",
  "--minify",
  "--target=es2020",
  `--outfile=${OUTFILE}`,
  `--banner:js=${BANNER}`,
  "--log-level=warning",
];

/** Prefer a repo-local esbuild binary; fall back to `npx --yes esbuild@pin`. */
function runEsbuild() {
  const require = createRequire(join(ROOT, "package.json"));
  for (const base of [ROOT, join(ROOT, "apps/console")]) {
    const bin = join(base, "node_modules", ".bin", "esbuild");
    if (existsSync(bin)) {
      console.log(`[kernel-backdrop] using local esbuild: ${bin}`);
      execFileSync(bin, args, { stdio: "inherit" });
      return;
    }
  }
  try {
    // Programmatic API if esbuild is resolvable but not linked into .bin.
    const esbuildPath = require.resolve("esbuild");
    console.log(`[kernel-backdrop] using resolvable esbuild module: ${esbuildPath}`);
    execFileSync(process.execPath, [join(dirname(esbuildPath), "..", "bin", "esbuild"), ...args], {
      stdio: "inherit",
    });
    return;
  } catch {
    /* not installed locally — use npx below */
  }
  console.log(`[kernel-backdrop] using npx esbuild@${ESBUILD_VERSION}`);
  const res = spawnSync("npx", ["--yes", `esbuild@${ESBUILD_VERSION}`, ...args], {
    stdio: "inherit",
  });
  if (res.status !== 0) {
    throw new Error(`esbuild exited with status ${res.status ?? "signal"}`);
  }
}

function verify() {
  // 1. The bundle must parse as JS.
  execFileSync(process.execPath, ["--check", OUTFILE], { stdio: "inherit" });

  const bundle = readFileSync(OUTFILE, "utf8");

  // 2. The native bridge must be present.
  for (const symbol of [
    "__setKernel",
    "__setTheme",
    "__getKernel",
    "__getBackdropState",
    "__kernels",
    "__backdropReady",
  ]) {
    if (!bundle.includes(symbol)) throw new Error(`bundle is missing bridge symbol ${symbol}`);
  }

  // 3. Every kernel id in the registry must appear in the bundle.
  const registry = readFileSync(REGISTRY, "utf8");
  const ids = [...registry.matchAll(/^\s*id:\s*"([a-z0-9-]+)"/gm)].map((m) => m[1]);
  if (ids.length === 0) throw new Error("could not parse kernel ids from registry.ts");
  const missing = ids.filter((id) => !bundle.includes(`"${id}"`));
  if (missing.length > 0) throw new Error(`bundle is missing kernel ids: ${missing.join(", ")}`);

  const kb = (statSync(OUTFILE).size / 1024).toFixed(1);
  console.log(`[kernel-backdrop] OK — ${ids.length} kernels, ${kb} KB → ${OUTFILE}`);
}

runEsbuild();
verify();
