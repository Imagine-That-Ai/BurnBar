import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: {
    increment: (value: number) => ({ __increment: value }),
    serverTimestamp: () => ({ __serverTimestamp: true }),
  },
  getFirestore: vi.fn(),
}));

vi.mock("firebase-functions/v2/firestore", () => ({
  onDocumentWritten: vi.fn((options: unknown, handler: unknown) => ({ options, handler })),
}));

vi.mock("../logging.js", () => ({ logInfo: vi.fn() }));
vi.mock("../scheduledOps.js", () => ({
  runFirestoreTrigger: vi.fn(async (_name: string, handler: () => Promise<void>) => handler()),
}));

import {
  SIGNAL_MIGRATION_COLLECTIONS,
  classifySignalMigrationProducer,
  classifySignalMigrationWrite,
  signalMigrationCounterWrite,
} from "../signalMigrationTelemetry.js";

describe("aggregate-only Signal migration telemetry", () => {
  beforeEach(() => vi.clearAllMocks());

  it("covers exactly the ten private conversations_chat collections", () => {
    expect([...SIGNAL_MIGRATION_COLLECTIONS].sort()).toEqual(
      [
        "conversations",
        "chat_threads",
        "mobile_assistant_chats",
        "cli_sessions",
        "cli_agent_mission_requests",
        "text_snippets",
        "rollback_requests",
        "approval_policies",
        "agent_identities",
        "subscription_topics",
      ].sort(),
    );
  });

  it("reduces arbitrary producer strings to four fixed buckets", () => {
    expect(classifySignalMigrationProducer({ source: "ios-hermes-square" })).toBe("ios");
    expect(classifySignalMigrationProducer({ source: "macOS-AgentLens" })).toBe("macos");
    expect(classifySignalMigrationProducer({ clientPlatform: "android" })).toBe("android");
    expect(classifySignalMigrationProducer({ source: "private-customer-project-alpha" })).toBe("unknown");
  });

  it("classifies Signal, legacy, mixed, plaintext-only, and delete writes without retaining input data", () => {
    const signal = classifySignalMigrationWrite(
      "cli_sessions",
      undefined,
      {
        uid: "secret-user-id",
        documentId: "secret-document-id",
        transcript: "top secret transcript",
        source: "macos",
        signalEnvelope: { ciphertextLayer: { payloadCiphertextB64: "opaque" } },
      },
    );
    expect(signal).toEqual({
      collection: "cli_sessions",
      producer: "macos",
      operation: "create",
      signalSealed: true,
      legacySealed: false,
      mixedEnvelope: false,
      plaintextOnly: false,
    });
    expect(JSON.stringify(signal)).not.toContain("secret");

    expect(
      classifySignalMigrationWrite("text_snippets", {}, { source: "ios", sealedExpansion: { ciphertext: "opaque" } }),
    ).toMatchObject({ signalSealed: false, legacySealed: true, mixedEnvelope: false, plaintextOnly: false });
    expect(
      classifySignalMigrationWrite("approval_policies", {}, { signalEnvelope: {}, sealedDisplayLabel: {} }),
    ).toMatchObject({ signalSealed: true, legacySealed: true, mixedEnvelope: true, plaintextOnly: false });
    expect(classifySignalMigrationWrite("agent_identities", {}, { displayName: "leaked" })).toMatchObject({
      signalSealed: false,
      legacySealed: false,
      plaintextOnly: true,
    });
    expect(classifySignalMigrationWrite("subscription_topics", {}, undefined)).toMatchObject({
      operation: "delete",
      plaintextOnly: false,
    });
  });

  it("persists a closed aggregate schema with counters only", () => {
    const write = signalMigrationCounterWrite(
      {
        collection: "rollback_requests",
        producer: "android",
        operation: "update",
        signalSealed: true,
        legacySealed: false,
        mixedEnvelope: false,
        plaintextOnly: false,
      },
      "2026-08-04",
    );

    expect(Object.keys(write).sort()).toEqual(
      [
        "schemaVersion",
        "day",
        "collection",
        "producer",
        "totalWrites",
        "createWrites",
        "updateWrites",
        "deleteWrites",
        "signalSealedWrites",
        "legacySealedWrites",
        "mixedEnvelopeWrites",
        "plaintextOnlyWrites",
        "lastObservedAt",
      ].sort(),
    );
    expect(write).toMatchObject({
      schemaVersion: 1,
      day: "2026-08-04",
      collection: "rollback_requests",
      producer: "android",
      totalWrites: { __increment: 1 },
      createWrites: { __increment: 0 },
      updateWrites: { __increment: 1 },
      deleteWrites: { __increment: 0 },
      signalSealedWrites: { __increment: 1 },
      legacySealedWrites: { __increment: 0 },
      mixedEnvelopeWrites: { __increment: 0 },
      plaintextOnlyWrites: { __increment: 0 },
      lastObservedAt: { __serverTimestamp: true },
    });
    for (const forbidden of ["uid", "userId", "documentId", "path", "hash", "payload", "ciphertext"]) {
      expect(write).not.toHaveProperty(forbidden);
    }
  });
});
