/**
 * @fileoverview Promotional campaign redemption core: code canonicalization,
 * code digests, campaign eligibility rules, and Firestore document paths.
 *
 * Pure functions only — no Firestore access, no clock reads — so every
 * redemption rule is unit-testable without an emulator. The callable
 * (`functions/src/callables/promoRedemption.ts`) owns all I/O and the
 * entitlement write.
 *
 * Trust model: a promotional grant is an *unverified* entitlement source. It
 * carries no provider receipt, so it must never overwrite a provider-verified
 * subscription (see `paidEntitlementWriteWouldDowngrade`), and a later verified
 * purchase always supersedes it.
 *
 * Storage split (both collections are server-only; clients never read them):
 * - `promo_campaigns/{campaignId}` — the grant policy: what tier, how long,
 *   how many redemptions, which window. Stable id, safe to reference in docs.
 * - `promo_codes/{codeDigest}` — the rotatable secret mapping. Keyed by digest
 *   so redemption is a single point-read: no query, no composite index, and the
 *   plaintext code never lands in Firestore. Rotation = write a new digest doc
 *   and deactivate the old one; the campaign (and every grant it made) is
 *   untouched.
 */

import { createHash } from "node:crypto";

import { isRecord, numberField, stringField } from "./guards.js";

/** Server-only collection holding one policy document per campaign. */
const PROMO_CAMPAIGNS_COLLECTION = "promo_campaigns";

/** Server-only collection mapping a code digest to its campaign. */
const PROMO_CODES_COLLECTION = "promo_codes";

/** Schema version stamped on campaign, code, and redemption documents. */
export const PROMO_SCHEMA_VERSION = 1;

/**
 * `source` written onto entitlement documents minted by a promo redemption.
 * Distinct from every provider-verified source so support, analytics, and the
 * entitlement write guards can tell a campaign grant from a paid receipt.
 */
export const PROMO_ENTITLEMENT_SOURCE = "promo_campaign_grant";

/** Shortest / longest accepted code, measured after canonicalization. */
const MIN_CODE_LENGTH = 4;
const MAX_CODE_LENGTH = 64;

/**
 * Canonicalizes a user-supplied code: strips every non-alphanumeric character
 * and uppercases the rest, matching `pairingCodeDigest` in `hermes.ts`.
 *
 * This makes `XOPEN-ULTRA`, `xopen ultra`, and `xopenultra` the same code, so a
 * campaign works whether it is typed by hand, pasted with the hyphen, or
 * arrives through a one-click `?code=` link.
 *
 * Returns `undefined` when the input is not a string or falls outside the
 * length bounds, so callers reject it without a Firestore read.
 */
export function canonicalizePromoCode(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const canonical = raw.replace(/[^A-Za-z0-9]/g, "").toUpperCase();
  if (canonical.length < MIN_CODE_LENGTH || canonical.length > MAX_CODE_LENGTH) return undefined;
  return canonical;
}

/**
 * SHA-256 digest (hex) of a canonicalized code, used as the
 * `promo_codes/{codeDigest}` document id.
 *
 * The digest is a lookup key, not a password hash: campaign codes are public
 * marketing strings (printed in the launch post), so stretching would buy
 * nothing. What it does buy is that an operator reading Firestore, a backup, or
 * a log line never sees the live code, and rotation never has to rewrite the
 * campaign document.
 */
export function promoCodeDigest(canonicalCode: string): string {
  return createHash("sha256").update(canonicalCode).digest("hex");
}

/** `promo_campaigns/{campaignId}` */
export function promoCampaignDocPath(campaignID: string): string {
  return `${PROMO_CAMPAIGNS_COLLECTION}/${campaignID}`;
}

/** `promo_codes/{codeDigest}` */
export function promoCodeDocPath(codeDigest: string): string {
  return `${PROMO_CODES_COLLECTION}/${codeDigest}`;
}

/**
 * `promo_campaigns/{campaignId}/redemptions/{uid}` — the one-per-uid ledger.
 * Keying by uid (rather than an auto-id) makes "already redeemed" a document
 * existence check inside the redemption transaction, so a double-submit or a
 * retried callable cannot mint two grants or double-count the cap.
 */
export function promoRedemptionDocPath(campaignID: string, uid: string): string {
  return `${promoCampaignDocPath(campaignID)}/redemptions/${uid}`;
}

/**
 * Why a redemption attempt was refused. A closed union so the callable maps
 * each case to a distinct HttpsError code and the landing page can show copy
 * that tells the visitor what to actually do next.
 */
export type PromoRejectionReason =
  | "unknown_code" | "code_disabled" | "campaign_missing" | "campaign_inactive"
  | "campaign_not_started" | "campaign_ended" | "campaign_exhausted";

/** Either a validated value or the reason the stored document was refused. */
type PromoResolution<T> = { ok: true; value: T } | { ok: false; reason: PromoRejectionReason };

/**
 * The validated slice of a campaign policy a redemption acts on.
 *
 * Deliberately not the raw Firestore document: the stored shapes
 * (`promo_campaigns/*`, `promo_codes/*`) stay module-private so no caller can
 * assert its way past validation, and every field here has been range- and
 * type-checked by {@link resolvePromoCampaign}.
 */
interface PromoGrantPlan {
  campaignID: string;
  entitlementID: string;
  productID: string;
  grantExpiresAtMillis: number;
  label?: string;
}

/**
 * Validates a `promo_codes/{digest}` document read.
 *
 * Takes `unknown` and checks every field, because a Firestore read is untrusted
 * input like any other: the collection is server-only today, but a type
 * assertion here would silently trust whatever a future writer (or a restored
 * backup) put in the document.
 *
 * A rotated-out code reports `code_disabled` rather than masquerading as a dead
 * campaign — the operator needs to tell those apart when a visitor reports a
 * code that "stopped working".
 */
export function resolvePromoCode(raw: unknown): PromoResolution<{ campaignID: string }> {
  if (!isRecord(raw)) return { ok: false, reason: "unknown_code" };
  if (raw.active !== true) return { ok: false, reason: "code_disabled" };
  const campaignID = stringField(raw, "campaignID");
  if (!campaignID) return { ok: false, reason: "campaign_missing" };
  return { ok: true, value: { campaignID } };
}

/**
 * Validates a `promo_campaigns/{id}` document read and checks it is redeemable
 * at `nowMillis`. The clock is injected rather than read so the window and
 * exhaustion rules are testable without faking time.
 *
 * Run again inside the redemption transaction against freshly read data, so a
 * campaign disabled or exhausted mid-flight cannot be raced through.
 *
 * A campaign missing any field needed to mint an entitlement is refused rather
 * than defaulted: guessing a tier or an expiry would grant the wrong thing.
 */
export function resolvePromoCampaign(
  raw: unknown,
  options: { nowMillis: number },
): PromoResolution<PromoGrantPlan> {
  if (!isRecord(raw)) return { ok: false, reason: "campaign_missing" };
  if (raw.active !== true) return { ok: false, reason: "campaign_inactive" };

  const { nowMillis } = options;
  const startsAtMillis = numberField(raw, "startsAtMillis");
  if (startsAtMillis !== undefined && nowMillis < startsAtMillis) {
    return { ok: false, reason: "campaign_not_started" };
  }
  const endsAtMillis = numberField(raw, "endsAtMillis");
  if (endsAtMillis !== undefined && nowMillis >= endsAtMillis) {
    return { ok: false, reason: "campaign_ended" };
  }
  const maxRedemptions = numberField(raw, "maxRedemptions");
  if (maxRedemptions !== undefined && (numberField(raw, "redemptionCount") ?? 0) >= maxRedemptions) {
    return { ok: false, reason: "campaign_exhausted" };
  }

  const campaignID = stringField(raw, "campaignID");
  const entitlementID = stringField(raw, "entitlementID");
  const productID = stringField(raw, "productID");
  const grantExpiresAtMillis = numberField(raw, "grantExpiresAtMillis");
  if (!campaignID || !entitlementID || !productID || grantExpiresAtMillis === undefined) {
    return { ok: false, reason: "campaign_missing" };
  }
  return {
    ok: true,
    value: { campaignID, entitlementID, productID, grantExpiresAtMillis, label: stringField(raw, "label") },
  };
}

/**
 * Operator-facing message per rejection reason. Deliberately free of internal
 * identifiers (campaign ids, digests, collection names): this text reaches an
 * anonymous visitor on a public landing page.
 */
export function promoRejectionMessage(reason: PromoRejectionReason): string {
  switch (reason) {
    case "unknown_code":
    case "code_disabled":
      return "That code isn't valid. Check the code and try again.";
    case "campaign_missing":
    case "campaign_inactive":
      return "This offer is no longer available.";
    case "campaign_not_started":
      return "This offer hasn't opened yet. Try again shortly.";
    case "campaign_ended":
      return "This offer has ended.";
    case "campaign_exhausted":
      return "This offer has been fully claimed.";
  }
}
