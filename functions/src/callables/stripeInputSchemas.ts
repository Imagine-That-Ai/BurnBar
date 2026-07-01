/**
 * @fileoverview Declared input schemas for the Stripe / Google Play billing
 * callables in `stripe.ts`.
 *
 * Kept beside the callables (mirroring the existing `subscriptionCheckoutSelection`
 * helper) so `stripe.ts` stays within its size budget and the payload contracts
 * live in one auditable place. Each parser is built on
 * {@link parseCallableInput} and reproduces, field for field, the bounds the
 * callables previously enforced by hand — so the client-visible
 * `invalid-argument` error contract does not drift.
 */

import { optionalString, parseCallableInput, requiredString } from "../validation/callableSchema.js";

/** Cloud Pro top-up verifier payload — both fields required. */
export function parseGooglePlayTopUpInput(data: unknown): { purchaseToken: string; productID: string } {
  return parseCallableInput(
    "verifyGooglePlayCloudProTopUp",
    {
      purchaseToken: requiredString({ maxLength: 4096 }),
      productID: requiredString({ maxLength: 256 }),
    },
    data,
  );
}

/**
 * Play subscription verifier payload — `purchaseToken` required, `productID`
 * optional (the caller falls back to the configured default). The opt-in
 * analytics fields are read separately by the callable and are intentionally not
 * part of this security-relevant schema, so unknown keys are ignored, never
 * rejected.
 */
export function parseGooglePlayProSubscriptionInput(data: unknown): {
  purchaseToken: string;
  productID: string | undefined;
} {
  return parseCallableInput(
    "verifyGooglePlayBurnBarProSubscription",
    {
      purchaseToken: requiredString({ maxLength: 4096 }),
      productID: optionalString({ maxLength: 256 }),
    },
    data,
  );
}
