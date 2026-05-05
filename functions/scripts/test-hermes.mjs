import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  isHermesConnectionDoc,
  pairingCodeDigest,
  parseHermesPlatform,
  randomPairingCode,
  safeEqualHex,
  sanitizeHermesCapabilities,
  validateHermesEndpointURL,
} from "../lib/hermes.js";

function assertHttpsError(fn, code) {
  assert.throws(fn, (err) => err?.code === code);
}

const code = randomPairingCode();
assert.match(code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
assert.equal(pairingCodeDigest("ab12-cd34"), pairingCodeDigest("AB12CD34"));
assert.equal(safeEqualHex(pairingCodeDigest("AB12-CD34"), pairingCodeDigest("ab12cd34")), true);
assert.equal(safeEqualHex(pairingCodeDigest("AB12-CD34"), pairingCodeDigest("AB12-CD35")), false);

assert.equal(validateHermesEndpointURL("https://hermes.example.com/", "directURL"), "https://hermes.example.com");
assert.equal(validateHermesEndpointURL("http://127.0.0.1:8642", "directURL"), "http://127.0.0.1:8642");
assert.equal(validateHermesEndpointURL("http://192.168.1.10:8642", "directURL"), "http://192.168.1.10:8642");
assert.equal(validateHermesEndpointURL(undefined, "relayLink"), undefined);
assertHttpsError(() => validateHermesEndpointURL(undefined, "directURL"), "invalid-argument");
assertHttpsError(() => validateHermesEndpointURL("http://8.8.8.8:8642", "directURL"), "invalid-argument");
assertHttpsError(() => validateHermesEndpointURL("https://token@example.com", "directURL"), "invalid-argument");
assertHttpsError(() => validateHermesEndpointURL("https://hermes.example.com?api_key=secret", "directURL"), "invalid-argument");
assertHttpsError(() => validateHermesEndpointURL("ftp://hermes.example.com", "directURL"), "invalid-argument");

assert.equal(parseHermesPlatform("ios"), "ios");
assert.equal(parseHermesPlatform("ipados"), "ipados");
assert.equal(parseHermesPlatform(undefined), undefined);
assertHttpsError(() => parseHermesPlatform("desktop"), "invalid-argument");

const noisyCapabilities = [" chat_completions ", "", 123, "x".repeat(65), ...Array.from({ length: 40 }, (_, i) => `cap_${i}`)];
const capabilities = sanitizeHermesCapabilities(noisyCapabilities);
assert.equal(capabilities[0], "chat_completions");
assert.equal(capabilities.includes(""), false);
assert.equal(capabilities.some((item) => item.length > 64), false);
assert.equal(capabilities.length, 32);

assert.equal(isHermesConnectionDoc({
  id: "hermes_1",
  displayName: "Hermes",
  mode: "directURL",
  status: "online",
  capabilities: ["chat_completions"],
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
  schemaVersion: 1,
}), true);
assert.equal(isHermesConnectionDoc({ id: "partial", status: "revoked" }), false);

const rules = readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8");
for (const collection of ["hermes_pairings", "hermes_session_cache", "hermes_audit_events"]) {
  const start = rules.indexOf(`match /users/{userId}/${collection}/`);
  assert.notEqual(start, -1, `${collection} rules block must exist`);
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow write: if false;/, `${collection} must be server-only for writes`);
  assert.doesNotMatch(block, /ownerWritableNonSecret/, `${collection} must not use client-writable helper`);
}
{
  const start = rules.indexOf("match /users/{userId}/hermes_connections/");
  assert.notEqual(start, -1, "hermes_connections rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create: if relayConnectionWrite\(userId, connectionId\);/);
  assert.match(block, /allow update: if relayConnectionWrite\(userId, connectionId\) && resource\.data\.mode == "relayLink";/);
  assert.match(rules, /request\.resource\.data\.mode == "relayLink"/);
  assert.match(rules, /request\.resource\.data\.id == connectionId/);
  assert.match(rules, /request\.resource\.data\.keys\(\)\.hasOnly\(\[[\s\S]*"advertisedModel"[\s\S]*"relayPublicKey"[\s\S]*"relayEncryption"[\s\S]*\]\)/);
  assert.match(rules, /request\.resource\.data\.relayEncryption == "p256-hkdf-sha256-aesgcm"/);
  assert.doesNotMatch(block, /ownerWritableNonSecret\(userId\);/, "direct Hermes URLs must not become broadly client-writable");
}
for (const collection of ["hermes_relay_requests"]) {
  const start = rules.indexOf(`match /users/{userId}/${collection}/`);
  assert.notEqual(start, -1, `${collection} rules block must exist`);
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create, update: if relayRequestWrite\(userId, requestId\);/);
  assert.match(rules, /request\.resource\.data\.id == requestId/);
  assert.match(rules, /match \/chunks\/\{chunkId\}/);
  assert.match(rules, /allow create, update: if relayChunkWrite\(userId, requestId, chunkId\);/);
  assert.match(rules, /request\.resource\.data\.id == chunkId/);
  assert.match(rules, /request\.resource\.data\.requestId == requestId/);
}
assert.match(rules, /request\.resource\.data\.schemaVersion < 2[\s\S]*!\("body" in request\.resource\.data\)[\s\S]*request\.resource\.data\.payloadCiphertext is string/);
assert.match(rules, /request\.resource\.data\.schemaVersion < 2[\s\S]*!\("data" in request\.resource\.data\)[\s\S]*request\.resource\.data\.ciphertext is string/);
assert.match(readFileSync(new URL("../src/index.ts", import.meta.url), "utf8"), /current\.status === "revoked"/);
assert.match(rules, /!\("secretVersionName" in request\.resource\.data\)/);

console.log("Hermes contract and Firestore rule invariants passed");
