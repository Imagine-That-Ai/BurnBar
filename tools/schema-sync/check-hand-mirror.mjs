#!/usr/bin/env node
/**
 * Verify hand-maintained schema mirrors include every generated Firestore field.
 * Complements check-drift.sh (which guards generated output only).
 */

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");
const manifest = JSON.parse(
  readFileSync(join(__dirname, "manifest.json"), "utf8")
);

const ENDPOINT_PROFILE_FIELDS = [
  "endpointProfileID",
  "region",
  "tokenPlanTier",
  "tokenPlanBillingCycle",
  "authMethodID",
];

function extractInterfaceFields(tsSource, interfaceName) {
  const pattern = new RegExp(
    `export interface ${interfaceName}\\s*\\{([\\s\\S]*?)\\n\\}`,
    "m"
  );
  const match = tsSource.match(pattern);
  if (!match) {
    throw new Error(`Could not parse generated interface ${interfaceName}`);
  }
  const body = match[1];
  return [...body.matchAll(/^\s*(\w+)\??:/gm)].map((m) => m[1]);
}

function assertMirrorContainsFields(domainId, mirrorPath, fields) {
  const absolute = join(repoRoot, mirrorPath);
  const source = readFileSync(absolute, "utf8");
  const missing = fields.filter((field) => !source.includes(field));
  if (missing.length > 0) {
    throw new Error(
      `[${domainId}] ${mirrorPath} missing generated fields: ${missing.join(", ")}`
    );
  }
}

const CONNECT_ONLY_MIRRORS = new Set([
  "OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarProviderContracts.swift",
]);

function checkProviderAccountDomain(domain) {
  const generatedPath = join(repoRoot, domain.emit.typescript);
  const generated = readFileSync(generatedPath, "utf8");
  const docFields = extractInterfaceFields(generated, "ProviderAccountDoc");
  const connectFields = extractInterfaceFields(
    generated,
    "ProviderAccountConnectContext"
  );

  for (const field of ENDPOINT_PROFILE_FIELDS) {
    if (!docFields.includes(field)) {
      throw new Error(
        `[provider-account] generated ProviderAccountDoc missing ${field}`
      );
    }
    if (!connectFields.includes(field)) {
      throw new Error(
        `[provider-account] generated ProviderAccountConnectContext missing ${field}`
      );
    }
  }

  for (const mirrorPath of domain.swiftHandMirror ?? []) {
    const fields = CONNECT_ONLY_MIRRORS.has(mirrorPath) ? connectFields : docFields;
    assertMirrorContainsFields(domain.id, mirrorPath, fields);
  }
  for (const mirrorPath of domain.kotlinHandMirror ?? []) {
    assertMirrorContainsFields(domain.id, mirrorPath, docFields);
  }
}

let failures = 0;
for (const domain of manifest.domains) {
  if (domain.id !== "provider-account") continue;
  try {
    checkProviderAccountDomain(domain);
    console.log(`hand-mirror check passed: ${domain.id}`);
  } catch (error) {
    failures += 1;
    console.error(String(error.message ?? error));
  }
}

if (failures > 0) {
  process.exit(1);
}
