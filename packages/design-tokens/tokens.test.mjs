import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const read = (p) => readFileSync(join(HERE, p), "utf8");

// `npm test` runs `node config.mjs` first, so dist/ is fresh here.
const css = read("dist/css/pensieve.css");
const swift = read("dist/swift/PensieveTokens.swift");
const kotlin = read("dist/compose/PensieveTokens.kt");

test("CSS exposes the Pensieve + brand tokens as :root custom properties", () => {
  for (const v of [
    "--color-mercury-bright: #f4f6fb",
    "--color-seal-crimson: #c5221f",
    "--color-tier-end-to-end: #3cd6c0",
    "--color-tier-server-readable: #fdc42c",
    "--font-display: Outfit",
    "--space-4: 16px",
    "--radius-pill: 999px",
  ]) {
    assert.ok(css.includes(v), `CSS missing token: ${v}`);
  }
  assert.ok(css.includes(":root"), "CSS must scope to :root");
});

test("Swift + Kotlin emit the same tokens with resolved values (no undefined)", () => {
  assert.ok(!swift.includes("undefined"), "Swift has an unresolved token");
  assert.ok(!kotlin.includes("undefined"), "Kotlin has an unresolved token");
  assert.ok(swift.includes('colorMercuryBright: String = "#f4f6fb"'));
  assert.ok(kotlin.includes('colorMercuryBright: String = "#f4f6fb"'));
  assert.ok(swift.includes("enum PensieveTokens"));
  assert.ok(kotlin.includes("object PensieveTokens"));
});

test("all three platforms emit the same token count (one source of truth)", () => {
  const cssCount = (css.match(/^\s*--[a-z0-9-]+:/gim) || []).length;
  const swiftCount = (swift.match(/static let /g) || []).length;
  const kotlinCount = (kotlin.match(/const val /g) || []).length;
  assert.equal(swiftCount, kotlinCount, "swift vs kotlin token count drift");
  assert.equal(cssCount, swiftCount, "css vs swift token count drift");
  assert.ok(cssCount >= 40, `expected >=40 tokens, got ${cssCount}`);
});

// Android keeps an in-tree copy of the generated Compose tokens (synced by the
// `:app:syncGeneratedSources` Gradle task) because a module can't reference
// files outside itself. CI must catch any drift between that copy and the
// freshly-built dist output, the same way registry.test.mjs guards DataDomains.kt.
test("android in-tree PensieveTokens.kt matches generated Compose output (run ./gradlew :app:syncGeneratedSources)", () => {
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
    "ui",
    "tokens",
    "PensieveTokens.kt"
  );
  const onDisk = readFileSync(androidPath, "utf8");
  assert.equal(
    onDisk,
    kotlin,
    "android PensieveTokens.kt is stale — run ./gradlew :app:syncGeneratedSources (Compose design tokens must equal the generated output byte-for-byte)"
  );
});

test("encryption-tier colors are distinct (legible tier badges)", () => {
  const e2e = "#3cd6c0";
  const zero = "#8b94a8";
  const server = "#fdc42c";
  assert.notEqual(e2e, zero);
  assert.notEqual(zero, server);
  assert.notEqual(e2e, server);
  for (const c of [e2e, zero, server]) assert.ok(css.includes(c), `tier color ${c} missing from CSS`);
});
