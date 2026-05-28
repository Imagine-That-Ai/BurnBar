#!/usr/bin/env node
/**
 * Guardrail: hand-maintained functions/src/types/legacy.ts must stay aligned with
 * schema-sync generated provider-account contracts.
 */

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");

function extractInterfaceFields(source, interfaceName) {
  const pattern = new RegExp(
    `(?:export )?interface ${interfaceName}\\s*\\{([\\s\\S]*?)\\n\\}`,
    "m"
  );
  const match = source.match(pattern);
  if (!match) {
    throw new Error(`Could not parse interface ${interfaceName}`);
  }
  return new Set([...match[1].matchAll(/^\s*(\w+)\??:/gm)].map((m) => m[1]));
}

const generated = readFileSync(
  join(repoRoot, "functions/src/types/generated/provider-account.ts"),
  "utf8"
);
const handMaintained = readFileSync(
  join(repoRoot, "functions/src/types/legacy.ts"),
  "utf8"
);

const generatedDoc = extractInterfaceFields(generated, "ProviderAccountDoc");
const handDoc = extractInterfaceFields(handMaintained, "ProviderAccountDoc");
const generatedConnect = extractInterfaceFields(
  generated,
  "ProviderAccountConnectContext"
);
const handConnect = extractInterfaceFields(
  handMaintained,
  "ProviderAccountConnectContext"
);

function assertSuperset(label, generatedFields, handFields) {
  const missing = [...generatedFields].filter((field) => !handFields.has(field));
  if (missing.length > 0) {
    throw new Error(
      `${label} missing in functions/src/types/legacy.ts: ${missing.join(", ")}`
    );
  }
}

assertSuperset("ProviderAccountDoc", generatedDoc, handDoc);
assertSuperset("ProviderAccountConnectContext", generatedConnect, handConnect);

console.log("provider-account schema parity check passed");
