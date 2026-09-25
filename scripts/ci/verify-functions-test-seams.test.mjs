#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const gate = join(scriptDir, "verify-functions-test-seams.mjs");

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

// Chain liveness passes: mod is imported only by terminal (same-package
// re-export), terminal is imported out-of-package. Dead seam fails.
{
  const root = mkdtempSync(join(tmpdir(), "openburnbar-seams-"));
  try {
    write(
      root,
      "functions-identity/src/testing.ts",
      'export * as modTesting from "./mod.js";\n' +
        'export * as terminalTesting from "./terminal.js";\n' +
        'export * as deadTesting from "./dead.js";\n',
    );
    write(root, "functions-identity/src/mod.ts", "export const x = 1;\n");
    write(root, "functions-identity/src/terminal.ts", 'export { x } from "./mod.js";\n');
    write(root, "functions-identity/src/dead.ts", "export const y = 2;\n");
    write(
      root,
      "functions/src/__tests__/t.test.ts",
      'import { x } from "../../../functions-identity/src/terminal.js";\nconsole.log(x);\n',
    );
    write(root, "functions/src/testing.ts", 'export * as stubTesting from "./stub.js";\n');
    write(root, "functions/src/stub.ts", "export const z = 3;\n");
    write(
      root,
      "functions/scripts/h.mjs",
      'import { z } from "../lib/stub.js";\nconsole.log(z);\n',
    );
    const result = runGate(root);
    if (result.status === 0) throw new Error("stale seam: expected failure");
    const output = `${result.stdout}${result.stderr}`;
    if (!output.includes("seams dead with no knip-invisible importer")) {
      throw new Error(`stale seam: wrong failure\n${output}`);
    }
    if (output.includes("seams mod ") || output.includes("seams terminal ")) {
      throw new Error(`chain-live seams must not fail\n${output}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// Production modules must not import a seam.
{
  const root = mkdtempSync(join(tmpdir(), "openburnbar-seams-"));
  try {
    write(root, "functions-identity/src/testing.ts", 'export * as modTesting from "./mod.js";\n');
    write(root, "functions-identity/src/mod.ts", "export const x = 1;\n");
    write(
      root,
      "functions/src/__tests__/t.test.ts",
      'import { x } from "../../../functions-identity/src/mod.js";\nconsole.log(x);\n',
    );
    write(
      root,
      "functions-identity/src/prod.ts",
      'import { modTesting } from "./testing.js";\nconsole.log(modTesting);\n',
    );
    write(root, "functions/src/testing.ts", 'export * as stubTesting from "./stub.js";\n');
    write(root, "functions/src/stub.ts", "export const z = 3;\n");
    write(
      root,
      "functions/scripts/h.mjs",
      'import { z } from "../lib/stub.js";\nconsole.log(z);\n',
    );
    const result = runGate(root);
    if (result.status === 0) throw new Error("prod seam import: expected failure");
    const output = `${result.stdout}${result.stderr}`;
    if (!output.includes("imports a testing seam")) {
      throw new Error(`prod seam import: wrong failure\n${output}`);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log("PASS: Functions test-seam verifier self-test.");
