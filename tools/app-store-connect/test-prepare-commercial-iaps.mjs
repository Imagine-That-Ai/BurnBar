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
]);
assert.equal(topUpByProduct.get('com.openburnbar.agentControl.actions100').priceUSD, '4.99');
assert.equal(topUpByProduct.get('com.openburnbar.floo.relay50gb').priceUSD, '4.99');

const source = readFileSync(new URL('./prepare-commercial-iaps.js', import.meta.url), 'utf8');
assert.doesNotMatch(
  source,
  /api\('POST',\s*['"`]\/v1\/subscriptions/,
  'prep script must not create subscriptions; ASC creation remains an explicit operator step',
);

console.log('prepare-commercial-iaps contract checks passed');
