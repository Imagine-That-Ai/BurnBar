# Promotional campaign codes (operator runbook)

How to launch, monitor, rotate, pause, and retire a promotional campaign that
grants a paid BurnBar tier with no payment instrument — the mechanism behind the
free BurnBar Ultra beta claim at <https://burnbar.ai/beta>.

Related: [`docs/PROVIDERS.md`](../PROVIDERS.md) ·
[`docs/product-focus/MONETIZATION_AND_TRIAL_SPEC.md`](../product-focus/MONETIZATION_AND_TRIAL_SPEC.md)

---

## What a campaign grant is

A redemption writes a normal entitlement document — the same one a paid
subscription writes — at `users/{uid}/entitlements/{entitlementID}`, with:

| Field | Value on a promo grant |
|---|---|
| `active` | `true` |
| `productID` | the campaign's SKU, e.g. `com.openburnbar.ultra.annual.v2` |
| `expireAt` / `expiresAt` | the campaign's far-future expiry |
| `source` | `promo_campaign_grant` |
| `platform` | `web` |
| `promoCampaignID` | the campaign id |
| `externalSubscriptionID`, `purchaseTokenHash`, `transactionID` | **absent** |

Because the grant reuses the shipped Ultra SKU, every existing tier gate accepts
it unchanged: `firestore.rules` predicates, the backend `assertActive*` helpers,
the Wand fan-out cap, and the Swift/Kotlin product-ID catalogs. Ultra grants
dual-write the `burnbar_pro_max` mirror exactly as a purchase does, which is what
the hosted-quota, Floo, and Agent Control gates actually read.

**No charge is involved anywhere:** no Stripe customer or subscription, no App
Store or Play auto-renewing introductory offer, nothing to cancel. The grant
simply expires on its own date.

### How promo grants and real purchases coexist

Promotional grants and provider-verified receipts rank by **trust, not expiry**
(`functions/src/callables/shared/entitlementWriteGuards.ts`):

- A verified purchase (or an operator bridge) **always supersedes** a promo
  grant, even though the promo's far-future expiry is longer. The subscriber's
  own billing lifecycle — including cancellation — must own the document.
- A promo grant **never overwrites** a live paid entitlement. Redeeming while
  already subscribed returns `already_entitled`, leaves the subscription intact,
  and does **not** consume a redemption, so the code stays usable.
- A verified write scrubs `promoCampaignID` / `promoRedemptionID` /
  `promoGrantedAt`, so a paying subscriber never reads back as a promo claimant.

---

## Where the pieces live

| Concern | Location |
|---|---|
| Grant policy (reviewed in git) | [`config/promo-campaigns.json`](../../config/promo-campaigns.json) |
| Runtime source of truth | Firestore `promo_campaigns/{campaignId}` |
| Rotatable code → campaign map | Firestore `promo_codes/{sha256(code)}` |
| One-per-uid ledger | Firestore `promo_campaigns/{campaignId}/redemptions/{uid}` |
| Redemption rules (pure) | `functions/src/promoCampaigns.ts` |
| Callable | `functions/src/callables/promoRedemption.ts` (`redeemPromoCode`) |
| Claim page | `website/src/pages/beta.astro` → `/beta` |
| Operator script | [`scripts/promo/seed-promo-campaign.mjs`](../../scripts/promo/seed-promo-campaign.mjs) |

All three Firestore collections are **server-only**: no client match block
exists, so Firestore's default deny applies. Reading `promo_codes` would let
anyone enumerate live digests (for short marketing codes that is equivalent to
the codes themselves), and writing any of them would mint Ultra outside the
callable. Pinned by a regression test in `functions/scripts/test-firestore-rules.mjs`.

### Codes are never stored in plaintext

Only `sha256(canonicalized code)` reaches Firestore. Canonicalization strips
every non-alphanumeric character and uppercases the rest, so `XOPEN-ULTRA`,
`xopen ultra`, and `xopenultra` are the same code — which is what makes the
one-click `?code=` link and hand-typed entry agree.

The code string itself is public marketing copy (it is printed in the launch
post), so the digest is a lookup key, not a password hash. What it buys is that
an operator reading Firestore, a backup, or a log line never sees the live code,
and rotation never rewrites the campaign document.

---

## Launch a campaign

1. Add or confirm the campaign in `config/promo-campaigns.json` (tier, SKU,
   `grantExpiresAt`, `maxRedemptions`). This is the reviewable policy.
2. Authenticate with Application Default Credentials for the target project.
3. Seed it:

```bash
node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --project burnbar
```

Add `--dry-run` first to print what would be written without writing. Use
`--code <CODE>` to seed a code other than the config's `defaultCode`.

Re-running is idempotent: campaign policy is merged and `redemptionCount` is
never reset, so a re-seed cannot resurrect an exhausted campaign or double-grant
anyone.

4. Verify the claim path end to end on the live site before announcing: load
   `https://burnbar.ai/beta?code=<CODE>`, sign in with a test account, and
   confirm the account reads as Ultra in the app.

## Check status

```bash
node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --status
```

Prints `active`, `redemptionCount`, `maxRedemptions`, and the grant expiry.

## Rotate the code

A rotation issues a new code and retires the old one. Existing grants are
untouched — rotation changes who can still claim, never who already claimed.

```bash
node scripts/promo/seed-promo-campaign.mjs \
  --campaign xopen-ultra --code NEWCODE-2026 --deactivate-code XOPEN-ULTRA
```

Update the announcement link (`/beta?code=NEWCODE-2026`) at the same time.

## Pause / resume

```bash
node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --pause
node scripts/promo/seed-promo-campaign.mjs --campaign xopen-ultra --resume
```

A pause takes effect on the next redemption attempt — no deploy, no rollout ring.
Claimants who already redeemed keep their entitlement.

## Retire a campaign

Pause it, then leave the ledger in place. The redemption subcollection is the
audit trail of who claimed what; deleting it would let previous claimants redeem
again if the campaign were ever resumed.

---

## Abuse controls

| Control | Bound |
|---|---|
| Auth | Firebase Auth required; uid comes from `request.auth.uid` only |
| App Check + high-risk nonce | Same attested sequence as `completeCliLink` |
| Wrong-code lockout | 5 failures / 15 min (`promo_redeem_fail`) |
| Redemption volume | 5 / min burst, 30 / day per uid |
| One grant per uid | `redemptions/{uid}` ledger, checked in the transaction |
| Campaign cap | `maxRedemptions`, incremented transactionally |

A malformed code is charged against the lockout budget too, so an attacker
cannot infer the code shape from which inputs are rejected before lookup.

---

## Failure modes

| Symptom | Cause | Action |
|---|---|---|
| `not-found` "code isn't valid" | Unknown or rotated-out code | Confirm the announced code matches a seeded digest (`--status`, then re-seed) |
| `failed-precondition` "no longer available" | Campaign paused or missing | `--resume`, or re-seed |
| `resource-exhausted` "fully claimed" | `maxRedemptions` reached | Raise the cap in config and re-seed, or let it close |
| `resource-exhausted` "too many attempts" | Per-uid rate limit | Expected; the visitor retries in a few minutes |
| Claim succeeds but the app still shows Free | Client cache, not entitlement | Confirm the doc at `users/{uid}/entitlements/burnbar_ultra`; have the user sign out and back in |
| `already_entitled` | Account already has a paid subscription for that tier | Working as designed — the subscription is preserved and the code was not consumed |

---

## Porting the mechanism to another product

Nothing in the redemption path is BurnBar-specific: the target entitlement
document and SKU are read off the campaign document, so standing up a second
offer — even on a different tier — is a seeding operation. That property is
asserted by the "a second campaign grants a different tier with no code change"
case in `functions/scripts/test-promo-redemption.mjs`, which writes a second
campaign on a different entitlement doc and SKU and redeems it without touching
the callable.

**If the other product shares this Firebase project**, there is no port at all:
add a campaign entry to `config/promo-campaigns.json` naming that product's
entitlement doc id and SKU, then seed it. No new code, no new callable, no rules
change.

**If the other product has its own backend**, the port is:

| Bring across | Why |
|---|---|
| `functions/src/promoCampaigns.ts` | Pure rules — canonicalization, digest, eligibility, paths. Product-agnostic as written. |
| `functions/src/callables/promoRedemption.ts` | The callable. Its only product coupling is the entitlement writer it calls. |
| The two trust-ranking rules in `entitlementWriteGuards.ts` | Without them a real purchase cannot supersede a promo grant, and a promo grant will erase a live subscription. **Do not skip these.** |
| Rate-limit actions (`promo_redeem_burst` / `_daily` / `_fail`) | Wrong-code lockout and volume bounds. |
| The server-only rules block + its regression test | Otherwise clients can enumerate code digests or mint a campaign. |
| `scripts/promo/seed-promo-campaign.mjs` | Operator surface; only the collection paths are shared. |
| `website/src/pages/beta.astro` + the per-path hosting headers | Claim page. Keep the "already subscribed" branch so paying users are not told a code was applied. |

Wire the callable to whatever that product's equivalent of
`writeBurnBarProEntitlement` is — the one requirement is that it writes an
entitlement document that product's own gates already accept, so the grant needs
no client change.

## Tests

| Surface | Command |
|---|---|
| Redemption rules + guard ranking (unit) | `npx vitest run src/__tests__/promoCampaigns.test.ts --prefix functions` |
| Full flow against a real Firestore | `npm run test:promo-redemption --prefix functions` |
| Server-only collections | `npm run test:firestore-rules --prefix functions` |
| Claim page source contract | `npm run test:beta-claim --prefix website` |

`test:promo-redemption` runs the shipped redemption logic and the shipped
entitlement writer against the Firestore emulator, seeding through this
runbook's own script — so the documented operator path is under test, not just
the callable.
