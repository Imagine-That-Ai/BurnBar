import assert from "node:assert/strict";
import test from "node:test";

import {
  createDomainCoreOpaqueIdentifierAdapterForTest,
  pensieveDedupHash,
  pensieveProvenanceHash,
  pensieveSlugHmac,
  type DomainCoreOpaqueIdentifierModule,
  type DomainCoreOpaqueIdentifierReceipt,
} from "./domainCoreOpaqueIdentifiers.js";

const MODE = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE";
const KEY = Buffer.from(Array.from({ length: 32 }, (_, index) => index));
const SOURCE_A = "a".repeat(64);
const SOURCE_B = "b".repeat(64);
const WASM_SHA = "c".repeat(64);

const receipt: DomainCoreOpaqueIdentifierReceipt = {
  schemaVersion: 1,
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: SOURCE_A,
  wasmSha256: WASM_SHA,
};

function testModule(overrides: Partial<DomainCoreOpaqueIdentifierModule> = {}): DomainCoreOpaqueIdentifierModule {
  return {
    cloudVaultPensieveDedupHash: () => "rust-result",
    cloudVaultPensieveProvenanceHash: () => "rust-result",
    cloudVaultPensieveSlugHmac: () => "rust-result",
    domainCoreAbiVersion: () => 3,
    domainCoreSourceFingerprint: () => SOURCE_A,
    domainCoreVersion: () => "0.1.0",
    ...overrides,
  };
}

function withMode<T>(value: string | undefined, operation: () => T): T {
  const previous = process.env[MODE];
  if (value === undefined) {
    delete process.env[MODE];
  } else {
    process.env[MODE] = value;
  }
  try {
    return operation();
  } finally {
    if (previous === undefined) {
      delete process.env[MODE];
    } else {
      process.env[MODE] = previous;
    }
  }
}

test("Rust opaque-identifier operations match the cross-language vectors", () => {
  withMode("rust", () => {
    assert.equal(
      pensieveDedupHash("deploy the daemon before midnight", KEY, () => "legacy"),
      "e55f699579cba539fb8f3a87c77bd768a95e331859c9fca9c89d21dac0c6d433",
    );
    assert.equal(
      pensieveSlugHmac("burnbar-docs-secret-runbook", KEY, () => "legacy"),
      "f77ecba2eaa6012fb4a6846d8fd218b61a04094cad346683f029e1636da7a96d",
    );
    assert.equal(
      pensieveProvenanceHash("source:burnbar", KEY, () => "legacy"),
      "4f069319dcb12b868983bc04992c7871f3682c4b107a9e0bbfb8348fcbd8fc4e",
    );
  });
});

test("legacy mode remains a path-addressable rollback", () => {
  withMode("legacy", () => {
    assert.equal(pensieveDedupHash("value", KEY, () => "legacy-result"), "legacy-result");
  });
});

test("Rust authority fails closed on invalid vault keys", () => {
  withMode("rust", () => {
    assert.throws(
      () => pensieveSlugHmac("slug", Buffer.alloc(31), () => "legacy-result"),
      /invalid_key_length|exactly 32 bytes/i,
    );
  });
});

test("Rust authority rejects same-ABI module substitution with the wrong source", () => {
  const adapter = createDomainCoreOpaqueIdentifierAdapterForTest("rust", {
    module: testModule({ domainCoreSourceFingerprint: () => SOURCE_B }),
    receipt,
    sourceFingerprint: SOURCE_A,
    wasmSha256: WASM_SHA,
  });
  assert.throws(
    () => adapter.pensieveDedupHash("private-input", KEY, () => "legacy-result"),
    /identity mismatch/,
  );
});

test("shadow mismatch records only the operation and category", () => {
  const warnings: string[] = [];
  const adapter = createDomainCoreOpaqueIdentifierAdapterForTest("shadow", {
    module: testModule(),
    receipt,
    sourceFingerprint: SOURCE_A,
    wasmSha256: WASM_SHA,
  }, (message) => warnings.push(message));
  assert.equal(
    adapter.pensieveDedupHash("private-input", KEY, () => "legacy-result"),
    "legacy-result",
  );
  assert.deepEqual(warnings, [
    "domain_core.cloudvault.shadow_mismatch operation=pensieve_dedup_hash core=abi3",
  ]);
  assert.equal(warnings[0].includes("private-input"), false);
});

test("shadow native errors fall back without logging inputs", () => {
  const warnings: string[] = [];
  const adapter = createDomainCoreOpaqueIdentifierAdapterForTest("shadow", {
    module: testModule({
      cloudVaultPensieveProvenanceHash: () => { throw new Error("private-input"); },
    }),
    receipt,
    sourceFingerprint: SOURCE_A,
    wasmSha256: WASM_SHA,
  }, (message) => warnings.push(message));
  assert.equal(
    adapter.pensieveProvenanceHash("private-input", KEY, () => "legacy-result"),
    "legacy-result",
  );
  assert.deepEqual(warnings, [
    "domain_core.cloudvault.native_error operation=pensieve_provenance_hash core=abi3",
  ]);
  assert.equal(warnings[0].includes("private-input"), false);
});
