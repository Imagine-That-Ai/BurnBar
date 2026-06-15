#!/usr/bin/env node
/**
 * Normalize generated BOLA scaffolds to use bolaCrossUserData() from the harness.
 */
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const bolaDir = resolve(import.meta.dirname, "../src/__tests__/bola");
const skip = new Set([
  "callableBolaHarness.ts",
  "authOnly.bola.test.ts",
  "credentialTransfer.bola.test.ts",
  "openTimestamps.bola.test.ts",
  "voipPush.bola.test.ts",
  "hermesGateway.bola.test.ts",
]);

const payloadCall = "bolaCrossUserData()";
const oldPayload =
  /callableRequest\(ALICE_UID,\s*\{[\s\S]*?\}\)/gu;

for (const file of readdirSync(bolaDir).filter((name) => name.endsWith(".bola.test.ts"))) {
  if (skip.has(file)) continue;
  const path = resolve(bolaDir, file);
  let source = readFileSync(path, "utf8");
  if (!source.includes("callableRequest(ALICE_UID")) continue;
  if (!source.includes("bolaCrossUserData")) {
    source = source.replace(
      /from "\.\/callableBolaHarness\.js";/u,
      'from "./callableBolaHarness.js";',
    );
    source = source.replace(
      /import \{([^}]+)\} from "\.\/callableBolaHarness\.js";/u,
      (match, imports) => {
        const names = imports.split(",").map((part) => part.trim());
        if (!names.includes("bolaCrossUserData")) {
          names.push("bolaCrossUserData");
        }
        return `import { ${names.join(", ")} } from "./callableBolaHarness.js";`;
      },
    );
  }
  source = source.replace(oldPayload, `callableRequest(ALICE_UID, bolaCrossUserData())`);
  writeFileSync(path, source);
  console.log(`updated ${file}`);
}