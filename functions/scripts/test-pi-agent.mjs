import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  isPiAgentConnectionDoc,
  piAgentPairingCodeDigest,
  piAgentSafeEqualHex,
  parsePiAgentPlatform,
  randomPiAgentPairingCode,
  sanitizePiAgentCapabilities,
  sanitizePiAgentInstances,
  sanitizePiAgentModels,
  validatePiAgentEndpointURL,
} from "../lib/piAgent.js";

function assertHttpsError(fn, code) {
  assert.throws(fn, (err) => err?.code === code);
}

const code = randomPiAgentPairingCode();
assert.match(code, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
assert.equal(piAgentPairingCodeDigest("ab12-cd34"), piAgentPairingCodeDigest("AB12CD34"));
assert.equal(piAgentSafeEqualHex(piAgentPairingCodeDigest("AB12-CD34"), piAgentPairingCodeDigest("ab12cd34")), true);
assert.equal(piAgentSafeEqualHex(piAgentPairingCodeDigest("AB12-CD34"), piAgentPairingCodeDigest("AB12-CD35")), false);

assert.equal(validatePiAgentEndpointURL("https://pi.example.com/", "directURL"), "https://pi.example.com");
assert.equal(validatePiAgentEndpointURL("http://127.0.0.1:8765", "directURL"), "http://127.0.0.1:8765");
assert.equal(validatePiAgentEndpointURL("http://192.168.1.10:8765", "directURL"), "http://192.168.1.10:8765");
assert.equal(validatePiAgentEndpointURL(undefined, "relayLink"), undefined);
assertHttpsError(() => validatePiAgentEndpointURL(undefined, "directURL"), "invalid-argument");
assertHttpsError(() => validatePiAgentEndpointURL("http://8.8.8.8:8765", "directURL"), "invalid-argument");
assertHttpsError(() => validatePiAgentEndpointURL("https://token@example.com", "directURL"), "invalid-argument");
assertHttpsError(() => validatePiAgentEndpointURL("https://pi.example.com?api_key=secret", "directURL"), "invalid-argument");
assertHttpsError(() => validatePiAgentEndpointURL("ftp://pi.example.com", "directURL"), "invalid-argument");

assert.equal(parsePiAgentPlatform("ios"), "ios");
assert.equal(parsePiAgentPlatform("android"), "android");
assert.equal(parsePiAgentPlatform(undefined), undefined);
assertHttpsError(() => parsePiAgentPlatform("desktop"), "invalid-argument");

const noisyCapabilities = [" chat_completions ", "", 123, "x".repeat(65), ...Array.from({ length: 40 }, (_, i) => `cap_${i}`)];
const capabilities = sanitizePiAgentCapabilities(noisyCapabilities);
assert.equal(capabilities[0], "chat_completions");
assert.equal(capabilities.includes(""), false);
assert.equal(capabilities.some((item) => item.length > 64), false);
assert.equal(capabilities.length, 32);

const instances = sanitizePiAgentInstances([
  { id: "default", displayName: "Default", status: "online", endpointURL: "http://127.0.0.1:8765", capabilities: ["chat_completions"] },
  { id: "", displayName: "ignored" },
]);
assert.equal(instances.length, 1);
assert.equal(instances[0].id, "default");

const models = sanitizePiAgentModels([
  { providerID: "pi", providerName: "Pi", modelID: "pi-default", displayName: "Pi Default", instanceID: "default" },
  { providerID: "bad" },
]);
assert.equal(models.length, 1);
assert.equal(models[0].id, "pi:pi-default");

assert.equal(isPiAgentConnectionDoc({
  id: "pi_1",
  displayName: "Pi Agent",
  mode: "directURL",
  status: "online",
  capabilities: ["chat_completions"],
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
  schemaVersion: 1,
}), true);
assert.equal(isPiAgentConnectionDoc({ id: "partial", status: "revoked" }), false);

const rules = readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8");
for (const collection of ["pi_agent_pairings", "pi_agent_audit_events"]) {
  const start = rules.indexOf(`match /users/{userId}/${collection}/`);
  assert.notEqual(start, -1, `${collection} rules block must exist`);
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow write: if false;/, `${collection} must be server-only for writes`);
}
{
  const start = rules.indexOf("match /users/{userId}/pi_agent_connections/");
  assert.notEqual(start, -1, "pi_agent_connections rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create: if piRelayConnectionWrite\(userId, connectionId\);/);
  assert.match(block, /allow update: if piRelayConnectionWrite\(userId, connectionId\) && resource\.data\.mode == "relayLink";/);
  assert.match(rules, /function piRelayConnectionWrite\(userId, connectionId\)/);
}
{
  const start = rules.indexOf("match /users/{userId}/pi_agent_relay_requests/");
  assert.notEqual(start, -1, "pi_agent_relay_requests rules block must exist");
  const block = rules.slice(start, rules.indexOf("\n    }\n", start) + 7);
  assert.match(block, /allow create, update: if piRelayRequestWrite\(userId, requestId\);/);
  assert.match(rules, /function piRelayRequestWrite\(userId, requestId\)[\s\S]*request\.resource\.data\.schemaVersion >= 2/);
  assert.match(rules, /function piRelayRequestWrite\(userId, requestId\)[\s\S]*request\.resource\.data\.payloadCiphertext is string/);
  assert.match(rules, /function piRelayChunkWrite\(userId, requestId, chunkId\)[\s\S]*request\.resource\.data\.ciphertext is string/);
  assert.doesNotMatch(rules, /match \/users\/\{userId\}\/pi_agent_relay_requests\/\{requestId\}[\s\S]*relayRequestWrite\(userId, requestId\)/);
}
{
  const functionsSource = readFileSync(new URL("../src/index.ts", import.meta.url), "utf8");
  for (const exportedName of [
    "createPiAgentPairing",
    "completePiAgentPairing",
    "listPiAgentConnections",
    "revokePiAgentConnection",
    "updatePiAgentConnectionStatus",
  ]) {
    const start = functionsSource.indexOf(`export const ${exportedName}`);
    assert.notEqual(start, -1, `${exportedName} must exist`);
    const block = functionsSource.slice(start, functionsSource.indexOf("\n);\n", start) + 4);
    assert.match(block, /await assertActiveHostedQuotaEntitlement\(uid\);/, `${exportedName} must be premium-gated`);
  }
  assert.match(functionsSource, /pi_agent_create_pairing|pi_agent_\$\{action\}|pi_agent_/);
}

console.log("Pi Agent contract and Firestore rule invariants passed");
