#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const gate = join(scriptDir, "verify-functions-codebase-isolation.mjs");

const runGate = (root) =>
  spawnSync(process.execPath, [gate], {
    encoding: "utf8",
    env: { ...process.env, FUNCTIONS_CI_FIXTURE_ROOT: root },
  });

const write = (root, rel, content) => {
  const full = join(root, rel);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, content);
};

// Positive control: the real repo passes.
{
  const result = spawnSync(process.execPath, [gate], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`real repo: expected PASS\n${result.stdout}${result.stderr}`);
  }
}

// Runtime src escaping its codebase fails; tests and harness lib/ channels pass.
{
  const root = mkdtempSync(join(tmpdir(), "openburnbar-isolation-"));
  try {
    write(root, "functions-identity/src/mod.ts", "export const x = 1;\n");
    write(
      root,
      "functions-sync/src/leak.ts",
      'import { x } from "../../../functions-identity/src/mod.js";\nconsole.log(x);\n',
    );
    write(
      root,
      "functions/src/__tests__/t.test.ts",
      'import { x } from "../../../functions-identity/src/mod.js";\nconsole.log(x);\n',
    );
    write(
      root,
      "functions/scripts/h.mjs",
      'import { x } from "../../functions-identity/lib/mod.js";\nconsole.log(x);\n',
    );
    const result = runGate(root);
    if (result.status === 0) throw new Error("src escape: expected failure");
    const output = `${result.stdout}${result.stderr}`;
    if (!output.includes("functions-sync/src/leak.ts escapes functions-sync")) {
      throw new Error(`src escape: wrong failure\n${output}`);
    }
    if (output.includes("t.test.ts") || output.includes("h.mjs")) {
      throw new Error(`sanctioned channels must not fail\n${output}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// Harnesses importing sibling sources fail.
{
  const root = mkdtempSync(join(tmpdir(), "openburnbar-isolation-"));
  try {
    write(root, "functions-identity/src/mod.ts", "export const x = 1;\n");
    write(
      root,
      "functions/scripts/h.mjs",
      'import { x } from "../../functions-identity/src/mod.js";\nconsole.log(x);\n',
    );
    const result = runGate(root);
    if (result.status === 0) throw new Error("harness src import: expected failure");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log("PASS: Functions codebase-isolation verifier self-test.");
