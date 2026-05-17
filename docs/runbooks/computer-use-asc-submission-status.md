# Computer Use SKU — App Store Connect submission status

**Date:** 2026-05-17
**App:** OpenBurnBar (id `6766366964`, bundle `com.openburnbar.app`)
**SKUs created in real ASC (verified via API):**

| Product ID | Subscription Group | ASC ID | Price | State |
|---|---|---|---|---|
| `com.openburnbar.hostedComputerUseSync.monthly` | OpenBurnBar Computer Use (id `22095775`) | `6770276669` | $14.99/mo | MISSING_METADATA |
| `com.openburnbar.proMax.monthly` | OpenBurnBar Pro Max (id `22095761`) | `6770276926` | $24.99/mo | MISSING_METADATA |

## Programmatically completed via ASC REST API

- ✅ Subscription groups created
- ✅ Subscriptions created with name + product id + 1-month period + review notes
- ✅ en-US subscription localizations (name + 47-char description)
- ✅ en-US subscription group localizations
- ✅ App Store Review screenshots (1024×1024 PNG, uploaded + committed)
- ✅ Subscription availability records (9 territories: USA + CAN + GBR + AUS + NZL + IRL + DEU + FRA + JPN, with `availableInNewTerritories=true`)
- ✅ USA base price ($14.99 / $24.99) attached via `subscriptionPrices`
- ✅ 9-territory price fanout via tier matching (USA + 8 others where Apple's tier numbers match)

## What's left — 2 minutes of clicking in App Store Connect

Apple's REST API requires explicit prices in **every** Apple territory (~175) before `subscriptionSubmissions` will accept the IAP. Programmatic enumeration is blocked because Apple uses different tier-number schemes per territory's local currency. The interactive App Store Connect web UI has a **"Set Prices in All Territories"** flow that does the equivalent in one click.

### Step-by-step

1. Open https://appstoreconnect.apple.com/apps/6766366964/distribution/subscriptions
2. Click **OpenBurnBar Computer Use** (group)
3. Click **OpenBurnBar Computer Use Monthly** (sub)
4. **Pricing → "Set Prices in All Territories"** → confirm USA base $14.99
5. Add any other locale's localization beyond en-US if you want broader reach
6. Click **"Submit for Review"** (will move state to `WAITING_FOR_REVIEW`)
7. Repeat steps 2-6 for **OpenBurnBar Pro Max → OpenBurnBar Pro Max Monthly** at $24.99

After step 6, state should match the existing `hostedQuotaSync` SKUs (which are currently `WAITING_FOR_REVIEW`).

## Tooling shipped in this session

| Script | Purpose |
|---|---|
| `tools/app-store-connect/submit-computer-use-iaps.js` | Idempotent: ensures subscription groups + subscriptions + localizations exist |
| `tools/app-store-connect/price-computer-use-iaps.js` | Attaches USA base prices via `subscriptionPrices` |
| `tools/app-store-connect/upload-cu-review-screenshot.js` | Uploads `subscriptionAppStoreReviewScreenshots` via Apple's 3-step upload protocol |
| `tools/app-store-connect/fanout-cu-territory-prices.js` | Sets prices across the 9 explicitly-available territories |
| `tools/app-store-connect/fanout-cu-all-territories.js` | Best-effort fan-out to all 175 territories at the same tier (gets ~13 of 175; the rest need the ASC web UI's auto-conversion) |
| `OpenBurnBarMobileTests/Resources/OpenBurnBarComputerUse.storekit` | StoreKit configuration file for in-IDE testing of the IAPs |

All scripts are idempotent and read credentials from `APP_STORE_ASC_KEY_ID` + `APP_STORE_ASC_ISSUER_ID` + `APP_STORE_ASC_KEY_PATH` env vars (same pattern as the existing `tools/app-store-connect/asc-api.js`).

## Verifying after the user clicks Submit

```bash
TOKEN=$(node -e "/* mint JWT */")
curl -sS -G "https://api.appstoreconnect.apple.com/v1/apps/6766366964/subscriptionGroups" \
  --data-urlencode 'include=subscriptions' \
  -H "Authorization: Bearer $TOKEN" | python3 -c "..."
```

Expected `state=WAITING_FOR_REVIEW` for both `com.openburnbar.hostedComputerUseSync.monthly` and `com.openburnbar.proMax.monthly`.
