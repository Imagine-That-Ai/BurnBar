import { HttpsError } from "firebase-functions/v2/https";
import { describe, expect, it } from "vitest";

import { parseGooglePlayProSubscriptionInput, parseGooglePlayTopUpInput } from "../callables/stripeInputSchemas.js";

function caughtHttpsError(action: () => unknown): HttpsError {
  try {
    action();
  } catch (error) {
    if (error instanceof HttpsError) return error;
    throw error;
  }
  throw new Error("expected an HttpsError to be thrown");
}

function expectInvalidArgument(action: () => unknown, messagePattern: RegExp): void {
  const error = caughtHttpsError(action);
  expect(error.code).toBe("invalid-argument");
  expect(error.message).toMatch(messagePattern);
}

describe("parseGooglePlayTopUpInput", () => {
  it("returns both trimmed fields when present", () => {
    expect(parseGooglePlayTopUpInput({ purchaseToken: "  tok ", productID: " com.x " })).toEqual({
      purchaseToken: "tok",
      productID: "com.x",
    });
  });

  it("requires both purchaseToken and productID (contract parity with the legacy handler)", () => {
    expectInvalidArgument(() => parseGooglePlayTopUpInput({ productID: "com.x" }), /purchaseToken is required/);
    expectInvalidArgument(() => parseGooglePlayTopUpInput({ purchaseToken: "tok" }), /productID is required/);
  });

  it("rejects an over-long purchaseToken and a non-object payload", () => {
    expectInvalidArgument(
      () => parseGooglePlayTopUpInput({ purchaseToken: "a".repeat(4097), productID: "com.x" }),
      /purchaseToken must be 4096 characters or fewer/,
    );
    expectInvalidArgument(() => parseGooglePlayTopUpInput("not-an-object"), /must be a JSON object/);
  });
});

describe("parseGooglePlayProSubscriptionInput", () => {
  it("keeps productID optional (undefined when omitted) while requiring purchaseToken", () => {
    expect(parseGooglePlayProSubscriptionInput({ purchaseToken: "tok" })).toEqual({
      purchaseToken: "tok",
      productID: undefined,
    });
    expectInvalidArgument(() => parseGooglePlayProSubscriptionInput({}), /purchaseToken is required/);
  });

  it("ignores extra keys (opt-in analytics fields are read separately)", () => {
    expect(
      parseGooglePlayProSubscriptionInput({
        purchaseToken: "tok",
        productID: "com.sub",
        analyticsConsent: "granted",
        analyticsDeviceId: "device-1",
      }),
    ).toEqual({ purchaseToken: "tok", productID: "com.sub" });
  });
});
