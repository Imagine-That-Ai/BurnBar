#!/usr/bin/env node
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const bolaDir = resolve(import.meta.dirname, "../src/__tests__/bola");
const skip = new Set(["callableBolaHarness.ts", "bolaSetup.ts", "authOnly.bola.test.ts", "voipPush.bola.test.ts"]);

for (const file of readdirSync(bolaDir).filter((name) => name.endsWith(".bola.test.ts"))) {
  if (skip.has(file)) continue;
  const path = resolve(bolaDir, file);
  let source = readFileSync(path, "utf8");
  if (source.includes('import "./bolaSetup.js"')) continue;

  source = source.replace(
    /\/\*\*[\s\S]*?\*\/\s*/u,
    (comment) => `${comment}import "./bolaSetup.js";\n`,
  );

  // Remove per-file adminRuntime mock now centralized in bolaSetup.
  source = source.replace(/const bolaStore = vi\.hoisted\(\(\) => new Map\(\)\);\s*/u, "");
  source = source.replace(
    /vi\.mock\("\.\.\/\.\.\/adminRuntime\.js",\s*\(\)\s*=>\s*\(\{\s*db:\s*pathKeyedFirestore\(bolaStore\)\s*\}\)\s*\);\s*/u,
    "",
  );
  source = source.replace(/\s*,\s*pathKeyedFirestore/gu, "");
  source = source.replace(/pathKeyedFirestore,\s*/gu, "");

  writeFileSync(path, source);
  console.log(`setup import ${file}`);
}