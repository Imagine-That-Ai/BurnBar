#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const gate = join(scriptDir, "verify-functions-vendor-pins.mjs");

const runGate = (root) =>
  spawnSync(process.execPath, [gate], {
    encoding: "utf8",
    env: { ...process.env, FUNCTIONS_CI_FIXTURE_ROOT: root },
  });

const BRACE_FILES = [
  "vendor/openburnbar/brace-expansion-cjs.tgz",
  "vendor/openburnbar/brace-expansion-cjs/index.js",
  "vendor/openburnbar/brace-expansion-cjs/package.json",
  "vendor/openburnbar/brace-expansion-cjs/README.md",
];
const WASM_FILES = ["core.js", "core.wasm"];

const writeTree = (root, mutate) => {
  for (const codebase of ["functions", "functions-identity", "functions-sync", "functions-media"]) {
    for (const file of BRACE_FILES) {
      const full = join(root, codebase, file);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, `canon:${file}\n`);
    }
  }
  for (const codebase of ["functions", "functions-sync"]) {
    for (const file of WASM_FILES) {
      const full = join(root, codebase, "vendor", "openburnbar", "domain-core-wasm", file);
      mkdirSync(dirname(full), { recursive: true });
      writeFileSync(full, `canon:wasm:${file}\n`);
    }
  }
  if (mutate) mutate(root);
};

// Positive control: the real repo passes.
{
  const result = spawnSync(process.execPath, [gate], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`real repo: expected PASS\n${result.stdout}${result.stderr}`);
  }
}

// Identical fixture passes.
{
  const root = mkdtempSync(join(tmpdir(), "openburnbar-pins-"));
  try {
    writeTree(root);
    const result = runGate(root);
    if (result.status !== 0) {
      throw new Error(`identical fixture: expected PASS\n${result.stdout}${result.stderr}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// One drifted byte fails.
{
  const root = mkdtempSync(join(tmpdir(), "openburnbar-pins-"));
  try {
    writeTree(root, (r) =>
      writeFileSync(
        join(r, "functions-media", "vendor", "openburnbar", "brace-expansion-cjs.tgz"),
        "drifted\n",
      ),
    );
    const result = runGate(root);
    if (result.status === 0) throw new Error("drifted pin: expected failure");
    const output = `${result.stdout}${result.stderr}`;
    if (!output.includes("pinned blob drifted")) {
      throw new Error(`drifted pin: wrong failure\n${output}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log("PASS: Functions vendor-pin verifier self-test.");
