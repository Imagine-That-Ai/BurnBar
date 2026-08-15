#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const require = createRequire(import.meta.url);
const { SUBSCRIPTIONS, TOP_UPS } = require('./prepare-commercial-iaps.js');

const subscriptionByProduct = new Map(
  SUBSCRIPTIONS.map((subscription) => [subscription.productId, subscription]),
);
const topUpByProduct = new Map(TOP_UPS.map((topUp) => [topUp.productId, topUp]));

const expectedSubscriptionIds = [
  'com.openburnbar.pro.monthly',
  'com.openburnbar.pro.annual',
  'com.openburnbar.proMax.v2.monthly',
  'com.openburnbar.proMax.annual',
];

assert.deepEqual([...subscriptionByProduct.keys()], expectedSubscriptionIds);
assert.equal(subscriptionByProduct.has('com.openburnbar.proMax.monthly'), false);

assert.equal(subscriptionByProduct.get('com.openburnbar.pro.monthly').priceUSD, '7.99');
assert.equal(subscriptionByProduct.get('com.openburnbar.pro.annual').priceUSD, '79.00');
assert.equal(subscriptionByProduct.get('com.openburnbar.proMax.v2.monthly').priceUSD, '24.99');
assert.equal(subscriptionByProduct.get('com.openburnbar.proMax.annual').priceUSD, '249.00');

assert.equal(subscriptionByProduct.get('com.openburnbar.pro.monthly').trial, true);
assert.equal(subscriptionByProduct.get('com.openburnbar.pro.annual').trial, true);
assert.equal(subscriptionByProduct.get('com.openburnbar.proMax.v2.monthly').trial, false);
assert.equal(subscriptionByProduct.get('com.openburnbar.proMax.annual').trial, false);

for (const subscription of SUBSCRIPTIONS) {
  assert.ok(subscription.localizationName.length > 0, `${subscription.productId} has a display name`);
  assert.ok(
    subscription.localizationDescription.length <= 55,
    `${subscription.productId} localization description fits ASC length limits`,
  );
  assert.ok(subscription.reviewNote.includes('BurnBar'), `${subscription.productId} has a review note`);
}

assert.deepEqual([...topUpByProduct.keys()], [
  'com.openburnbar.agentControl.actions100',
  'com.openburnbar.floo.relay50gb',
  'com.openburnbar.elderWand.searches100',
  'com.openburnbar.elderWand.searches500',
  'com.openburnbar.memory.boost.text.1m',
  'com.openburnbar.memory.boost.text.5m',
  'com.openburnbar.memory.boost.vision.1m',
]);
assert.equal(topUpByProduct.get('com.openburnbar.agentControl.actions100').priceUSD, '4.99');
assert.equal(topUpByProduct.get('com.openburnbar.floo.relay50gb').priceUSD, '4.99');
assert.equal(topUpByProduct.get('com.openburnbar.elderWand.searches100').priceUSD, '4.99');
assert.equal(topUpByProduct.get('com.openburnbar.elderWand.searches500').priceUSD, '19.99');
assert.equal(topUpByProduct.get('com.openburnbar.memory.boost.text.1m').priceUSD, '2.99');
assert.equal(topUpByProduct.get('com.openburnbar.memory.boost.text.5m').priceUSD, '9.99');
assert.equal(topUpByProduct.get('com.openburnbar.memory.boost.vision.1m').priceUSD, '6.99');

for (const topUp of TOP_UPS) {
  assert.ok(topUp.name.length > 0 && topUp.name.length <= 30, `${topUp.productId} ASC display name fits 30 chars`);
  assert.ok(topUp.reviewNote.includes('BurnBar'), `${topUp.productId} has a review note`);
}

const source = readFileSync(new URL('./prepare-commercial-iaps.js', import.meta.url), 'utf8');
assert.doesNotMatch(
  source,
  /api\('POST',\s*['"`]\/v1\/subscriptions/,
  'prep script must not create subscriptions; ASC creation remains an explicit operator step',
);
assert.match(
  source,
  /api\(\s*['"`]POST['"`],\s*['"`]\/v2\/inAppPurchases/,
  'prep script must create missing consumable top-ups idempotently',
);
assert.match(source, /inAppPurchaseType:\s*'CONSUMABLE'/);

console.log('prepare-commercial-iaps contract checks passed');
