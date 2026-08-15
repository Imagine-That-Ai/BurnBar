# Memory Power-Up packs

Prepaid token wallets for usage-memory extraction. Packs **never** unlock a
membership tier. Fable owns extraction, consent, and metered spend. This
document is the commerce contract: catalog, wallet, and the three payment
rails.

Related: [`MEMORY_ACTIVATION.md`](MEMORY_ACTIVATION.md) (extraction gates).

## Catalog

| Pack | Lane | Tokens | List | Product ID | Stripe lookup |
|---|---|---:|---:|---|---|
| `text_1m` | text | 1,000,000 | $2.99 | `com.openburnbar.memory.boost.text.1m` | `memory_boost_text_1m` |
| `text_5m` | text | 5,000,000 | $9.99 | `com.openburnbar.memory.boost.text.5m` | `memory_boost_text_5m` |
| `vision_1m` | multimodal | 1,000,000 | $6.99 | `com.openburnbar.memory.boost.vision.1m` | `memory_boost_vision_1m` |

List prices are documentation and anti-typo floors, not what clients charge.
Clients show StoreKit / Play / Stripe localized prices. Server floors
(`minChargeMinor`) are text_1m **200**, text_5m **700**, vision_1m **500**.
Remote Config `memory_pack_catalog` may only **raise** those floors or hide a
pack. It cannot lower floors and cannot change token sizes.

Credits expire **12 months after grant**. Pending vision packs expire on that
same clock and cannot be settled afterward.

## Who can buy

- **Text packs:** any active Cloud / Cloud Pro / Ultra membership at
  *purchase intent* (Stripe checkout create). After money is taken, Apple and
  Play redeem credit even if membership lapsed — the user already paid.
- **Vision packs:** Cloud Pro or Ultra at checkout (Stripe) and at grant time.
  If entitlement lapsed between pay and grant, the pack is held `pending`.
  `writeBurnBarProEntitlement` for an active `burnbar_pro_max` / `burnbar_ultra`
  calls `settlePendingMemoryPacks(uid, true)`. Clients may also call the
  `settlePendingMemoryPacks` callable.
- Packs never unlock tiers. Spend is Fable's problem; this wallet only holds
  prepaid tokens.

## Wallet

Hot path: `users/{uid}/memoryWallet/current/grants/{entryId}`.

Cache (client-readable): `users/{uid}/memoryWallet/current` with
`textTokens`, `multimodalTokens`, `pendingTextTokens`, and
`pendingMultimodalTokens`. Always rewritten as the **sum of unexpired
remaining tokens** (pending packs counted separately) in the same
transaction. Never incremented. Clients must not treat a listener error
as a zero wallet.

Ledger (server-only): `users/{uid}/memoryWalletLedger/{entryId}`.

Fable must call `debitWallet` / `getWalletBalances` **inside the same
Firestore transaction** that meters curation spend. Replay of `reservationId`
is success. Insufficient balance throws `MemoryWalletInsufficientError` (not
`HttpsError`). FIFO by `expiresAt`. Lazy expiry runs inside that transaction.

Refunds and disputes claw back **only this grant's remaining tokens**. They
cannot steal another pack. Apple REFUND writes `refundReversedTokens` so
`REFUND_REVERSED` can restore; Play voids and Stripe full refunds that should
not come back use `reversedTokens`.

Grant IDs are `requiredIdentifier(`${source}_${transactionId}`)`. Never put
`|` in Firestore IDs.

Cap: 400 active+pending grants per wallet.

## Rails

### Stripe (Mac direct download)

`createMemoryPackCheckoutSession` asserts membership, refuses a Remote
Config-hidden pack (empty title), requires quantity 1, rejects discounts,
`allow_promotion_codes: false`, and copies `{ firebaseUID, kind, packId }` onto
both the session and `payment_intent_data.metadata`. Pass a unique `attemptId`
so two legitimate purchases in the same 10 minutes do not collapse; without it
the idempotency key buckets by 10 minutes (double-click guard).

`checkout.session.completed` records the charge/PI mapping **before** grant,
verifies the line-item price ID matches the catalog pack, refuses a missing or
non-1 quantity, refuses `amount_discount`, and enforces the anti-typo floor. Refunds resolve uid via
`stripe_memory_pack_payments/{charge_|payment_intent_}`. If that mapping is
missing, the webhook reads PI metadata + the Checkout session; a memory-pack
charge with no grant yet throws `memory_pack_grant_missing` so Stripe retries
instead of granting after a refund.

### App Store (iOS + Mac App Store)

Consumables. Client mints `appAccountToken` via `beginEntitlementBinding`,
listens `Transaction.updates` and `Transaction.unfinished`, redeems, then
`finish()`. If the grant already exists, redeem returns `alreadyGranted`
**before** requiring a fresh binding. ASN `REFUND` claws back
`refundReversedTokens`; `REFUND_REVERSED` restores. `ONE_TIME_CHARGE` may
grant when uid is resolvable. Memory-pack products never fall through to
entitlement reconcile. `CONSUMPTION_REQUEST` is logged and acknowledged; Send
Consumption Information is not implemented in this rail.

### Google Play (Android)

INAPP consumables. Grant first, then Play `consume`. Replay of an already
granted token is success, including when Play later surfaces an `orderId`
that was missing on the first redeem (the existing grant is reused; a second
grant is not created). RTDN one-time void and voided-purchase notifications
call `reverseVoidedMemoryPack`, never Cloud Pro top-up reversal. Unclaimed
one-time voids nack with `memory_pack_grant_missing` so Pub/Sub retries until
the redeem path writes the token claim. Subscription voids stay ignored when
unclaimed.

## Store consoles

Created 2026-08-15 on the shipping catalogs. Product IDs are the commercial
contract; Stripe **price** IDs are environment-specific.

| Pack | Apple / Play product ID | Stripe lookup | Live price | Test price |
|---|---|---|---|---|
| `text_1m` | `com.openburnbar.memory.boost.text.1m` | `memory_boost_text_1m` | `price_1U4g9eCFamvUJU7yggtdq5rb` | `price_1U4g9fCFamvUJU7yq7rySoze` |
| `text_5m` | `com.openburnbar.memory.boost.text.5m` | `memory_boost_text_5m` | `price_1U4g9fCFamvUJU7yRdgAwFPq` | `price_1U4g9fCFamvUJU7yazxd3zK6` |
| `vision_1m` | `com.openburnbar.memory.boost.vision.1m` | `memory_boost_vision_1m` | `price_1U4g9gCFamvUJU7ynPctZb7B` | `price_1U4g9gCFamvUJU7yeAMiQTwJ` |

- **Stripe:** one-time USD prices on lookup keys above. Live IDs live in
  `functions/.env.burnbar.production`; test IDs in
  `functions/.env.burnbar-staging`. Checkout stays fail-closed until Functions
  is deployed with those files. Re-run:
  `STRIPE_SECRET_KEY="$(firebase functions:secrets:access STRIPE_SECRET_KEY --project burnbar)" node tools/stripe/prepare-memory-boost-prices.mjs --apply --write-env`
  (use `burnbar-staging` for test mode).
- **App Store Connect:** consumables on app `6766366964`
  (`com.openburnbar.app`). Metadata, USA price, availability, and review
  screenshots are applied by `tools/app-store-connect/prepare-commercial-iaps.js --apply`
  plus `upload-cu-review-screenshot.js --top-ups-only --apply`. Submitted for
  review 2026-08-15 (`WAITING_FOR_REVIEW`). Apple still has to approve; no
  extra console click unless review rejects.
- **Google Play:** INAPP one-time products on `com.openburnbar`, purchase
  option `buy`, **ACTIVE** at $2.99 / $9.99 / $6.99. Re-run
  `tools/google-play/prepare-commercial-iaps.mjs --apply`. License testers can
  buy immediately; production users see them once the shipping billing client
  queries the SKUs.

## Clients

Power-up UI lives on the **Cloud store**, not memory settings.

- iOS: Memory Boost tile; vision hidden unless Cloud Pro / Ultra.
- Android: same rail; Play INAPP SKUs; `redeemPlayMemoryPack`.
- Mac App Store: StoreKit consumables, same redeem callable.
- Mac direct download: Stripe Checkout opened in the browser; success/cancel
  URLs are `https://burnbar.ai/account` (the production Stripe redirect
  allowlist). The wallet listener shows pending vision tokens until Cloud Pro
  or Ultra is active.

Wallet cache is owner-read only. Grants and the ledger are server-only.

## Fable seam

Import from `functions/src/usageCuration/`:

- `getWalletBalances(txn, uid)`
- `debitWallet(txn, uid, lane, tokens, reservationId)`
- `grantMemoryPack` / `revokeGrant` / `reverseMemoryPackGrant` / `grantExists`
- `settlePendingMemoryPacks(uid, visionEligible)` — no-op when
  `visionEligible` is false
- `MemoryWalletInsufficientError`

Do **not** add a spend callable here. `wallet.ts` must not import
`entitlements.ts`.
