#!/usr/bin/env node
// Compact firestore.rules in place (strip line comments + blank lines) so the
// ruleset deployed through firebase-tools matches what the drift check compares
// against (check-firestore-deploy-drift.mjs compacts the repo side). Intended to
// run only in the ephemeral CI workspace immediately before `firebase deploy`.
// It is a no-op-safe idempotent transform: compacting already-compact source
// yields the same bytes.
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import { compactFirebaseRulesSource } from "./firebase-rules-source.mjs";

const target = resolve(process.cwd(), process.argv[2] || "firestore.rules");
const raw = readFileSync(target, "utf8");
const compacted = compactFirebaseRulesSource(raw);
writeFileSync(target, compacted);
console.log(
  `compacted ${target} raw=${Buffer.byteLength(raw)} compacted=${Buffer.byteLength(compacted)} bytes`,
);
