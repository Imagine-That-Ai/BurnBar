#!/usr/bin/env node

import assert from "node:assert/strict";

import {
  GOOGLE_PLAY_TOP_UPS,
  buildOneTimeProduct,
  diffOneTimeProduct,
  moneyFromUSD,
  moneyToUSD,
  priceUSDMicros,
} from "./prepare-commercial-iaps.mjs";

assert.equal(priceUSDMicros("4.99"), "4990000");
assert.equal(priceUSDMicros("19.99"), "19990000");
assert.deepEqual(moneyFromUSD("4.99"), { currencyCode: "USD", units: "4", nanos: 990000000 });
assert.equal(moneyToUSD({ currencyCode: "USD", units: "19", nanos: 990000000 }), "$19.99");

assert.deepEqual(
  GOOGLE_PLAY_TOP_UPS.map((product) => product.productId),
  [
    "com.openburnbar.agentcontrol.actions100",
    "com.openburnbar.floo.relay50gb",
    "com.openburnbar.elderwand.searches100",
    "com.openburnbar.elderwand.searches500",
  ],
);
assert.equal(GOOGLE_PLAY_TOP_UPS[0].name, "Agent Control · 100 actions");
assert.equal(GOOGLE_PLAY_TOP_UPS[1].name, "Floo relay · 50 GB");

const elderWand100 = GOOGLE_PLAY_TOP_UPS.find((product) => product.productId === "com.openburnbar.elderwand.searches100");
assert.ok(elderWand100);

const convertedPrices = {
  regionVersion: { version: "2026/02" },
  convertedRegionPrices: {
    US: {
      regionCode: "US",
      price: { currencyCode: "USD", units: "4", nanos: 990000000 },
    },
  },
  convertedOtherRegionsPrice: {
    usdPrice: { currencyCode: "USD", units: "4", nanos: 990000000 },
    eurPrice: { currencyCode: "EUR", units: "4", nanos: 990000000 },
  },
};

const oneTimeProduct = buildOneTimeProduct(elderWand100, "com.openburnbar", convertedPrices);
assert.equal(oneTimeProduct.packageName, "com.openburnbar");
assert.equal(oneTimeProduct.productId, "com.openburnbar.elderwand.searches100");
assert.equal(oneTimeProduct.listings[0].title, "Elder Wand Search 100");
assert.equal(oneTimeProduct.purchaseOptions[0].purchaseOptionId, "buy");
assert.equal(oneTimeProduct.purchaseOptions[0].buyOption.legacyCompatible, true);
assert.equal(oneTimeProduct.purchaseOptions[0].buyOption.multiQuantityEnabled, false);
assert.equal(oneTimeProduct.purchaseOptions[0].regionalPricingAndAvailabilityConfigs[0].availability, "AVAILABLE");
assert.equal(
  oneTimeProduct.purchaseOptions[0].taxAndComplianceSettings.withdrawalRightType,
  "WITHDRAWAL_RIGHT_DIGITAL_CONTENT",
);

assert.deepEqual(
  diffOneTimeProduct(
    {
      ...oneTimeProduct,
      purchaseOptions: [{ ...oneTimeProduct.purchaseOptions[0], state: "ACTIVE" }],
    },
    elderWand100,
  ),
  [],
);

assert.deepEqual(
  diffOneTimeProduct(
    {
      ...oneTimeProduct,
      listings: [{ languageCode: "en-US", title: "Old", description: oneTimeProduct.listings[0].description }],
      purchaseOptions: [
        {
          ...oneTimeProduct.purchaseOptions[0],
          state: "DRAFT",
          regionalPricingAndAvailabilityConfigs: [
            {
              regionCode: "US",
              price: { currencyCode: "USD", units: "1", nanos: 990000000 },
              availability: "AVAILABLE",
            },
          ],
        },
      ],
    },
    elderWand100,
  ),
  ["title", "state:DRAFT->ACTIVE", "usPrice:$1.99->$4.99"],
);

console.log("Google Play commercial IAP prep tests passed");
