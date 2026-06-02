import { beforeEach, describe, expect, it, vi } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";

const { mockCreate, mockGet, mockDoc } = vi.hoisted(() => {
  const mockCreate = vi.fn();
  const mockGet = vi.fn();
  const mockDoc = vi.fn(() => ({
    create: mockCreate,
    get: mockGet,
  }));
  return { mockCreate, mockGet, mockDoc };
});

vi.mock("../adminRuntime.js", () => ({
  db: { doc: mockDoc },
}));

import {
  GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION,
  claimGooglePlayPurchaseToken,
} from "../callables/googlePlayTokenClaims.js";

describe("googlePlayTokenClaims", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCreate.mockResolvedValue(undefined);
    mockGet.mockResolvedValue({ get: (field: string) => (field === "uid" ? "other-uid" : undefined) });
  });

  it("uses a top-level collection path for global token binding", () => {
    const hash = "a".repeat(64);
    expect(`${GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION}/${hash}`).toBe(`google_play_token_claims/${hash}`);
  });

  it("creates a claim doc on first use", async () => {
    await claimGooglePlayPurchaseToken({
      uid: "uid-a",
      purchaseTokenHash: "hash-1",
      productID: "com.openburnbar.proMax.monthly",
      kind: "subscription",
    });
    expect(mockDoc).toHaveBeenCalledWith(`${GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION}/hash-1`);
    expect(mockCreate).toHaveBeenCalledOnce();
  });

  it("rejects the same token hash for a different uid", async () => {
    const alreadyExists = Object.assign(new Error("exists"), { code: 6 });
    mockCreate.mockRejectedValueOnce(alreadyExists);

    await expect(
      claimGooglePlayPurchaseToken({
        uid: "uid-b",
        purchaseTokenHash: "hash-2",
        productID: "com.openburnbar.proMax.monthly",
        kind: "subscription",
      }),
    ).rejects.toMatchObject({
      code: "permission-denied",
    } satisfies Partial<HttpsError>);
  });

  it("allows idempotent reclaim for the same uid", async () => {
    const alreadyExists = Object.assign(new Error("exists"), { code: 6 });
    mockCreate.mockRejectedValueOnce(alreadyExists);
    mockGet.mockResolvedValueOnce({ get: () => "uid-same" });

    await expect(
      claimGooglePlayPurchaseToken({
        uid: "uid-same",
        purchaseTokenHash: "hash-3",
        productID: "com.openburnbar.proMax.monthly",
        kind: "topup",
      }),
    ).resolves.toBeUndefined();
  });
});
