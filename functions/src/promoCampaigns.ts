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

/** Server-only collection holding one policy document per campaign. */
export const PROMO_CAMPAIGNS_COLLECTION = "promo_campaigns";

/** Server-only collection mapping a code digest to its campaign. */
export const PROMO_CODES_COLLECTION = "promo_codes";

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

/** Policy document stored at `promo_campaigns/{campaignId}`. */
export interface PromoCampaignDoc {
  /** Stable campaign id; mirrors the document id. */
  campaignID: string;
  /** Operator-facing label, e.g. "X launch — free BurnBar Ultra beta". */
  label?: string;
  /** Master switch. A false/missing value disables redemption immediately. */
  active: boolean;
  /** Entitlement document id to write, e.g. `burnbar_ultra`. */
  entitlementID: string;
  /** Product id stamped on the granted entitlement. */
  productID: string;
  /** Epoch millis the granted entitlement expires (far-future for the beta). */
  grantExpiresAtMillis: number;
  /** Redemption window open (epoch millis). Optional — defaults to always open. */
  startsAtMillis?: number;
  /** Redemption window close (epoch millis). Optional — defaults to never closing. */
  endsAtMillis?: number;
  /** Hard ceiling on total redemptions. Optional — defaults to uncapped. */
  maxRedemptions?: number;
  /** Redemptions granted so far; incremented in the redemption transaction. */
  redemptionCount?: number;
  schemaVersion?: number;
}

/** Mapping document stored at `promo_codes/{codeDigest}`. */
export interface PromoCodeDoc {
  campaignID: string;
  active: boolean;
  /** Operator-facing hint (never the code itself), e.g. "rotation 1". */
  label?: string;
  schemaVersion?: number;
}

/**
 * Why a redemption attempt was refused. Kept as a closed union so the callable
 * maps each case to a distinct HttpsError code and the landing page can show
 * copy that tells the visitor what to actually do next.
 */
export type PromoRejectionReason =
  | "unknown_code"
  | "code_disabled"
  | "campaign_missing"
  | "campaign_inactive"
  | "campaign_not_started"
  | "campaign_ended"
  | "campaign_exhausted";

export type PromoEligibility = { ok: true } | { ok: false; reason: PromoRejectionReason };

/**
 * Validates the code mapping document. Split from campaign evaluation so a
 * rotated-out code reports `code_disabled` rather than masquerading as a dead
 * campaign — the operator needs to tell those apart when a visitor reports a
 * code that "stopped working".
 */
export function evaluatePromoCode(code: PromoCodeDoc | undefined): PromoEligibility {
  if (!code) return { ok: false, reason: "unknown_code" };
  if (code.active !== true) return { ok: false, reason: "code_disabled" };
  if (typeof code.campaignID !== "string" || code.campaignID.length === 0) {
    return { ok: false, reason: "campaign_missing" };
  }
  return { ok: true };
}

/**
 * Validates campaign state at `nowMillis`. The clock is injected rather than
 * read so window and exhaustion rules are testable without faking time.
 *
 * Evaluated again inside the redemption transaction against freshly read data,
 * so a campaign that is disabled or exhausted mid-flight cannot be raced.
 */
export function evaluatePromoCampaign(
  campaign: PromoCampaignDoc | undefined,
  options: { nowMillis: number },
): PromoEligibility {
  if (!campaign) return { ok: false, reason: "campaign_missing" };
  if (campaign.active !== true) return { ok: false, reason: "campaign_inactive" };

  const { nowMillis } = options;
  if (typeof campaign.startsAtMillis === "number" && nowMillis < campaign.startsAtMillis) {
    return { ok: false, reason: "campaign_not_started" };
  }
  if (typeof campaign.endsAtMillis === "number" && nowMillis >= campaign.endsAtMillis) {
    return { ok: false, reason: "campaign_ended" };
  }
  if (typeof campaign.maxRedemptions === "number") {
    const redeemed = typeof campaign.redemptionCount === "number" ? campaign.redemptionCount : 0;
    if (redeemed >= campaign.maxRedemptions) return { ok: false, reason: "campaign_exhausted" };
  }
  return { ok: true };
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
