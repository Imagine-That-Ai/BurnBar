#!/usr/bin/env node
import { createRequire } from "node:module";
import { resolve } from "node:path";
import {
  clearDomainCoreShadowClaims,
  enrollmentMatches,
  mergeDomainCoreShadowClaims,
  normalizeDomainCoreShadowEnrollment,
} from "../lib/domain-core-shadow-enrollment.mjs";

const args = new Map();
const flags = new Set();
for (let index = 2; index < process.argv.length; index += 1) {
  const arg = process.argv[index];
  if (["--apply", "--clear", "--verify"].includes(arg)) flags.add(arg);
  else if (arg.startsWith("--")) args.set(arg, process.argv[++index]);
  else throw new Error(`unknown argument: ${arg}`);
}
const uid = args.get("--uid");
if (!uid) throw new Error("--uid is required");
if (flags.has("--clear") && flags.has("--verify")) throw new Error("--clear and --verify are mutually exclusive");

const requireFromFunctions = createRequire(resolve("functions/package.json"));
const { applicationDefault, getApps, initializeApp } = requireFromFunctions("firebase-admin/app");
const { getAuth } = requireFromFunctions("firebase-admin/auth");
if (getApps().length === 0) initializeApp({ credential: applicationDefault(), projectId: args.get("--project") });
const auth = getAuth();
const user = await auth.getUser(uid);
const existing = user.customClaims ?? {};

if (flags.has("--clear")) {
  const next = clearDomainCoreShadowClaims(existing);
  if (flags.has("--apply")) await auth.setCustomUserClaims(uid, next);
  console.log(JSON.stringify({ uid, action: flags.has("--apply") ? "cleared" : "would-clear", claims: next }, null, 2));
  process.exit(0);
}

const enrollment = normalizeDomainCoreShadowEnrollment(
  args.get("--channel"),
  (args.get("--consumers") ?? "").split(","),
);
if (flags.has("--verify")) {
  if (!enrollmentMatches(existing, enrollment)) {
    console.error(JSON.stringify({ uid, status: "mismatch", expected: enrollment, claims: existing }, null, 2));
    process.exit(2);
  }
  console.log(JSON.stringify({ uid, status: "verified", enrollment }, null, 2));
  process.exit(0);
}

const next = mergeDomainCoreShadowClaims(existing, enrollment);
if (Buffer.byteLength(JSON.stringify(next), "utf8") > 900) throw new Error("merged custom claims exceed the 900-byte operator safety limit");
if (flags.has("--apply")) await auth.setCustomUserClaims(uid, next);
console.log(JSON.stringify({ uid, action: flags.has("--apply") ? "merged" : "would-merge", claims: next }, null, 2));
