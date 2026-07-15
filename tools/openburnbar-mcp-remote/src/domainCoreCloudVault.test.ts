import assert from "node:assert/strict";
import test from "node:test";

import {
  createDomainCoreCloudVaultAdapterForTest,
  domainCoreAesGcmOpenCombined,
  domainCoreAesGcmSealCombined,
  domainCoreCloudVaultAADContext,
  domainCoreCloudVaultSearch,
  domainCorePensieveDeterministicEmbedAndCloak,
  domainCorePensieveVectorCloak,
  type DomainCoreCloudVaultModule,
  type DomainCoreCloudVaultReceipt,
} from "./domainCoreCloudVault.js";
import {
  legacyAesGcmOpenCombined,
  legacyAesGcmSealCombined,
  legacyCloudVaultAADContext,
  legacyCloudVaultSemanticHashes,
  legacyCloudVaultTokenHashes,
} from "./legacy/cloudVaultLegacy.js";
import {
  legacyCloakVector,
  legacyDeterministicEmbed,
} from "./legacy/pensieveVectorLegacy.js";

const MODE = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE";
const SOURCE_A = "a".repeat(64);
const SOURCE_B = "b".repeat(64);
const WASM_SHA = "c".repeat(64);
const KEY = Buffer.alloc(32);
const NONCE = Buffer.alloc(12);
const AAD = Buffer.from("OpenBurnBar-CloudVault-aad-v2|user|sessions|doc|body|2|body");

const receipt: DomainCoreCloudVaultReceipt = {
  schemaVersion: 1,
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: SOURCE_A,
  wasmSha256: WASM_SHA,
};

function searchResult(hashes: string[]) {
  return {
    hashCount: hashes.length,
    hashAt: (index: number) => hashes[index],
    free: () => undefined,
  };
}

function testModule(overrides: Partial<DomainCoreCloudVaultModule> = {}): DomainCoreCloudVaultModule {
  return {
    cloudVaultAadV2: () => "rust-aad",
    cloudVaultAesGcmOpenCombined: () => Buffer.from("rust-open"),
    cloudVaultAesGcmSealCombined: () => Buffer.from("rust-seal"),
    cloudVaultSearch: () => searchResult(["rust-hash"]),
    pensieveVectorCloak: (vector) => vector,
    pensieveDeterministicEmbed: (_text, dimensions) => new Float64Array(dimensions),
    pensieveDeterministicEmbedAndCloak: (_text, dimensions) => new Float64Array(dimensions),
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

test("Rust CloudVault adapter matches canonical AAD, AES, and search vectors", () => {
  withMode("rust", () => {
    const aad = domainCoreCloudVaultAADContext(
      "user",
      "sessions",
      "doc",
      "body",
      2,
      "body",
      () => "legacy",
    );
    assert.equal(aad, AAD.toString("utf8"));

    const plaintext = Buffer.from("OpenBurnBar");
    const combined = Buffer.from(domainCoreAesGcmSealCombined(
      plaintext,
      KEY,
      NONCE,
      AAD,
      () => Buffer.from("legacy"),
    ));
    assert.equal(
      combined.toString("base64"),
      "AAAAAAAAAAAAAAAAgdclUw8VGQBFL7fp4wkz+89gQ53cRuKGgDQD",
    );
    assert.equal(
      Buffer.from(domainCoreAesGcmOpenCombined(combined, KEY, AAD, () => Buffer.from("legacy"))).toString(),
      "OpenBurnBar",
    );

    assert.deepEqual(
      domainCoreCloudVaultSearch(0, "The QUICK, quick fox and X.", Buffer.from(Array.from({ length: 32 }, (_, index) => index)), 250, () => []),
      ["e9110d7f0c79afdae6316235800dc41b", "66e59fa04825dc74f5ef7cb57884d4ed"],
    );
  });
});

test("Rust Pensieve vector adapter matches the published cross-language golden vectors", () => {
  withMode("rust", () => {
    const key = Buffer.alloc(32, 0x42);
    const basis = new Float64Array(384);
    basis[5] = 1;
    const cloaked = domainCorePensieveVectorCloak(
      basis,
      key,
      "hashing-bow-v1",
      () => legacyCloakVector(basis, key, "hashing-bow-v1"),
    );
    const expected = [
      0.024962057620774702,
      -0.0012100986493098734,
      0.01970170194431331,
      -0.01876288243402278,
      0.050834395709711204,
      0.8367944634995997,
    ];
    expected.forEach((value, index) => assert.ok(Math.abs(cloaked[index] - value) < 1e-12));

    const text = "hosted minimax encrypted session search";
    const combined = domainCorePensieveDeterministicEmbedAndCloak(
      text,
      384,
      false,
      key,
      "hashing-bow-v1",
      () => Array.from(legacyCloakVector(
        legacyDeterministicEmbed(text, 384, false), key, "hashing-bow-v1",
      )),
    );
    assert.ok(Math.abs(combined[0] - -0.06038318803677569) < 1e-12);
  });
});

test("legacy helpers preserve the remote MCP rollback behavior", () => {
  assert.equal(
    legacyCloudVaultAADContext("user", "sessions", "doc", "body"),
    AAD.toString("utf8"),
  );
  const plaintext = Buffer.from("OpenBurnBar");
  const combined = legacyAesGcmSealCombined(plaintext, KEY, NONCE, AAD);
  assert.equal(legacyAesGcmOpenCombined(combined, KEY, AAD).toString(), "OpenBurnBar");
  assert.deepEqual(
    legacyCloudVaultTokenHashes("The QUICK, quick fox and X.", Buffer.from(Array.from({ length: 32 }, (_, index) => index)), 250),
    ["e9110d7f0c79afdae6316235800dc41b", "66e59fa04825dc74f5ef7cb57884d4ed"],
  );
  assert.equal(legacyCloudVaultSemanticHashes("shared rust domain", KEY, 12).length, 12);
});

test("shadow remains legacy-authoritative and logs no input material", () => {
  const warnings: string[] = [];
  const adapter = createDomainCoreCloudVaultAdapterForTest("shadow", {
    module: testModule(),
    receipt,
    sourceFingerprint: SOURCE_A,
    wasmSha256: WASM_SHA,
  }, (message) => warnings.push(message));
  assert.equal(
    adapter.aadV2("private-user", "collection", "doc", "field", 2, "field", () => "legacy-aad"),
    "legacy-aad",
  );
  assert.deepEqual(warnings, ["domain_core.cloudvault.shadow_mismatch operation=aad_v2 core=abi3"]);
  assert.equal(warnings[0].includes("private-user"), false);
});

test("Rust authority rejects a same-ABI package with the wrong source", () => {
  const adapter = createDomainCoreCloudVaultAdapterForTest("rust", {
    module: testModule({ domainCoreSourceFingerprint: () => SOURCE_B }),
    receipt,
    sourceFingerprint: SOURCE_A,
    wasmSha256: WASM_SHA,
  });
  assert.throws(
    () => adapter.search(0, "private-query", KEY, 10, () => ["legacy"]),
    /identity mismatch/,
  );
});

test("Rust authority fails closed on AES authentication failure", () => {
  withMode("rust", () => {
    const combined = Buffer.from(domainCoreAesGcmSealCombined(
      Buffer.from("secret"),
      KEY,
      NONCE,
      AAD,
      () => Buffer.from("legacy"),
    ));
    combined[combined.length - 1] ^= 1;
    let legacyCalled = false;
    assert.throws(() => domainCoreAesGcmOpenCombined(combined, KEY, AAD, () => {
      legacyCalled = true;
      return Buffer.from("legacy");
    }));
    assert.equal(legacyCalled, false);
  });
});
