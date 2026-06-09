import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  loadRegistry,
  validateRegistry,
  generateAll,
  emitWebsiteTrust,
  loadTierColors,
  WEBSITE_TRUST_PATH,
} from "./codegen.mjs";
import { findDrift, userCollectionsInRules } from "./driftcheck.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const registry = loadRegistry();

test("registry validates structurally", () => {
  assert.doesNotThrow(() => validateRegistry(registry));
  assert.ok(registry.domains.length >= 12, "expect the full ~12-domain control center");
});

test("every domain has a unique id and a known encryption tier", () => {
  const ids = registry.domains.map((d) => d.id);
  assert.equal(new Set(ids).size, ids.length, "domain ids must be unique");
  const tiers = new Set(["server_readable", "zero_access", "end_to_end"]);
  for (const d of registry.domains) assert.ok(tiers.has(d.encryptionTier), `${d.id} bad tier`);
});

test("E2E domains never claim the server sees content", () => {
  for (const d of registry.domains.filter((d) => d.encryptionTier === "end_to_end")) {
    assert.ok(d.deviceOnly.length > 0, `${d.id} (E2E) must list device-only (plaintext) fields`);
  }
});

test("codegen emits TS + Swift + Kotlin and they reference every domain", () => {
  const files = generateAll(registry);
  for (const rel of ["gen/domains.ts", "gen/DataDomains.swift", "gen/DataDomains.kt"]) {
    assert.ok(files[rel] && files[rel].length > 100, `${rel} generated`);
    for (const d of registry.domains) {
      assert.ok(files[rel].includes(`"${d.id}"`), `${rel} must include domain ${d.id}`);
    }
  }
});

test("generated files on disk are up to date with registry (run `npm run build` if this fails)", () => {
  const files = generateAll(registry);
  for (const [rel, content] of Object.entries(files)) {
    const onDisk = readFileSync(join(HERE, rel), "utf8");
    assert.equal(onDisk, content, `${rel} is stale — regenerate with: node codegen.mjs`);
  }
});

// Apple consumes gen/DataDomains.swift directly via project.yml source paths,
// but Android cannot reference files outside its module, so it keeps a copied
// in-tree DataDomains.kt synced by the `:app:syncGeneratedSources` Gradle task.
// This is exactly how the false "end-to-end encrypted" chat label drifted in
// once (a hand-edited GENERATED-DO-NOT-EDIT copy), so CI — not a reviewer —
// must catch any divergence between the Android copy and the registry.
test("android in-tree DataDomains.kt matches generated output (run ./gradlew :app:syncGeneratedSources)", () => {
  const generated = generateAll(registry)["gen/DataDomains.kt"];
  const androidPath = join(
    HERE,
    "..",
    "..",
    "android",
    "app",
    "src",
    "main",
    "java",
    "com",
    "openburnbar",
    "data",
    "domains",
    "DataDomains.kt"
  );
  const onDisk = readFileSync(androidPath, "utf8");
  assert.equal(
    onDisk,
    generated,
    "android DataDomains.kt is stale — run ./gradlew :app:syncGeneratedSources (the Android privacy labels must equal registry.json byte-for-byte)"
  );
});

test("firestore.rules parser finds the known Pensieve + core collections", () => {
  const rulesText = readFileSync(join(HERE, "..", "..", "firestore.rules"), "utf8");
  const cols = userCollectionsInRules(rulesText);
  for (const c of ["usage", "cloud_search_knowledge", "knowledge_sync_manifests", "entitlements", "remote_mcp_clients"]) {
    assert.ok(cols.has(c), `rules parser must find ${c}`);
  }
});

test("NO DRIFT: every user subcollection in firestore.rules is registered or excluded", () => {
  const rulesText = readFileSync(join(HERE, "..", "..", "firestore.rules"), "utf8");
  const { uncovered } = findDrift(rulesText, registry);
  assert.deepEqual(uncovered, [], `uncovered collections: ${uncovered.join(", ")}`);
});

// ── Website trust surface (burnbar.ai/trust) ────────────────────────────────
// The public marketing site renders every factual claim about what the server
// can and cannot see from this generated module. Exactly like the Android
// DataDomains.kt copy, CI — not a reviewer — must catch any divergence between
// the in-tree website copy and the registry. This is where the old, overstated
// marketing claims (chat "end-to-end encrypted") drifted in; the assertions
// below make them impossible to reintroduce.

test("website trust.generated.ts matches the registry (run `node codegen.mjs`)", () => {
  const generated = emitWebsiteTrust(registry, loadTierColors());
  const onDisk = readFileSync(WEBSITE_TRUST_PATH, "utf8");
  assert.equal(
    onDisk,
    generated,
    "website/src/data/trust.generated.ts is stale — run `node packages/data-domains/codegen.mjs` and commit the result (the public trust copy must equal registry.json byte-for-byte)"
  );
});

test("website tier badge colors come from the design-token source of truth", () => {
  const colors = loadTierColors();
  // Locked to the Pensieve token values so the live badges match the in-app
  // Data & Privacy Control Center byte-for-byte.
  assert.equal(colors.server_readable, "#fdc42c", "server-readable tier color drifted from design tokens");
  assert.equal(colors.zero_access, "#8b94a8", "zero-access tier color drifted from design tokens");
  assert.equal(colors.end_to_end, "#3cd6c0", "end-to-end tier color drifted from design tokens");
});

test("website tokens.css dark-theme tier vars mirror the design tokens", () => {
  // The site's theme-flipping --tier-* custom properties (tokens.css) drive
  // SealBadge tints, TrustBoundaryMap lanes, ClaimsLedger spines, and the
  // TrustTierBadge. Their DARK values must equal the generated colorHex so the
  // public trust surface and the in-app control center can never diverge on
  // the same page. (Light-theme values are deliberately AA-darkened.)
  const colors = loadTierColors();
  const tokensCss = readFileSync(
    join(HERE, "..", "..", "website", "src", "styles", "tokens.css"),
    "utf8"
  );
  const darkBlock = tokensCss.slice(0, tokensCss.indexOf('[data-theme="light"]'));
  const varValue = (name) => {
    const m = darkBlock.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`));
    assert.ok(m, `tokens.css is missing ${name} in the dark :root block`);
    return m[1].toLowerCase();
  };
  assert.equal(varValue("--tier-server"), colors.server_readable, "--tier-server drifted from design tokens");
  assert.equal(varValue("--tier-zero"), colors.zero_access, "--tier-zero drifted from design tokens");
  assert.equal(varValue("--tier-e2e"), colors.end_to_end, "--tier-e2e drifted from design tokens");
});

test("HONEST CLAIMS: the public trust copy never overstates the product", () => {
  const trust = emitWebsiteTrust(registry, loadTierColors());

  // 1. No over-loaded / unearned crypto terms anywhere on the public surface.
  for (const banned of [/zero-knowledge/i, /\binversion\b/i, /embedding-inversion/i]) {
    assert.ok(!banned.test(trust), `public trust copy must not contain ${banned}`);
  }

  // 2. No internal transport / relay codenames leak to the marketing site.
  for (const codename of [/\bHermes\b/, /\biroh\b/, /\bMercury\b/, /\bPi agent\b/]) {
    assert.ok(!codename.test(trust), `public trust copy must not expose codename ${codename}`);
  }

  // 3. Chat mirrors must stay end-to-end sealed. Find the conversations_chat
  //    block in the generated source and assert on it.
  const chat = registry.domains.find((d) => d.id === "conversations_chat");
  assert.equal(chat.encryptionTier, "end_to_end", "chat mirrors must stay end-to-end in the registry");
  const chatBlock = trust.slice(trust.indexOf('"id": "conversations_chat"'), trust.indexOf('"id": "session_logs"'));
  assert.ok(chatBlock.length > 0, "expected a conversations_chat block in the generated trust module");
  assert.match(chatBlock, /"tier": "end_to_end"/, "chat must be tiered end-to-end on the public site");
  assert.ok(!/server can read/i.test(chatBlock), "chat must not say the server can read mirrored text");
  assert.ok(!/server_readable/i.test(chatBlock), "chat block must not contain the server-readable tier");
  assert.ok(/sealed on-device/i.test(chatBlock), "chat must say mirrored content is sealed on-device");
});

// ── Honesty assertions for the privacy-leak remediation (2026-06-02) ─────────
// usage/budget project text is sealed; project-identity strings never appear as
// a server-readable facet, only an opaque per-project hash for group-by.

test("HONEST CLAIMS: usage_spend hides project names behind an opaque hash", () => {
  const usage = registry.domains.find((d) => d.id === "usage_spend");
  assert.ok(usage, "expected the usage_spend domain");
  const serverLower = usage.serverSees.map((v) => v.toLowerCase());
  // The bare "project" facet (project name / identity) must be gone.
  assert.ok(
    !serverLower.includes("project"),
    "usage_spend serverSees must not claim it reads the plaintext project",
  );
  // What the server may group by is an OPAQUE hash, said so out loud.
  assert.ok(
    serverLower.some((v) => v.includes("opaque") && v.includes("hash")),
    "usage_spend serverSees must declare the opaque project hash it groups by",
  );
  // Project names and budget labels are device-only (sealed) plaintext.
  const deviceLower = usage.deviceOnly.map((v) => v.toLowerCase());
  assert.ok(
    deviceLower.some((v) => v.includes("project name")),
    "usage_spend deviceOnly must list project names as sealed/device-only",
  );
  assert.ok(
    deviceLower.some((v) => v.includes("budget label")),
    "usage_spend deviceOnly must list budget labels as sealed/device-only",
  );
});

// pensieve: a connected repo stores only an opaque keyed match token + a sealed
// repo name; the cleartext repo name is observed transiently for webhook routing
// only (never stored). The registry must name that caveat and keep repo names
// off the server-readable facet list.

test("HONEST CLAIMS: pensieve repo names are device-only with a webhook caveat", () => {
  const pensieve = registry.domains.find((d) => d.id === "pensieve");
  assert.ok(pensieve, "expected the pensieve domain");
  assert.equal(pensieve.encryptionTier, "end_to_end", "pensieve must stay end-to-end");
  const serverLower = pensieve.serverSees.map((v) => v.toLowerCase());
  // The server-readable facets must not name plaintext repo identity.
  assert.ok(
    !serverLower.some((v) => v.includes("repo name") || v.includes("repofullname") || v.includes("repo full name")),
    "pensieve serverSees must not claim it reads the cleartext repo name",
  );
  // It DOES hold an opaque match token + keyed hashes, named honestly.
  assert.ok(
    serverLower.some((v) => v.includes("opaque") && v.includes("match token")),
    "pensieve serverSees must declare the opaque repo match token",
  );
  // Repo names are sealed/device-only.
  assert.ok(
    pensieve.deviceOnly.map((v) => v.toLowerCase()).some((v) => v.includes("repo name")),
    "pensieve deviceOnly must list repo names as sealed/device-only",
  );
  // The honest caveat: the cleartext repo name is only seen transiently for the
  // GitHub webhook, never stored.
  assert.ok(/NOTE:/.test(pensieve.summary), "pensieve summary must carry a NOTE caveat");
  assert.match(
    pensieve.summary,
    /webhook/i,
    "pensieve summary must explain the repo name is observed transiently only for webhook routing",
  );
});

// connected_devices: relay/gateway content-sealing claims are runtime-gated.
// The registry can describe the paired E2EE mode, but it must not turn that into
// an unconditional production claim while the release-readiness manifest is
// still not_ready.

test("HONEST CLAIMS: connected_devices caveats relay and hosted gateway sealing", () => {
  const devices = registry.domains.find((d) => d.id === "connected_devices");
  assert.ok(devices, "expected the connected_devices domain");
  const serverLower = devices.serverSees.map((v) => v.toLowerCase());
  const summaryLower = devices.summary.toLowerCase();
  const deviceOnlyLower = devices.deviceOnly.map((v) => v.toLowerCase()).join(" ");

  assert.match(devices.summary, /NOTE:/, "connected_devices summary must carry a NOTE caveat");
  assert.match(summaryLower, /runtime-readiness gate/, "connected_devices must bind sealing to readiness");
  assert.match(summaryLower, /paired e2ee/, "connected_devices must bind sealing to paired E2EE");
  assert.ok(
    !/never (?:reads?|receives?|sees) plaintext/i.test(devices.summary),
    "connected_devices summary must not make an unconditional plaintext-visibility denial",
  );
  assert.ok(
    !/both directions are end-to-end encrypted/i.test(devices.summary),
    "connected_devices summary must not make an unconditional hosted-gateway E2EE claim",
  );
  for (const visible of ["routing metadata", "public keys", "tool labels", "thread ids", "attachment ids"]) {
    assert.ok(summaryLower.includes(visible), `connected_devices summary must disclose visible ${visible}`);
  }
  assert.ok(
    serverLower.some((v) => v.includes("opaque") && v.includes("key material")),
    "connected_devices serverSees must declare the opaque relay public-key material it routes",
  );
  assert.ok(
    deviceOnlyLower.includes("runtime readiness is complete"),
    "connected_devices deviceOnly must caveat gateway frame contents on runtime readiness",
  );
  assert.ok(
    !/server can read/i.test(devices.summary),
    "connected_devices summary must not say the server can read the gateway",
  );
});

// rollback_requests + W3 same-pattern private collections: previously buried in
// excludedCollections as "ephemeral/local" state. They carry device-private
// rollback scope, approval labels/globs/projects, agent personas, and the
// subscription graph. They are now folded into conversations_chat (sealed
// end-to-end) so export/delete owns the ciphertext and the registry tells the
// truth about the private text it holds.

test("HONEST CLAIMS: W3 sealed private collections are folded into conversations_chat, not hidden as excluded state", () => {
  const chat = registry.domains.find((d) => d.id === "conversations_chat");
  assert.ok(chat, "expected the conversations_chat domain");
  assert.equal(chat.encryptionTier, "end_to_end", "conversations_chat must stay end-to-end");
  for (const name of ["rollback_requests", "approval_policies", "agent_identities", "subscription_topics"]) {
    assert.ok(
      chat.firestorePaths.includes(name),
      `conversations_chat must own the ${name} path so it is no longer hidden in excludedCollections`,
    );
    assert.ok(
      !Object.prototype.hasOwnProperty.call(registry.excludedCollections ?? {}, name),
      `${name} must be removed from excludedCollections once folded into a sealed domain`,
    );
  }
  // The device-only facets must name the genuinely private rollback text.
  const deviceLower = chat.deviceOnly.map((v) => v.toLowerCase());
  assert.ok(
    deviceLower.some((v) => v.includes("rollback scope")),
    "conversations_chat deviceOnly must list rollback scope paths as sealed/device-only",
  );
  assert.ok(
    deviceLower.some((v) => v.includes("rollback error")),
    "conversations_chat deviceOnly must list rollback error diagnostics as sealed/device-only",
  );
  assert.ok(
    deviceLower.some((v) => v.includes("approval policy")),
    "conversations_chat deviceOnly must list approval policy private labels/globs/projects",
  );
  assert.ok(
    deviceLower.some((v) => v.includes("agent persona")),
    "conversations_chat deviceOnly must list agent persona text",
  );
  assert.ok(
    deviceLower.some((v) => v.includes("subscription graph")),
    "conversations_chat deviceOnly must list subscription graph edges",
  );
});

// ── sealingScheme: an OPTIONAL, apps-internal at-rest sealing codename ────────
// (signalification Stream 5). It records HOW an end_to_end domain is sealed at
// rest (CloudVault AES-GCM today; a future Signal HPKE identity seal) WITHOUT
// changing the tier or leaking the codename to the public trust surface. These
// assertions bind the field to reality so it can never be misused.

test("sealingScheme: pensieve carries the CloudVault at-rest scheme; future Signal scheme is NOT set yet", () => {
  const pensieve = registry.domains.find((d) => d.id === "pensieve");
  assert.ok(pensieve, "expected the pensieve domain");
  // Today's value is the existing CloudVault AES-GCM at-rest seal.
  assert.equal(
    pensieve.sealingScheme,
    "cloudvault-aesgcm-v2",
    "pensieve sealingScheme must record the current CloudVault AES-GCM at-rest seal",
  );
  // Flag-OFF: the future Signal HPKE identity seal must NOT be advertised in the
  // registry until the client-side ciphertext path actually ships.
  for (const d of registry.domains) {
    assert.notEqual(
      d.sealingScheme,
      "signal-hpke-identity-seal-v1",
      `${d.id} must not advertise the Signal at-rest scheme before the client ciphertext path ships`,
    );
  }
});

test("sealingScheme: tier invariance — declaring a sealing scheme never changes the encryption tier", () => {
  for (const d of registry.domains) {
    if (d.sealingScheme === undefined) continue;
    assert.equal(typeof d.sealingScheme, "string", `${d.id} sealingScheme must be a string when present`);
    assert.ok(d.sealingScheme.length > 0, `${d.id} sealingScheme must be non-empty when present`);
    // A domain that names a sealing scheme is, by definition, sealed at rest.
    assert.equal(
      d.encryptionTier,
      "end_to_end",
      `${d.id} declares a sealingScheme but is not end_to_end — a sealing scheme never weakens or changes the tier`,
    );
  }
});

test("sealingScheme: self-encryption guard — only end_to_end domains may carry a scheme", () => {
  const scheme = registry.domains.filter((d) => d.sealingScheme !== undefined).map((d) => d.id);
  const e2e = new Set(registry.domains.filter((d) => d.encryptionTier === "end_to_end").map((d) => d.id));
  for (const id of scheme) {
    assert.ok(
      e2e.has(id),
      `${id} carries a sealingScheme but is not one of the end_to_end domains — block signalifying a non-E2E domain`,
    );
  }
});

// Producer-coverage honesty: the at-rest gate is keyed by DOMAIN id but producers are
// per-collection. signalSealedCollections records the EXACT subset of a domain's
// firestorePaths that actually emit a signalEnvelope, so the registry can never silently
// over-claim that an unwired collection is Signal-sealed. (Mirrors the parity guard.)
test("signalSealedCollections: when present, is a non-empty subset of firestorePaths", () => {
  for (const d of registry.domains) {
    if (d.signalSealedCollections === undefined) continue;
    assert.ok(Array.isArray(d.signalSealedCollections), `${d.id} signalSealedCollections must be an array`);
    assert.ok(d.signalSealedCollections.length > 0, `${d.id} signalSealedCollections must be non-empty when present`);
    const paths = new Set(d.firestorePaths ?? []);
    for (const c of d.signalSealedCollections) {
      assert.ok(paths.has(c), `${d.id} signalSealedCollections lists "${c}" which is not in firestorePaths`);
    }
  }
});

test("signalSealedCollections: conversations_chat declares exactly the wired+proven producer set", () => {
  const cc = registry.domains.find((d) => d.id === "conversations_chat");
  assert.ok(cc, "expected the conversations_chat domain");
  assert.deepEqual(
    [...(cc.signalSealedCollections ?? [])].sort(),
    ["chat_threads", "cli_agent_mission_requests", "conversations", "mobile_assistant_chats"],
    "conversations_chat must document the 4 collections that actually have Signal producers (the other 6 paths stay legacy-only)",
  );
});

test("signalSealedCollections: every domain carrying the Signal scheme must declare it", () => {
  for (const d of registry.domains) {
    if (d.sealingScheme === "signal-hpke-identity-seal-v1") {
      assert.ok(
        Array.isArray(d.signalSealedCollections) && d.signalSealedCollections.length > 0,
        `${d.id} carries the Signal scheme but does not declare signalSealedCollections — the activation would over-claim coverage`,
      );
    }
  }
});

test("sealingScheme: NON-WEBSITED — the scheme codename never reaches the public trust surface", () => {
  const trust = emitWebsiteTrust(registry, loadTierColors());
  // The field key and every scheme value must be absent from the generated
  // public trust module — burnbar.ai speaks the tier language only.
  assert.ok(!/sealingScheme/.test(trust), "trust.generated.ts must not contain the sealingScheme field");
  for (const d of registry.domains) {
    if (d.sealingScheme === undefined) continue;
    assert.ok(
      !trust.includes(d.sealingScheme),
      `trust.generated.ts must not leak the sealing scheme codename "${d.sealingScheme}"`,
    );
  }
});
