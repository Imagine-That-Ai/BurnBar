#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const {
  SUBSCRIPTIONS,
  TOP_UPS,
  buildInAppPurchasePriceScheduleBody,
} = require('./prepare-commercial-iaps.js');
const {
  buildSubscriptionLocalizationBody,
  buildSubscriptionPatchBody,
} = require('./submit-computer-use-iaps.js');
const { buildSubscriptionPriceBody } = require('./price-computer-use-iaps.js');
const { isTrustedUploadHost } = require('./upload-cu-review-screenshot.js');

function nodeCheck(relativePath) {
  const filePath = fileURLToPath(new URL(relativePath, import.meta.url));
  const result = spawnSync(process.execPath, ['--check', filePath], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

nodeCheck('./upload-cu-review-screenshot.js');
nodeCheck('./submit-computer-use-iaps.js');
nodeCheck('./price-computer-use-iaps.js');
nodeCheck('./prepare-commercial-iaps.js');

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

const submitSource = readFileSync(new URL('./submit-computer-use-iaps.js', import.meta.url), 'utf8');
assert.match(
  submitSource,
  /PATCH',\s*`\/v1\/subscriptions\/\$\{subId\}`/,
  'submit script must patch existing subscription SKUs instead of only skipping them',
);

const sampleSku = {
  productId: 'com.openburnbar.pro.monthly',
  name: 'BurnBar Cloud Monthly',
  reviewNote: 'BurnBar review note',
};
const subscriptionPatch = buildSubscriptionPatchBody('sub-1', sampleSku);
assert.equal(subscriptionPatch.data.id, 'sub-1');
assert.equal(subscriptionPatch.data.attributes.name, sampleSku.name);
assert.equal(subscriptionPatch.data.attributes.reviewNote, sampleSku.reviewNote);
assert.equal(
  /priceUSD:\s*'7\.99'/.test(submitSource),
  true,
  'submit script must carry base prices with the subscription SKUs',
);
assert.match(
  submitSource,
  /POST',\s*'\/v1\/subscriptionPrices'/,
  'submit script must apply subscription base prices instead of leaving pricing manual',
);

const localizationPost = buildSubscriptionLocalizationBody('sub-1', {
  locale: 'en-US',
  name: 'BurnBar Cloud',
  description: 'Cloud sync.',
});
assert.equal(localizationPost.data.relationships.subscription.data.id, 'sub-1');

const localizationPatch = buildSubscriptionLocalizationBody('sub-1', {
  locale: 'en-US',
  name: 'BurnBar Cloud',
  description: 'Cloud sync.',
}, 'loc-1');
assert.equal(localizationPatch.data.id, 'loc-1');
assert.equal(localizationPatch.data.attributes.locale, undefined);
assert.equal(localizationPatch.data.relationships, undefined);

const subscriptionPrice = buildSubscriptionPriceBody('sub-1', 'price-point-1');
assert.equal(subscriptionPrice.data.relationships.subscription.data.id, 'sub-1');
assert.equal(subscriptionPrice.data.relationships.subscriptionPricePoint.data.id, 'price-point-1');

const iapPriceSchedule = buildInAppPurchasePriceScheduleBody('iap-1', 'iap-price-point-1');
const manualPriceRef = iapPriceSchedule.data.relationships.manualPrices.data[0];
assert.equal(manualPriceRef.id, 'manual-price-0');
assert.equal(iapPriceSchedule.included[0].id, manualPriceRef.id);
assert.equal(
  iapPriceSchedule.included[0].relationships.inAppPurchasePricePoint.data.id,
  'iap-price-point-1',
);
assert.notEqual(manualPriceRef.id, '${p0}');

assert.equal(isTrustedUploadHost('upload.appstoreconnect.apple.com'), true);
assert.equal(isTrustedUploadHost('iosapps-ssl.itunes.apple.com'), true);
assert.equal(isTrustedUploadHost('s3.us-west-2.amazonaws.com'), true);
assert.equal(isTrustedUploadHost('bucket.s3.us-west-2.amazonaws.com'), true);
assert.equal(isTrustedUploadHost('attacker.amazonaws.com'), false);

const priceSource = readFileSync(new URL('./price-computer-use-iaps.js', import.meta.url), 'utf8');
assert.match(
  priceSource,
  /`\/v1\/apps\/\$\{APP_ID\}\/subscriptionGroups/,
  'price helper must respect APP_STORE_APPLE_APP_ID instead of hardcoding one app id',
);

console.log('prepare-commercial-iaps contract checks passed');
