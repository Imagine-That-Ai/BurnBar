/**
 * BOLA negative coverage — validateOpenTimestampsProof binds auth uid to body uid.
 */
import { describe, it, vi } from "vitest";

import { BOB_UID, callableRunner, tier2CallableProof, pathKeyedFirestore } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));

vi.mock("../../auth.js", async () => {
  const actual = await vi.importActual<typeof import("../../auth.js")>("../../auth.js");
  return {
    ...actual,
    enforceAuthAndAppCheck: vi.fn(),
  };
});

export const BOLA_MANIFEST = {
  validateOpenTimestampsProof: ["validateOpenTimestampsProof rejects cross-user object access"],
} as const;

describe("BOLA — openTimestamps", () => {
  it("validateOpenTimestampsProof rejects cross-user object access", async () => {
    const mod = await import("../../computerUseOpenTimestamps.js");
    const run = callableRunner(mod.validateOpenTimestampsProof);
    await tier2CallableProof(bolaStore, {
      exportedName: "validateOpenTimestampsProof",
      run,
      payload: {
        uid: BOB_UID,
        sessionId: "bob-session",
        auditHeadHashHex: "a".repeat(64),
        proofBase64: Buffer.from("proof").toString("base64"),
      },
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });
});