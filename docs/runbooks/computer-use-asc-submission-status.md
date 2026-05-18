# Computer Use SKU — App Store Connect submission status

**Date:** 2026-05-17
**App:** OpenBurnBar (id `6766366964`, bundle `com.openburnbar.app`)
**SKUs created and submitted in real ASC (verified via API):**

| Product ID | Subscription Group | ASC ID | Price | State |
|---|---|---|---|---|
| `com.openburnbar.hostedComputerUseSync.monthly` | OpenBurnBar Computer Use (id `22095775`) | `6770276669` | $14.99/mo | WAITING_FOR_REVIEW |
| `com.openburnbar.proMax.monthly` | OpenBurnBar Pro Max (id `22095761`) | `6770276926` | $24.99/mo | WAITING_FOR_REVIEW |

## Final submission status

- ✅ iOS app version `1.0` (build `15`) resubmitted to App Review on 2026-05-17 at 14:48:16 UTC.
- ✅ Review submission `3598a21a-578c-42a0-b79e-0946b3dc1b81` is `WAITING_FOR_REVIEW`.
- ✅ Existing Hosted Quota Sync subscriptions remain `WAITING_FOR_REVIEW`.
- ✅ Computer Use subscriptions are attached to the iOS app version and are `WAITING_FOR_REVIEW`.

## Programmatically completed via ASC REST API

- ✅ Subscription groups created
- ✅ Subscriptions created with name + product id + 1-month period + review notes
- ✅ en-US subscription localizations (name + 47-char description)
- ✅ en-US subscription group localizations
- ✅ App Store Review screenshots uploaded, committed, and processed (`2064×2752` PNG, `assetDeliveryState=COMPLETE`)
- ✅ Subscription availability records with `availableInNewTerritories=true`
- ✅ USA base price ($14.99 / $24.99) attached via `subscriptionPrices`
- ✅ All-territory price fanout via Apple's subscription price-point equalizations endpoint (`175` price records per SKU)
- ✅ Direct `subscriptionSubmissions` attempt proved the first-subscription gate: Apple requires first subscriptions to be selected from the app version page and submitted with the app binary.

## Completed through App Store Connect UI

Apple's public API returns `FIRST_SUBSCRIPTION_MUST_BE_SUBMITTED_ON_VERSION` for first-time subscription review submissions. The final attach and resubmit were completed through the App Store Connect web UI:

1. Opened iOS app version `1.0` review page in Chrome.
2. Selected both `READY_TO_SUBMIT` Computer Use subscriptions in **In-App Purchases and Subscriptions**.
3. Added Computer Use review-note context.
4. Saved metadata.
5. Clicked **Update Review** and then **Resubmit to App Review**.

## Tooling shipped in this session

| Script | Purpose |
|---|---|
| `tools/app-store-connect/submit-computer-use-iaps.js` | Idempotent: ensures subscription groups + subscriptions + localizations exist |
| `tools/app-store-connect/price-computer-use-iaps.js` | Attaches USA base prices via `subscriptionPrices` |
| `tools/app-store-connect/upload-cu-review-screenshot.js` | Deletes stale/failed review screenshots and uploads `subscriptionAppStoreReviewScreenshots` via Apple's 3-step upload protocol |
| `tools/app-store-connect/fanout-cu-territory-prices.js` | Sets prices across the 9 explicitly-available territories |
| `tools/app-store-connect/fanout-cu-all-territories.js` | Best-effort fan-out to all 175 territories at the same tier (gets ~13 of 175; the rest need the ASC web UI's auto-conversion) |
| `tools/app-store-connect/fanout-cu-equalizations.js` | Final all-territory fanout using Apple's price-point equalizations endpoint |
| `OpenBurnBarMobileTests/Resources/OpenBurnBarComputerUse.storekit` | StoreKit configuration file for in-IDE testing of the IAPs |

All scripts are idempotent and read credentials from `APP_STORE_ASC_KEY_ID` + `APP_STORE_ASC_ISSUER_ID` + `APP_STORE_ASC_KEY_PATH` env vars (same pattern as the existing `tools/app-store-connect/asc-api.js`).

## Verification

```bash
TOKEN=$(node -e "/* mint JWT */")
curl -sS -G "https://api.appstoreconnect.apple.com/v1/apps/6766366964/subscriptionGroups" \
  --data-urlencode 'include=subscriptions' \
  -H "Authorization: Bearer $TOKEN" | python3 -c "..."
```

Expected `state=WAITING_FOR_REVIEW` for:

- iOS app version `1.0`
- `com.openburnbar.hostedQuotaSync.cloud.monthly`
- `com.openburnbar.hostedQuotaSync.monthly`
- `com.openburnbar.hostedComputerUseSync.monthly`
- `com.openburnbar.proMax.monthly`
