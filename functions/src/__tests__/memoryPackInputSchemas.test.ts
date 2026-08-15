import { describe, expect, it } from "vitest";

import {
  parseCreateMemoryPackCheckoutInput,
  parseRedeemAppleMemoryPackInput,
  parseRedeemPlayMemoryPackInput,
} from "../callables/memoryPackInputSchemas.js";

describe("Memory Boost callable input schemas", () => {
  it("parses checkout, Play redeem, and Apple redeem payloads", () => {
    expect(
      parseCreateMemoryPackCheckoutInput({
        packId: "text_1m",
        successUrl: "https://burnbar.ai/account",
        cancelUrl: "https://burnbar.ai/account",
        attemptId: "a1",
      }),
    ).toEqual({
      packId: "text_1m",
      successUrl: "https://burnbar.ai/account",
      cancelUrl: "https://burnbar.ai/account",
      attemptId: "a1",
    });
    expect(
      parseRedeemPlayMemoryPackInput({
        purchaseToken: "play-token",
        productID: "com.openburnbar.memory.boost.text.1m",
      }),
    ).toEqual({
      purchaseToken: "play-token",
      productID: "com.openburnbar.memory.boost.text.1m",
    });
    expect(
      parseRedeemAppleMemoryPackInput({
        signedTransactionJWS: "header.payload.sig",
        productID: "com.openburnbar.memory.boost.vision.1m",
      }),
    ).toEqual({
      signedTransactionJWS: "header.payload.sig",
      productID: "com.openburnbar.memory.boost.vision.1m",
    });
  });

  it("rejects unknown packs and missing redeem fields", () => {
    expect(() =>
      parseCreateMemoryPackCheckoutInput({
        packId: "text_99m",
        successUrl: "https://burnbar.ai/account",
        cancelUrl: "https://burnbar.ai/account",
      }),
    ).toThrow();
    expect(() => parseRedeemPlayMemoryPackInput({})).toThrow();
    expect(() => parseRedeemAppleMemoryPackInput({})).toThrow();
  });
});
