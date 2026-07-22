#!/usr/bin/env node
import { createRequire } from "node:module";
import { writeFile } from "node:fs/promises";

import {
  buildDomainCorePromotionEvidence,
  validateDomainCorePromotionOptions,
} from "../lib/export-domain-core-promotion-evidence.mjs";

const ARGUMENTS = new Set([
  "project",
  "domain",
  "start",
  "end",
  "channel",
  "candidate-commit",
  "expected-core-version",
  "expected-core-abi-version",
  "expected-core-source-sha256",
  "source-uri",
  "output",
]);

function argumentsFrom(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined || value.length === 0)
      throw new Error(`Invalid argument near ${key ?? "end"}`);
    const name = key.slice(2);
    if (!ARGUMENTS.has(name)) throw new Error(`Unknown argument --${name}`);
    if (values.has(name)) throw new Error(`Duplicate argument --${name}`);
    values.set(name, value);
  }
  for (const required of ARGUMENTS) {
    if (!values.has(required)) throw new Error(`Missing --${required}`);
  }
  if (!new Set(["internal", "beta"]).has(values.get("channel"))) {
    throw new Error("--channel must be internal or beta");
  }
  if (
    !new Set(["quota", "cloudvault", "hermes", "pricing"]).has(
      values.get("domain"),
    )
  ) {
    throw new Error("--domain must be quota, cloudvault, hermes, or pricing");
  }
  return values;
}

async function main() {
  const args = argumentsFrom(process.argv.slice(2));
  const startedAt = new Date(args.get("start"));
  const endedAt = new Date(args.get("end"));
  const expectedCoreAbiVersion = Number(args.get("expected-core-abi-version"));
  const promotionOptions = {
    domain: args.get("domain"),
    channel: args.get("channel"),
    candidateCommit: args.get("candidate-commit"),
    expectedCoreVersion: args.get("expected-core-version"),
    expectedCoreAbiVersion,
    expectedCoreSourceSha256: args.get("expected-core-source-sha256"),
    startedAt,
    endedAt,
    generatedAt: new Date(),
    sourceUri: args.get("source-uri"),
  };
  validateDomainCorePromotionOptions(promotionOptions);
  const requireFromFunctions = createRequire(
    new URL("../../functions/package.json", import.meta.url),
  );
  const { applicationDefault, getApps, initializeApp } =
    requireFromFunctions("firebase-admin/app");
  const { getFirestore, Timestamp } = requireFromFunctions(
    "firebase-admin/firestore",
  );
  if (getApps().length === 0)
    initializeApp({
      credential: applicationDefault(),
      projectId: args.get("project"),
    });
  const snapshot = await getFirestore()
    .collection("domain_core_shadow_samples")
    .where("receivedAt", ">=", Timestamp.fromDate(startedAt))
    .where("receivedAt", "<", Timestamp.fromDate(endedAt))
    .orderBy("receivedAt")
    .get();
  const evidence = buildDomainCorePromotionEvidence(
    snapshot.docs.map((document) => document.data()),
    { ...promotionOptions, generatedAt: new Date() },
  );
  await writeFile(
    args.get("output"),
    `${JSON.stringify(evidence, null, 2)}\n`,
    { mode: 0o600 },
  );
}

main().catch((error) => {
  process.stderr.write(
    `${error instanceof Error ? error.message : String(error)}\n`,
  );
  process.exitCode = 1;
});
