#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { writeFile } from "node:fs/promises";

import { buildDomainCorePromotionEvidence } from "../lib/export-domain-core-promotion-evidence.mjs";

function argumentsFrom(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error(`Invalid argument near ${key ?? "end"}`);
    values.set(key.slice(2), value);
  }
  for (const required of ["project", "domain", "start", "end", "channel", "core-version", "source-uri", "output"]) {
    if (!values.has(required)) throw new Error(`Missing --${required}`);
  }
  if (!new Set(["internal", "beta"]).has(values.get("channel"))) {
    throw new Error("--channel must be internal or beta");
  }
  if (!new Set(["quota", "cloudvault", "hermes", "pricing"]).has(values.get("domain"))) {
    throw new Error("--domain must be quota, cloudvault, hermes, or pricing");
  }
  return values;
}

async function main() {
  const args = argumentsFrom(process.argv.slice(2));
  const requireFromFunctions = createRequire(new URL("../../functions/package.json", import.meta.url));
  const { applicationDefault, getApps, initializeApp } = requireFromFunctions("firebase-admin/app");
  const { getFirestore, Timestamp } = requireFromFunctions("firebase-admin/firestore");
  if (getApps().length === 0) initializeApp({ credential: applicationDefault(), projectId: args.get("project") });
  const startedAt = new Date(args.get("start"));
  const endedAt = new Date(args.get("end"));
  const snapshot = await getFirestore()
    .collection("domain_core_shadow_samples")
    .where("observedAt", ">=", Timestamp.fromDate(startedAt))
    .where("observedAt", "<=", Timestamp.fromDate(endedAt))
    .orderBy("observedAt")
    .get();
  const queryRevision =
    args.get("query-revision") ?? execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
  const evidence = buildDomainCorePromotionEvidence(
    snapshot.docs.map((document) => document.data()),
    {
      domain: args.get("domain"),
      channel: args.get("channel"),
      coreVersion: args.get("core-version"),
      startedAt,
      endedAt,
      generatedAt: new Date(),
      queryRevision,
      sourceUri: args.get("source-uri"),
    },
  );
  await writeFile(args.get("output"), `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
}

main().catch((error) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
