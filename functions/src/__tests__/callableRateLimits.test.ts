import { beforeEach, describe, expect, it, vi } from "vitest";

import { ALICE_UID, pathKeyedFirestore } from "./bola/callableBolaHarness.js";

const mocks = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
}));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(mocks.store),
  };
});

vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));

import {
  checkAgentNotificationReplyRateLimit,
  checkKnowledgeSearchRateLimit,
  checkVoIPCallRateLimit,
  isPublicRateLimitExceeded,
} from "../callables/publicRateLimit.js";

describe("checkVoIPCallRateLimit", () => {
  beforeEach(() => {
    mocks.store.clear();
  });

  it("allows a short burst and rejects the 21st request for a uid", async () => {
    for (let i = 0; i < 20; i += 1) {
      await expect(checkVoIPCallRateLimit(ALICE_UID)).resolves.toBeUndefined();
    }

    try {
      await checkVoIPCallRateLimit(ALICE_UID);
      expect.fail("expected voip call rate limit to reject");
    } catch (error) {
      expect(isPublicRateLimitExceeded(error)).toBe(true);
      expect(error).toMatchObject({ code: "resource-exhausted" });
    }
  });
});

describe("checkKnowledgeSearchRateLimit", () => {
  beforeEach(() => {
    mocks.store.clear();
  });

  it("allows a short burst and rejects the 31st request for a uid", async () => {
    for (let i = 0; i < 30; i += 1) {
      await expect(checkKnowledgeSearchRateLimit(ALICE_UID)).resolves.toBeUndefined();
    }

    try {
      await checkKnowledgeSearchRateLimit(ALICE_UID);
      expect.fail("expected knowledge search rate limit to reject");
    } catch (error) {
      expect(isPublicRateLimitExceeded(error)).toBe(true);
      expect(error).toMatchObject({ code: "resource-exhausted" });
    }
  });
});

describe("checkAgentNotificationReplyRateLimit", () => {
  beforeEach(() => {
    mocks.store.clear();
  });

  it("allows a short burst and rejects the 31st request for a uid", async () => {
    for (let i = 0; i < 30; i += 1) {
      await expect(checkAgentNotificationReplyRateLimit(ALICE_UID)).resolves.toBeUndefined();
    }

    try {
      await checkAgentNotificationReplyRateLimit(ALICE_UID);
      expect.fail("expected agent notification reply rate limit to reject");
    } catch (error) {
      expect(isPublicRateLimitExceeded(error)).toBe(true);
      expect(error).toMatchObject({ code: "resource-exhausted" });
    }
  });
});