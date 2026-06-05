import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { DATA_DOMAIN_PATHS, isSealedEnvelope, sealAwareSerializeDoc } from "../callables/dataExport.js";
import { UNDELETABLE_DOMAINS } from "../callables/dataDeletion.js";
import {
  HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION,
  HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
  HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
  type GatewaySignalAtRestKeyDeliveryDoc,
  type GatewaySignalEnvelopeDoc,
} from "../hermesGateway.js";

// vitest runs from the functions/ package root; the registry is a sibling package.
const registry = JSON.parse(
  readFileSync(join(process.cwd(), "..", "packages", "data-domains", "registry.json"), "utf8"),
) as {
  domains: Array<{
    id: string;
    encryptionTier: string;
    firestorePaths: string[];
    storagePaths: string[];
    actions: string[];
  }>;
};
const registryIds = registry.domains.map((d) => d.id).sort();

describe("DATA_DOMAIN_PATHS ⇄ data-domain registry (no drift)", () => {
  it("covers exactly the registry's domain ids", () => {
    expect(Object.keys(DATA_DOMAIN_PATHS).sort()).toEqual(registryIds);
  });

  it("encryptionTier matches the registry for every domain", () => {
    for (const domain of registry.domains) {
      expect(DATA_DOMAIN_PATHS[domain.id].encryptionTier, `${domain.id} tier`).toBe(domain.encryptionTier);
    }
  });

  it("firestoreCollections match the registry's firestorePaths top-level collections", () => {
    for (const domain of registry.domains) {
      const expected = domain.firestorePaths.map((p) => p.split("/")[0]).sort();
      const actual = [...DATA_DOMAIN_PATHS[domain.id].firestoreCollections].sort();
      expect(actual, `${domain.id} collections`).toEqual(expected);
    }
  });

  it("storagePrefixes are the prefix-before-wildcard of the registry's storagePaths", () => {
    for (const domain of registry.domains) {
      const expected = domain.storagePaths
        .map((p) => {
          const idx = p.indexOf("/{");
          const slash = p.indexOf("/**");
          const cut = [idx, slash].filter((n) => n >= 0).sort((a, b) => a - b)[0];
          return cut == null || cut < 0 ? p.replace(/\/$/, "") : p.slice(0, cut);
        })
        .sort();
      const actual = [...DATA_DOMAIN_PATHS[domain.id].storagePrefixes].sort();
      expect(actual, `${domain.id} storage prefixes`).toEqual(expected);
    }
  });
});

describe("deleteDomainData deletability gate", () => {
  it("every domain that exposes a registry `delete` action is deletable here", () => {
    for (const domain of registry.domains) {
      if (domain.actions.includes("delete")) {
        expect(UNDELETABLE_DOMAINS.has(domain.id), `${domain.id} should be deletable`).toBe(false);
      }
    }
  });

  it("every undeletable domain is a real registry domain", () => {
    for (const id of UNDELETABLE_DOMAINS) {
      expect(registryIds, `${id} is a registry domain`).toContain(id);
    }
  });

  it("domains without a `delete` action are blocked from generic deletion", () => {
    for (const domain of registry.domains) {
      if (!domain.actions.includes("delete")) {
        expect(UNDELETABLE_DOMAINS.has(domain.id), `${domain.id} should be undeletable`).toBe(true);
      }
    }
  });
});

// privacy-leak-remediation-2026-06-02 §5: the inline-export of end_to_end /
// zero_access domains must never carry a plaintext private field.
const sealedText = {
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  nonce: "bm9uY2U=",
  ciphertext: "Y2lwaGVy",
  tag: "dGFn",
};
const sealedBlob = {
  schemaVersion: 2,
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  plaintextHMAC: "a".repeat(64),
  integrityHashVersion: 1,
  sealedBoxBase64: "Ym94",
  createdAt: "2026-06-02T00:00:00.000Z",
  aad: "OpenBurnBar-CloudVault-aad-v2|userA|project_memory_snapshots|pm_fixture|sealedSnapshot|2|sealedSnapshot",
};

// gateway-e2e Wave 4: the sealed Hermes gateway relay envelope (HermesRelayCrypto
// p256-hkdf-sha256-aesgcm) carries only opaque base64 ciphertext + wrapped key.
const relayEnvelope = {
  payloadCiphertext: "Y2lwaGVydGV4dA==",
  wrappedKey: "BAQEd3JhcHBlZA==",
  relayEncryption: "p256-hkdf-sha256-aesgcm",
  relayKeyVersion: 1,
};

const relayEnvelopeV3 = {
  payloadCiphertext: "Y2lwaGVydGV4dA==",
  wrappedKey: "d3JhcHBlZA==",
  enc: "ZW5j",
  relayEncryption: "hpke-auth-p256-hkdfsha256-aes256gcm",
  relayKeyVersion: 3,
  senderPublicKey: "c2VuZGVy",
};

const ratchetEnvelope = {
  header: {
    version: 1,
    algorithm: "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM",
    sessionID: "session-alpha",
    senderDeviceID: "agent-device",
    receiverDeviceID: "phone-device",
    ratchetPublicKeyBase64: "BAQEd3JhcHBlZA==",
    previousChainLength: 0,
    messageNumber: 0,
    epoch: 0,
  },
  ciphertextBase64: "Y2lwaGVydGV4dA==",
};

const signalTransportEnvelope: GatewaySignalEnvelopeDoc = {
  signalEnvelopeFormatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  mode: "transport",
  relayKeyVersion: HERMES_GATEWAY_SIGNAL_RELAY_KEY_VERSION,
  relayEncryption: HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
  ciphertextLayer: {
    payloadCiphertextB64: "Y2lwaGVydGV4dA==",
    payloadAADLabel: "gatewayEvent",
    schemaVersion: 2,
  },
  keyDelivery: {
    scheme: HERMES_GATEWAY_SIGNAL_TRANSPORT_ENCRYPTION,
    signalMessageType: 3,
    signalMessageB64: "cHJla2V5LW1lc3NhZ2U=",
    senderIdentityKeyId: "agent-signal-identity",
    ratchetEpochHint: 1,
  },
  binding: {
    uid: "user_1",
    scope: "gateway",
    clientId: "client-1",
    slotId: "evt_signal_1",
    mode: "transport",
    formatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  },
};

const signalAtRestEnvelope: GatewaySignalEnvelopeDoc = {
  signalEnvelopeFormatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  mode: "at-rest",
  relayEncryption: HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION,
  ciphertextLayer: {
    payloadCiphertextB64: "Y2xvdWR2YXVsdC1jaXBoZXJ0ZXh0",
    payloadAADLabel: "cloudVault",
    schemaVersion: 2,
  },
  keyDelivery: {
    scheme: HERMES_GATEWAY_SIGNAL_AT_REST_ENCRYPTION,
    wraps: [
      {
        recipientKind: "device",
        recipientIdentityKeyId: "device-signal-identity",
        recipientIdentityKeyB64: "aWRlbnRpdHkta2V5",
        sealedContentKeyB64: "c2VhbGVkLWNvbnRlbnQta2V5",
      },
    ],
    contentKeyLength: 32,
  },
  binding: {
    uid: "user_1",
    scope: "cloudvault",
    collection: "cloud_search_knowledge",
    docId: "doc-1",
    field: "signalEnvelope",
    mode: "at-rest",
    formatVersion: HERMES_GATEWAY_SIGNAL_ENVELOPE_FORMAT_VERSION,
  },
};
const signalAtRestKeyDelivery = signalAtRestEnvelope.keyDelivery as GatewaySignalAtRestKeyDeliveryDoc;

describe("isSealedEnvelope structural detection", () => {
  it("detects AES-256-GCM text + blob envelopes regardless of key name", () => {
    expect(isSealedEnvelope(sealedText)).toBe(true);
    expect(isSealedEnvelope(sealedBlob)).toBe(true);
  });

  it("detects the Hermes gateway relay envelope (v2 and HPKE v3)", () => {
    expect(isSealedEnvelope(relayEnvelope)).toBe(true);
    expect(isSealedEnvelope(relayEnvelopeV3)).toBe(true);
    // missing wrappedKey → not a complete envelope
    expect(isSealedEnvelope({ relayEncryption: "p256-hkdf-sha256-aesgcm", payloadCiphertext: "x" })).toBe(false);
    expect(
      isSealedEnvelope({
        relayEncryption: "hpke-auth-p256-hkdfsha256-aes256gcm",
        payloadCiphertext: "x",
        wrappedKey: "y",
      }),
    ).toBe(false);
    // wrong algorithm constant → not recognized
    expect(isSealedEnvelope({ relayEncryption: "rot13", payloadCiphertext: "x", wrappedKey: "y" })).toBe(false);
  });

  it("detects the Hermes gateway ratchet envelope", () => {
    expect(isSealedEnvelope(ratchetEnvelope)).toBe(true);
    expect(isSealedEnvelope({ ...ratchetEnvelope, ciphertextBase64: undefined })).toBe(false);
    expect(isSealedEnvelope({ ...ratchetEnvelope, header: { ...ratchetEnvelope.header, version: 2 } })).toBe(false);
  });

  it("detects future official-libsignal transport and at-rest envelopes", () => {
    expect(isSealedEnvelope(signalTransportEnvelope)).toBe(true);
    expect(isSealedEnvelope(signalAtRestEnvelope)).toBe(true);
    expect(isSealedEnvelope({ ...signalTransportEnvelope, relayKeyVersion: 3 })).toBe(false);
    expect(
      isSealedEnvelope({
        ...signalAtRestEnvelope,
        keyDelivery: { ...signalAtRestEnvelope.keyDelivery, wraps: [] },
      }),
    ).toBe(false);
  });

  it("rejects plaintext, partial envelopes, arrays, and scalars", () => {
    expect(isSealedEnvelope("a project name")).toBe(false);
    expect(isSealedEnvelope({ algorithm: "AES-256-GCM", nonce: "x" })).toBe(false);
    expect(isSealedEnvelope({ ciphertext: "x", tag: "y", nonce: "z" })).toBe(false);
    expect(isSealedEnvelope([sealedText])).toBe(false);
    expect(isSealedEnvelope(42)).toBe(false);
    expect(isSealedEnvelope(null)).toBe(false);
  });
});

describe("sealAwareSerializeDoc seals gateway / media / subscription content", () => {
  it("emits a sealed gateway event doc as routing metadata + relayEnvelope, drops plaintext text", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      // sealed payload sub-object (HermesRelayCrypto)
      relayEnvelope,
      // routing-only opaque metadata — emitted
      sequence: 7,
      kind: "user_message",
      destinationId: "dest-1",
      schemaVersion: 2,
      // any plaintext that a legacy/misbehaving writer left behind MUST be dropped
      text: "the secret prompt",
      senderDisplayName: "Alberto",
      threadId: "thread-99",
    });
    expect(out.relayEnvelope).toEqual(relayEnvelope);
    expect(out.sequence).toBe(7);
    expect(out.kind).toBe("user_message");
    expect(out.schemaVersion).toBe(2);
    for (const leaked of ["text", "senderDisplayName", "threadId", "destinationId"]) {
      expect(out, `${leaked} must be dropped`).not.toHaveProperty(leaked);
      expect(dropped, `${leaked} must be reported`).toContain(leaked);
    }
  });

  it("sanitizes nested legacy hash-oracle fields before exporting sealed envelopes", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      sealedSnapshot: {
        ...sealedBlob,
        plaintextSHA256: "e".repeat(64),
        plaintext: "secret transcript",
      },
      relayEnvelope: {
        ...relayEnvelopeV3,
        plaintext: "secret prompt",
      },
    });

    expect(out.sealedSnapshot).not.toHaveProperty("plaintextSHA256");
    expect(out.sealedSnapshot).not.toHaveProperty("plaintext");
    expect(out.sealedSnapshot).toHaveProperty("plaintextHMAC", "a".repeat(64));
    expect(out.relayEnvelope).toEqual(relayEnvelopeV3);
    expect(dropped).toContain("sealedSnapshot.plaintextSHA256");
    expect(dropped).toContain("sealedSnapshot.plaintext");
    expect(dropped).toContain("relayEnvelope.plaintext");
  });

  it("emits a ratchet-sealed gateway event doc as routing metadata + ratchetEnvelope", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      ratchetEnvelope,
      sequence: 8,
      kind: "user_message",
      schemaVersion: 2,
      text: "the secret prompt",
      senderDisplayName: "Alberto",
      threadId: "thread-99",
    });
    expect(out.ratchetEnvelope).toEqual(ratchetEnvelope);
    expect(out.sequence).toBe(8);
    expect(out.kind).toBe("user_message");
    expect(out.schemaVersion).toBe(2);
    for (const leaked of ["text", "senderDisplayName", "threadId"]) {
      expect(out, `${leaked} must be dropped`).not.toHaveProperty(leaked);
      expect(dropped, `${leaked} must be reported`).toContain(leaked);
    }
  });

  it("emits future Signal envelopes opaquely and strips nested plaintext junk", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      signalEnvelope: {
        ...signalTransportEnvelope,
        plaintext: "secret prompt",
        ciphertextLayer: {
          ...signalTransportEnvelope.ciphertextLayer,
          plaintextAAD: "OpenBurnBar-HermesRelay-v1|secret",
        },
        keyDelivery: {
          ...signalTransportEnvelope.keyDelivery,
          decryptedContentKey: "secret key",
        },
        binding: {
          ...signalTransportEnvelope.binding,
          privateThreadName: "Project Atlas",
        },
      },
      signalAtRestEnvelope: {
        ...signalAtRestEnvelope,
        keyDelivery: {
          ...signalAtRestEnvelope.keyDelivery,
          wraps: [
            {
              ...signalAtRestKeyDelivery.wraps[0],
              privateDeviceName: "Alberto's Mac",
            },
          ],
        },
      },
      sequence: 9,
      schemaVersion: 2,
      text: "the secret prompt",
    });

    expect(out.signalEnvelope).toEqual(signalTransportEnvelope);
    expect(out.signalAtRestEnvelope).toEqual(signalAtRestEnvelope);
    expect(out).not.toHaveProperty("text");
    expect(dropped).toContain("signalEnvelope.plaintext");
    expect(dropped).toContain("signalEnvelope.ciphertextLayer.plaintextAAD");
    expect(dropped).toContain("signalEnvelope.keyDelivery.decryptedContentKey");
    expect(dropped).toContain("signalEnvelope.binding.privateThreadName");
    expect(dropped).toContain("signalAtRestEnvelope.keyDelivery.wraps.0.privateDeviceName");
    expect(dropped).toContain("text");
  });

  it("emits a sealed media manifest as sealedFilename + opaque columns, drops plaintext filename", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      sealedFilename: sealedText,
      blobHash: "d".repeat(64),
      mime: "image/png",
      size: 4096,
      peerDeviceIdHash: "e".repeat(64),
      direction: "iosToMac",
      schemaVersion: 1,
      filename: "vacation-photos.zip", // legacy plaintext — must be dropped
    });
    expect(out.sealedFilename).toEqual(sealedText);
    expect(out.blobHash).toBe("d".repeat(64));
    expect(out.mime).toBe("image/png");
    expect(out.direction).toBe("iosToMac");
    expect(out).not.toHaveProperty("filename");
    expect(dropped).toContain("filename");
  });

  it("emits sealed subscription agentURI/topicID, drops cleartext graph identity", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      sealedAgentURI: sealedText,
      sealedTopicID: sealedText,
      consentGivenAt: { toDate: () => new Date("2026-06-03T00:00:00.000Z") },
      agentURI: "agent://example.com/coolbot", // cleartext graph — must be dropped
      topicID: "releases",
    });
    expect(out.sealedAgentURI).toEqual(sealedText);
    expect(out.sealedTopicID).toEqual(sealedText);
    expect(out.consentGivenAt).toBe("2026-06-03T00:00:00.000Z");
    expect(out).not.toHaveProperty("agentURI");
    expect(out).not.toHaveProperty("topicID");
    expect(dropped).toContain("agentURI");
    expect(dropped).toContain("topicID");
  });
});

describe("sealAwareSerializeDoc default-deny allowlist", () => {
  it("drops cleartext title/path/name/slug, keeps sealed envelopes + opaque columns", () => {
    const { out, dropped } = sealAwareSerializeDoc({
      // cleartext private fields that MUST be redacted
      repoFullName: "openburnbar/secret-repo",
      projectDisplayName: "Project Atlas",
      sourcePath: "/Users/alberto/secret/runbook.md",
      title: "merge the gateway rewrite",
      inferredTaskTitle: "fix the leak",
      // sealed envelopes (keyed by arbitrary names) — emitted verbatim
      sealedSnapshot: sealedBlob,
      sealedProjectName: sealedText,
      // opaque crypto columns — emitted
      slugHmac: "f".repeat(64),
      dedupHash: "a".repeat(64),
      repoMatchToken: "b".repeat(64),
      docID: "pm_0123456789abcdef0123456789abcdef",
      projectKeyHash: "c".repeat(32),
      embeddingModelVersion: "bge-small-en-v1.5",
      // content-free scalars — emitted
      byteCount: 128,
      chunkIndex: 0,
      schemaVersion: 2,
      isEnabled: true,
    });

    // No cleartext private field survives.
    for (const leaked of ["repoFullName", "projectDisplayName", "sourcePath", "title", "inferredTaskTitle"]) {
      expect(out, `${leaked} must be dropped`).not.toHaveProperty(leaked);
      expect(dropped, `${leaked} must be reported`).toContain(leaked);
    }
    // Sealed envelopes + opaque columns + scalars are preserved.
    expect(out.sealedSnapshot).toEqual(sealedBlob);
    expect(out.sealedProjectName).toEqual(sealedText);
    expect(out.slugHmac).toBe("f".repeat(64));
    expect(out.repoMatchToken).toBe("b".repeat(64));
    expect(out.docID).toBe("pm_0123456789abcdef0123456789abcdef");
    expect(out.byteCount).toBe(128);
    expect(out.schemaVersion).toBe(2);
    expect(out.isEnabled).toBe(true);
  });

  it("redacts legacy raw body/content hashes unless sibling versions mark them keyed", () => {
    const legacy = sealAwareSerializeDoc({
      bodyHash: "a".repeat(64),
      bodyHashVersion: 1,
      contentHash: "b".repeat(64),
      contentHashVersion: 0,
      storagePath: `users/u/session_logs/doc-1/bodies/${"a".repeat(64)}.json.aesgcm`,
      sealedTitle: sealedText,
    });

    expect(legacy.out).not.toHaveProperty("bodyHash");
    expect(legacy.out).not.toHaveProperty("contentHash");
    expect(legacy.out).not.toHaveProperty("storagePath");
    expect(legacy.out.bodyHashVersion).toBe(1);
    expect(legacy.out.contentHashVersion).toBe(0);
    expect(legacy.dropped).toContain("bodyHash");
    expect(legacy.dropped).toContain("contentHash");
    expect(legacy.dropped).toContain("storagePath");

    const keyed = sealAwareSerializeDoc({
      bodyHash: "c".repeat(64),
      bodyHashVersion: 2,
      contentHash: "d".repeat(64),
      contentHashVersion: 2,
      storagePath: `users/u/session_logs/doc-2/bodies/${"c".repeat(64)}.json.aesgcm`,
    });

    expect(keyed.out.bodyHash).toBe("c".repeat(64));
    expect(keyed.out.contentHash).toBe("d".repeat(64));
    expect(keyed.out.storagePath).toBe(`users/u/session_logs/doc-2/bodies/${"c".repeat(64)}.json.aesgcm`);
    expect(keyed.dropped).not.toContain("bodyHash");
    expect(keyed.dropped).not.toContain("contentHash");
    expect(keyed.dropped).not.toContain("storagePath");
  });

  it("serializes Firestore Timestamps to ISO and keeps them", () => {
    const ts = { toDate: () => new Date("2026-06-02T12:00:00.000Z") };
    const { out, dropped } = sealAwareSerializeDoc({ updatedAt: ts, label: "Personal budget" });
    expect(out.updatedAt).toBe("2026-06-02T12:00:00.000Z");
    expect(out).not.toHaveProperty("label");
    expect(dropped).toContain("label");
  });
});
