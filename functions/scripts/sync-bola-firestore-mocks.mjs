#!/usr/bin/env node
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

const mockBlock = `const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(bolaStore),
  };
});`;

for (const file of readdirSync(bolaDir).filter((name) => name.endsWith(".bola.test.ts"))) {
  if (skip.has(file)) continue;
  const path = resolve(bolaDir, file);
  let source = readFileSync(path, "utf8");

  if (!source.includes("pathKeyedFirestore")) {
    source = source.replace(
      /import \{([^}]+)\} from "\.\/callableBolaHarness\.js";/u,
      (match, imports) => {
        const names = imports.split(",").map((part) => part.trim()).filter(Boolean);
        if (!names.includes("pathKeyedFirestore")) names.push("pathKeyedFirestore");
        return `import { ${names.join(", ")} } from "./callableBolaHarness.js";`;
      },
    );
  }

  source = source.replace(/const bolaStore = vi\.hoisted\(\(\) => new Map\(\)\);\s*[\s\S]*?vi\.mock\("firebase-admin\/firestore"[\s\S]*?\}\)\);\s*/u, "");
  source = source.replace(
    /vi\.mock\("\.\.\/\.\.\/adminRuntime\.js",\s*\(\)\s*=>\s*\(\{[\s\S]*?\}\)\s*\);\s*/u,
    "",
  );

  const anchor = 'process.env.ENFORCE_APP_CHECK = "false";';
  if (!source.includes("pathKeyedFirestore(bolaStore)")) {
    source = source.replace(anchor, `${anchor}\n\n${mockBlock}`);
  }

  writeFileSync(path, source);
  console.log(`patched ${file}`);
}