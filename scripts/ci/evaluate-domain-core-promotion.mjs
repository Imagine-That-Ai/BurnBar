#!/usr/bin/env node

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { evaluatePromotionEvidence } from "../lib/domain-core-promotion-evidence.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DEFAULT_POLICY = join(REPO_ROOT, "config", "domain-core-promotion-policy.json");

function usage(message) {
  if (message) console.error(message);
  console.error(
    "usage: evaluate-domain-core-promotion.mjs --domain <quota|cloudvault|hermes|pricing> --evidence <path> [--output <path>]",
  );
  process.exit(1);
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!value || !new Set(["--domain", "--evidence", "--output"]).has(flag)) {
      usage(`invalid argument: ${flag ?? "<missing>"}`);
    }
    result[flag.slice(2)] = value;
  }
  if (!result.domain) usage("--domain is required");
  if (!result.evidence) usage("--evidence is required");
  return result;
}

function loadJson(path, label) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    const report = {
      schemaVersion: 1,
      domain: null,
      status: "invalid",
      ready: false,
      errors: [`unable to read ${label}: ${error instanceof Error ? error.message : String(error)}`],
      blockers: [{ code: "invalid_evidence", consumer: null }],
    };
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }
}

function writeAtomically(path, contents) {
  const destination = resolve(path);
  const temporary = `${destination}.tmp-${process.pid}`;
  writeFileSync(temporary, contents, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, destination);
}

const args = parseArguments(process.argv.slice(2));
const evidence = loadJson(args.evidence, "evidence");
const policy = loadJson(DEFAULT_POLICY, "policy");
const report = evidence?.domain === args.domain
  ? evaluatePromotionEvidence(evidence, policy)
  : {
      schemaVersion: 2,
      domain: args.domain,
      status: "invalid",
      ready: false,
      errors: [`evidence.domain must equal requested domain ${args.domain}`],
      blockers: [{ code: "invalid_evidence", slice: null, consumer: null }],
    };
const serialized = `${JSON.stringify(report, null, 2)}\n`;
if (args.output) writeAtomically(args.output, serialized);
process.stdout.write(serialized);
process.exit(report.status === "ready" ? 0 : report.status === "not_ready" ? 2 : 1);
