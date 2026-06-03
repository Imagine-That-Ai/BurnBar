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

  // 3. Chat is server-readable and must NEVER be labeled end-to-end. Find the
  //    conversations_chat block in the generated source and assert on it.
  const chat = registry.domains.find((d) => d.id === "conversations_chat");
  assert.equal(chat.encryptionTier, "server_readable", "chat must stay server-readable in the registry");
  const chatBlock = trust.slice(trust.indexOf('"id": "conversations_chat"'), trust.indexOf('"id": "session_logs"'));
  assert.ok(chatBlock.length > 0, "expected a conversations_chat block in the generated trust module");
  assert.ok(!/end-to-end/i.test(chatBlock), "chat must never be labeled end-to-end on the public site");
  assert.ok(/server can read/i.test(chatBlock), "chat must say the server can read the mirrored text");
});
