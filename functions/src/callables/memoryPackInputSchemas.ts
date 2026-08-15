import { HttpsError } from "firebase-functions/v2/https";

import { enumField, optionalString, parseCallableInput, requiredString } from "../validation/callableSchema.js";
import { MEMORY_PACK_IDS, isMemoryPackId } from "../usageCuration/catalog.js";

function requiredParsedString(value: unknown, fieldName: string): string {
  if (typeof value === "string") return value;
  throw new HttpsError("internal", `Validated callable field ${fieldName} did not parse to a string.`);
}

function optionalParsedString(value: unknown, fieldName: string): string | undefined {
  if (value === undefined || typeof value === "string") return value;
  throw new HttpsError("internal", `Validated callable field ${fieldName} did not parse to a string.`);
}

export function parseCreateMemoryPackCheckoutInput(data: unknown): {
  packId: (typeof MEMORY_PACK_IDS)[number];
  successUrl: string;
  cancelUrl: string;
  attemptId?: string;
} {
  const parsed = parseCallableInput(
    "createMemoryPackCheckoutSession",
    {
      packId: enumField([...MEMORY_PACK_IDS]),
      successUrl: requiredString({ maxLength: 2048 }),
      cancelUrl: requiredString({ maxLength: 2048 }),
      attemptId: optionalString({ maxLength: 128 }),
    },
    data,
  );
  const packId = requiredParsedString(parsed.packId, "packId");
  if (!isMemoryPackId(packId)) {
    throw new HttpsError("internal", "Validated callable field packId did not parse to a Memory Boost pack id.");
  }
  return {
    packId,
    successUrl: requiredParsedString(parsed.successUrl, "successUrl"),
    cancelUrl: requiredParsedString(parsed.cancelUrl, "cancelUrl"),
    attemptId: optionalParsedString(parsed.attemptId, "attemptId"),
  };
}

export function parseRedeemPlayMemoryPackInput(data: unknown): { purchaseToken: string; productID: string } {
  const parsed = parseCallableInput(
    "redeemPlayMemoryPack",
    {
      purchaseToken: requiredString({ maxLength: 4096 }),
      productID: requiredString({ maxLength: 256 }),
    },
    data,
  );
  return {
    purchaseToken: requiredParsedString(parsed.purchaseToken, "purchaseToken"),
    productID: requiredParsedString(parsed.productID, "productID"),
  };
}

export function parseRedeemAppleMemoryPackInput(data: unknown): {
  signedTransactionJWS: string;
  productID?: string;
} {
  const parsed = parseCallableInput(
    "redeemAppleMemoryPack",
    {
      signedTransactionJWS: requiredString({ maxLength: 16_384 }),
      productID: optionalString({ maxLength: 256 }),
    },
    data,
  );
  return {
    signedTransactionJWS: requiredParsedString(parsed.signedTransactionJWS, "signedTransactionJWS"),
    productID: optionalParsedString(parsed.productID, "productID"),
  };
}
