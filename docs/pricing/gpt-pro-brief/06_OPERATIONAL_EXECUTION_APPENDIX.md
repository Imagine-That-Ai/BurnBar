# 06 — Operational Execution Appendix (agent-executable layer)

> **Document 6 of 6.** Docs 1–5 are strategy + economics. **This doc is the execution layer**: the real current launch state, the exact commands, config keys, SKU ids, channel-by-channel steps, the master launch gate, and — most importantly — **the delta required to ship *two* tiers vs. today's single-SKU launch machinery**.
>
> Everything here is extracted verbatim from the repo's runbooks, `scripts/commercial-launch-gate.mjs`, `functions/src/config.ts`, the App Store Connect runbook, and the macOS release runbook as of **2026-05-30**. Where a value must still be created/decided, it is marked **⚠️ TODO**.
>
> **Owner-type tags** on every step so a coding agent and a computer-use agent know who runs what:
> `[CA]` = coding-agent (shell/code/deploy) · `[CU]` = computer-use-agent (browser/desktop GUI) · `[H]` = human-required (identity/payment/legal/irreversible).

---

## 1. Current launch state (truth as of 2026-05-30)

| Surface | State | Evidence |
|---|---|---|
| **macOS app** | Direct-download notarized DMG/ZIP pipeline live (R2 bucket `openburnbar-downloads`, host `downloads.burnbar.ai`); MAS sandboxed build passed readiness gates, **pending Apple review** | `docs/RELEASE_MACOS.md` |
| **iOS app** | `1.0`, build `16`, **`WAITING_FOR_REVIEW`** (resubmitted 2026-05-18). Apple app id **`6766366964`**, bundle `com.openburnbar.app` | `docs/IOS_APP_STORE_RELEASE_RUNBOOK.md` |
| **First subscription** | `Hosted Quota Sync Monthly` (`com.openburnbar.hostedQuotaSync.cloud.monthly`, **$4.99**, subscription id `6768773163`), **`WAITING_FOR_REVIEW`** with review screenshot | same |
| **Apple S2S webhook** | Live: `https://us-central1-burnbar.cloudfunctions.net/appStoreServerNotificationsV2` | same |
| **Apple billing env** | Functions default `APP_STORE_ENV=Sandbox` — **one config flip to Production** | `config.ts:124` |
| **Stripe** | Fully coded (`createStripeBurnBarProCheckoutSession`/`Portal`/`Webhook`); `STRIPE_BURNBAR_PRO_PRICE_ID` **empty → not yet live** | `config.ts:92`, `callables/stripe.ts:69` |
| **Google Play** | Coded (`verifyGooglePlayBurnBarProSubscription`, package `com.openburnbar`, product `com.openburnbar.pro.monthly`); **needs published app** | `config.ts:96–101` |
| **Website** | Live on Firebase Hosting (`burnbar.ai`); pricing page shows the **single** $4.99 tier | `website/src/data/site.ts:18` |
| **App Check** | SDK shipped; **Firestore enforcement must be flipped ON in console** before paid users | `docs/FIREBASE_APP_CHECK_ENFORCEMENT.md` |
| **Cost kill-switches** | Coded + Remote-Config-driven; verify production Remote Config values are set | Doc 3 §8 |
| **Billing alerts** | Policy definitions exist; deploy with `npm --prefix functions run alerts:billing` | `docs/PAID_SCALE_FIREBASE_RUNBOOK.md` |

**Net:** the single-SKU ($4.99 Hosted Quota Sync) launch is ~one Apple approval + production hardening away from live. **The two-tier launch is a *superset* of that** — it reuses all this machinery and adds the second tier's products, the second entitlement wiring, and a pricing-page rewrite (§7).

---

## 2. The master Definition of Done — `scripts/commercial-launch-gate.mjs`

This **read-only** script is the canonical launch gate. It prints one verdict: `WAITING_ON_APPLE` → `READY_FOR_MANUAL_RELEASE` → `READY_FOR_LIVE_PAID_PROOF` → (or `NO_GO`). Run it from a clean `origin/main` checkout. `[CA]`

```bash
scripts/commercial-launch-gate.mjs
# capture evidence (timestamped JSON under launch-evidence/, gitignored):
scripts/capture-commercial-launch-evidence.mjs
```

It hard-checks ALL of the following — **each is a launch task** with an objective acceptance test built in:

| Gate check | Pass condition |
|---|---|
| `repo` | HEAD == origin/main, working tree clean |
| `appStore` | iOS state ∈ {WAITING_FOR_REVIEW, PENDING_DEVELOPER_RELEASE, READY_FOR_SALE}; releaseType MANUAL; build VALID + APP_STORE_ELIGIBLE + non-exempt-encryption false; subscription productId matches |
| `appStoreServerNotifications` | Sandbox `delivered:true` always; Production `delivered:true` once live |
| `firebaseAppCheck` | `firestore.googleapis.com` enforcementMode == **ENFORCED** |
| `branchProtection` | admins enforced, no force-push/delete, 1 review, required checks include `openburnbar-pr` + 3 CodeQL jobs |
| `githubSecurity` | Dependabot + secret-scanning (6 settings) enabled; **0 open** code-scanning/secret/Dependabot alerts |
| `mainRequiredGate` / `mainCodeQL` / `latestMergedPrGate` | required checks green on origin/main + last merged PR |
| `cloudRun` | `openburnbar-quota-runner` Ready; **retired `hermes-realtime-relay` absent** |
| `runnerReadyz` | quota-runner `/readyz` returns 200 |
| `redis` | retired `hermes-realtime-relay-redis-prod-secure` **absent** |
| `hostedQuotaRuntime` | required functions have `ENFORCE_APP_CHECK=true`, `HOSTED_QUOTA_DAILY_REFRESH_LIMIT=30`, `HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT=300`, `HOSTED_QUOTA_PRODUCT_ID` set; runner URL https; `HOSTED_QUOTA_RUNNER_TOKEN` + `RUNNER_SHARED_SECRET` secrets present |
| `billingAlerts` | all `BILLING_ALERT_POLICIES` present (exactly 1 each), enabled, with notification channels, watching the right metrics |
| `firebaseFunctionsInventory` | 14 required functions present; forbidden `syncHostedQuotaEntitlement` absent |

> **⚠️ Two-tier note:** the gate currently hardcodes `PRODUCT_ID = "com.openburnbar.hostedQuotaSync.cloud.monthly"` and checks `subscription.productId === PRODUCT_ID`. **To gate a two-tier launch, this constant/check must be generalized** to accept the two new products (§5). This is a required `[CA]` code change in the plan.

---

## 3. Config & environment reference (`functions/src/config.ts`)

All keys, their env var, and default. Set via `firebase functions:config:set` or function env / Secret Manager.

| Setting | Env var | Default | Action for launch |
|---|---|---|---|
| App Check enforce | `ENFORCE_APP_CHECK` | `true` | keep true; also flip console enforcement (§6.1) |
| Hosted quota product | `HOSTED_QUOTA_PRODUCT_ID` | `com.openburnbar.hostedQuotaSync.cloud.monthly` | keep (Tier-1 legacy) |
| BurnBar Pro product | `BURNBAR_PRO_PRODUCT_ID` | `com.openburnbar.pro.monthly` | **Tier 1** product |
| **Stripe price id** | `STRIPE_BURNBAR_PRO_PRICE_ID` | `""` | **⚠️ TODO: set** (Tier 1 web) |
| Stripe secret | `STRIPE_SECRET_KEY` | `""` (secret) | **⚠️ TODO: set** |
| Stripe webhook secret | `STRIPE_WEBHOOK_SECRET` | `""` (secret) | **⚠️ TODO: set** |
| Google Play package | `GOOGLE_PLAY_PACKAGE_NAME` | `com.openburnbar` | keep |
| Google Play product | `GOOGLE_PLAY_SUBSCRIPTION_PRODUCT_ID` | `com.openburnbar.pro.monthly` | keep (Tier 1) |
| Quota daily cap | `HOSTED_QUOTA_DAILY_REFRESH_LIMIT` | `30` | keep (gate requires 30) |
| Quota monthly cap | `HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT` | `300` | keep (gate requires 300) |
| Runner URL | `HOSTED_QUOTA_RUNNER_URL` | `""` | set to https quota-runner URL |
| Runner token | `HOSTED_QUOTA_RUNNER_TOKEN` | `""` (secret) | set |
| Encrypted blob cap | `ENCRYPTED_SESSION_BLOB_MAX_BYTES` | `10485760` (10 MB) | keep |
| Apple env | `APP_STORE_ENV` | `Sandbox` | **flip to `Production` at go-live** |
| Apple numeric app id | `APP_STORE_APPLE_APP_ID` | unset | **set to `6766366964`** (required for Production notification verification) |
| ASC secrets | `APP_STORE_ASC_KEY_ID` / `ISSUER_ID` / `KEY_P8` | secrets | already set |

---

## 4. SKU / entitlement reference + two-tier mapping

| Entitlement doc | Apple product id | Price (code/plan) | In which tier (recommended) |
|---|---|---|---|
| `hosted_quota_sync` | `com.openburnbar.hostedQuotaSync.cloud.monthly` | $4.99 (shipped) | **Tier 1** (grandfather these subscribers) |
| `burnbar_pro` | `com.openburnbar.pro.monthly` | $14.99 (plan) | **Tier 1** canonical |
| `hosted_media_sync` | `com.openburnbar.hostedMediaSync.monthly` | $9.99 (plan) | fold into **Tier 2** |
| `hosted_computer_use_sync` | `com.openburnbar.hostedComputerUseSync.monthly` | $14.99 (fixture) | fold into **Tier 2** |
| `burnbar_pro_max` | `com.openburnbar.proMax.monthly` | $24.99 (fixture) | **Tier 2** canonical |

**StoreKit fixtures already exist** for local testing: `OpenBurnBarMobileTests/Resources/OpenBurnBarHostedQuota.storekit` and `…/OpenBurnBarComputerUse.storekit`. They are test fixtures — **the real products must be created in App Store Connect** (§5).

**Gating logic already in code** (Doc 2 §8): `assertActiveBurnBarProEntitlement` accepts `burnbar_pro`/`hosted_quota_sync` (Group A); media gated by `hosted_media_sync`/`burnbar_pro`; Computer Use by `hosted_computer_use_sync`/`burnbar_pro_max`. → Tier 1 = `burnbar_pro`, Tier 2 = `burnbar_pro_max` requires minimal new gating.

---

## 5. The DELTA to ship TWO tiers (vs today's single-SKU launch) — the critical worklist

This is the gap between "what's already wired for $4.99" and "two clean tiers live." **Every item is a plan task.**

1. **`[H]/[CU]` App Store Connect — create the two subscription products** (+ annual variants):
   - Tier 1: `com.openburnbar.pro.monthly` (and `…pro.yearly` ⚠️ TODO id) at the price Doc 5 locks.
   - Tier 2: `com.openburnbar.proMax.monthly` (and yearly) at the Doc 5 Tier-2 price.
   - Each needs: reference name, price, localized metadata, the five Guideline-3.1.2(c) disclosure fields, App Review screenshot, legal links (`burnbar.ai/legal/terms`, `/legal/privacy-policy`).
   - **First-auto-renewable rule already satisfied** by Hosted Quota Sync, so later subscriptions can submit via API — but verify each appears in the review submission via web UI.
2. **`[CA]` StoreKit config / product ids in the app** — ensure the iOS/macOS purchase UI offers both tiers and binds the right `appAccountToken`; keep the `cloudStore.subscriptionDisclosure` block for each.
3. **`[CA]` Stripe — second price/tier:** today only ONE price is wired (`STRIPE_BURNBAR_PRO_PRICE_ID`). To sell Tier 2 on web, **add a `STRIPE_BURNBAR_PRO_MAX_PRICE_ID` config key + checkout path**, or decide Tier 2 is App-Store-only at launch. ⚠️ **decision + small code change**.
4. **`[CA]` Entitlement gating:** confirm `burnbar_pro_max` unlocks media + Computer Use everywhere (it does in fixtures; verify the reconciler writes/mirrors it like `burnbar_pro`). Add any missing `assertActive…ProMax` checks.
5. **`[CA]` Generalize `commercial-launch-gate.mjs`** `PRODUCT_ID` check to accept both new products (§2 note).
6. **`[CA]` Google Play:** add the second subscription product to Play + extend `verifyGooglePlayBurnBarProSubscription` mapping if Tier 2 ships on Android.
7. **`[CA]` Website pricing page rewrite** from one tier to two (§7).
8. **`[CA]` Grandfathering:** map existing `hosted_quota_sync` ($4.99) subscribers into Tier 1 (the reconciler already mirrors `hosted_quota_sync`→`burnbar_pro`; verify pricing/comms).
9. **`[CU]` Remote Config:** confirm the production caps for both tiers (§8).

---

## 6. Channel-by-channel execution

### 6.1 Firebase production hardening `[CA]/[CU]`
```bash
# Deploy backend (rules, indexes, functions)
firebase deploy --only firestore:rules --project burnbar          # [CA]
firebase deploy --only firestore:indexes --project burnbar        # [CA]
npm --prefix functions run deploy                                  # [CA] (firebase deploy --only functions)

# Set Stripe + runner config/secrets (examples)
firebase functions:secrets:set STRIPE_SECRET_KEY --project burnbar          # [H] (paste live key)
firebase functions:secrets:set STRIPE_WEBHOOK_SECRET --project burnbar      # [H]
firebase functions:config:set stripe.burnbar_pro_price_id="price_XXX"       # [H] from Stripe dashboard
```
- **App Check enforcement `[CU]`:** Firebase Console → App Check → review Firestore *verified* metrics → **Enforce** for **Cloud Firestore** (propagates ≤15 min). Gate then sees `ENFORCED`. (`docs/FIREBASE_APP_CHECK_ENFORCEMENT.md`)
- **Billing alerts `[CA]`:**
  ```bash
  export GCLOUD_PROJECT=burnbar
  export BILLING_ALERT_CHANNELS=projects/burnbar/notificationChannels/CHANNEL_ID   # [H] create channel first
  npm --prefix functions run alerts:billing
  ```

### 6.2 Apple App Store `[CA]` + `[CU]` + `[H]`
```bash
# Pull ASC creds from Secret Manager  [CA]
export APP_STORE_ASC_KEY_ID="$(firebase functions:secrets:access APP_STORE_ASC_KEY_ID --project burnbar)"
export APP_STORE_ASC_ISSUER_ID="$(firebase functions:secrets:access APP_STORE_ASC_ISSUER_ID --project burnbar)"
export APP_STORE_ASC_KEY_P8="$(firebase functions:secrets:access APP_STORE_ASC_KEY_P8 --project burnbar)"

npm --prefix tools/app-store-connect run status                       # [CA] readback
npm --prefix tools/app-store-connect run prepare-review-metadata      # [CA] legal links, MANUAL release, demo acct
npm --prefix tools/app-store-connect run test-server-notifications -- sandbox   # [CA] must be delivered:true
# Web-only gates (Content Rights, add-for-review, subscription attach for first sub)  [CU]
export OPENBURNBAR_SUBMIT_APP_REVIEW="ios:9"
npm --prefix tools/app-store-connect run submit-review                # [H] official Apple submission
# After approval → PENDING_DEVELOPER_RELEASE:
OPENBURNBAR_RELEASE_APPROVED_IOS="1.0:<APP_STORE_VERSION_ID>" \
  npm --prefix tools/app-store-connect run release-approved-ios       # [H] customer-facing publish
npm --prefix tools/app-store-connect run test-server-notifications -- production   # must be delivered:true
```
- Review account: `app-review@openburnbar.app` (seed via `tools/app-store-connect/seed-review-account.js`). `[CA]`
- In-app deletion path for review: **You → Settings → Account → Delete account** (record a device video, upload via `upload-review-attachment`). `[H]` capture, `[CA]` upload.

### 6.3 Stripe (web) `[H]/[CA]`
- `[H]` In Stripe dashboard: create Product(s) + recurring Price(s) for Tier 1 (and Tier 2 if web), copy `price_…` ids.
- `[CA]` Set `STRIPE_BURNBAR_PRO_PRICE_ID` (+ new `…PRO_MAX_PRICE_ID` per §5.3); deploy functions.
- `[CU]` Register the webhook endpoint `…/stripeBurnBarProWebhook` in Stripe → events `checkout.session.completed`, `customer.subscription.created/updated/deleted`; copy signing secret → `STRIPE_WEBHOOK_SECRET`.
- Acceptance: a test-mode checkout writes `users/{uid}/entitlements/burnbar_pro` `isActive:true`.

### 6.4 Google Play `[H]/[CA]/[CU]`
- `[H]/[CU]` Publish the app; create subscription product(s) matching the tier product ids; configure the service account.
- Acceptance: `verifyGooglePlayBurnBarProSubscription` returns active and writes the entitlement.

### 6.5 macOS release `[CA]`
```bash
scripts/verify-macos-app-store-readiness.sh        # MAS compile gate
scripts/build-macos-app-store-release.sh           # sandboxed MAS archive/export
scripts/build-macos-website-release.sh             # Dev ID notarized DMG/ZIP/SBOM
scripts/upload-macos-downloads-r2.sh               # publish to R2 (downloads.burnbar.ai)
scripts/tag-release.sh <version>                   # cuts the GitHub release
```

### 6.6 Website pricing page `[CA]`
```bash
npm --prefix website run build      # build with Node 22
firebase deploy --only hosting:marketing --project burnbar   # deploy with Node 24
```
- Edit copy in `website/src/data/site.ts` (`iapProductId`, `iapPriceUSD`), `faq.ts`, `capabilities.ts`. Rewrite from one tier to **two** (benefit-first names; no codename/transport jargon — Doc 1 §9).
- ⚠️ Known hazards (project memory): recurring concurrent-editor file corruption — **re-verify every edit**; `--container-narrow` token gotcha.

---

## 7. Public pricing-page content delta
Today: one tier, `$4.99`, product `com.openburnbar.hostedQuotaSync.cloud.monthly` (`site.ts:18–19`), "Free vs Cloud" + billing FAQ. **Target: Free + two paid tiers** with the names/prices Doc 5 locks, each tier's feature list (benefit-first), annual toggle, and updated FAQ (refunds, cancellation, what each tier includes, privacy/zero-knowledge messaging). Keep legal links live: `burnbar.ai/legal/terms`, `/legal/privacy-policy`, `/support`.

---

## 8. Remote Config safety knobs (production values to confirm) `[CU]`
Set/verify in Firebase Console → Remote Config (all tunable live, no redeploy — Doc 3 §8):
```json
{
  "media_cost_per_gb_usd": 0.04,
  "media_budget_soft_cap_usd": 600.0,
  "media_budget_hard_cap_usd": 1000.0,
  "media_kill_switch": false,
  "computer_use_soft_cap_usd": 1500.0,
  "computer_use_hard_cap_usd": 2500.0,
  "computer_use_kill_switch": false,
  "user_quota_daily_refresh_limit": 30,
  "user_quota_monthly_refresh_limit": 300
}
```
Abuse response: drop `user_quota_daily_refresh_limit` to `5` to halt a rogue user within 60 s. For a Tier-2 vision-COGS overrun, lower `computer_use_hard_cap_usd` or the per-user `$5/day` envelope.

---

## 9. Post-launch proof, canary & rollback
- **Live paid proof `[H]/[CA]`** (gate verdict `READY_FOR_LIVE_PAID_PROOF`): real StoreKit purchase → entitlement write → one paid backup/quota action, then:
  ```bash
  OPENBURNBAR_PROOF_UID="<FIREBASE_UID>" npm --prefix functions run prove:hosted-quota -- \
    --project burnbar --environment Production \
    --original-transaction-id "<APPLE_TXN>" --require-backup --require-hosted-quota
  # must print ok:true with the entitlement + audit + evidence paths
  ```
- **Canary `[CA]`:** watch the four billing-alert metrics (Firestore reads, storage bytes, Cloud Run request rate, retired-Redis absence) + per-tier COGS for the first window. `docs/PAID_SCALE_FIREBASE_RUNBOOK.md`.
- **Rollback `[CA]/[CU]`:** `docs/RELEASE_ROLLBACK.md`. Levers: Remote Config kill-switches (instant, no deploy), iOS release type is MANUAL (don't publish on approval until ready), function rollback via redeploy of prior build, Stripe/price disable.

---

## 10. File provenance (what to attach / where truth lives)
The `operational-attachments/` sibling folder contains copies of: `PAID_SCALE_FIREBASE_RUNBOOK.md`, `IOS_APP_STORE_RELEASE_RUNBOOK.md`, `RELEASE_MACOS.md`, `RELEASE_ROLLBACK.md`, `FIREBASE_APP_CHECK_ENFORCEMENT.md`, `HOSTED_QUOTA_SYNC.md`, `functions/src/callables/stripe.ts`, `functions/src/config.ts`, `scripts/commercial-launch-gate.mjs`, `website/CLAIMS.md`, `website/src/data/{site,faq,capabilities}.ts`, and the two `.storekit` fixtures. **Attaching this Doc 6 alone is enough for GPT Pro to plan the execution; attach the `operational-attachments/` files only if you want the executing agents to quote exact file bodies.**

---

## 11. Launch-readiness checklist (objective DoD)
- [ ] Two tier products created in App Store Connect (+ annual), legal metadata + review screenshots, MANUAL release
- [ ] `burnbar_pro` (T1) and `burnbar_pro_max` (T2) entitlements verified end-to-end on a real purchase
- [ ] Stripe products/prices created; `STRIPE_*` config set; webhook writes entitlements (T2 web path decided)
- [ ] Google Play products created (if Android ships paid); server-verify green
- [ ] `APP_STORE_ENV=Production` + `APP_STORE_APPLE_APP_ID=6766366964` set; production ASN `delivered:true`
- [ ] App Check **ENFORCED** for Cloud Firestore
- [ ] Remote Config caps set; kill-switches `false`; quota limits 30/300
- [ ] Billing alert policies deployed with notification channel
- [ ] Website pricing page shows the two tiers; legal links live
- [ ] `commercial-launch-gate.mjs` (generalized for two products) returns `READY_FOR_LIVE_PAID_PROOF`
- [ ] `prove:hosted-quota` returns `ok:true` for a real paid user on each tier
- [ ] Canary window passed with per-tier margins inside Doc 4 targets

**Launch is done when every box is checked and the gate verdict is green on a clean `main`.**
