#!/usr/bin/env node
/**
 * Create the commercial BurnBar Cloud subscriptions in App Store Connect.
 * New subscriptions are created in DRAFT state. The operator reviews,
 * prices, attaches screenshots, and submits them with the app version in ASC.
 *
 * GTM Master Plan SKUs:
 *   com.openburnbar.pro.monthly      BurnBar Cloud monthly
 *   com.openburnbar.pro.annual       BurnBar Cloud annual
 *   com.openburnbar.proMax.v2.monthly   BurnBar Cloud Pro monthly
 *   com.openburnbar.proMax.annual    BurnBar Cloud Pro annual
 *
 * Required env vars:
 *   APP_STORE_ASC_KEY_ID      — ASC API key id (10-char)
 *   APP_STORE_ASC_ISSUER_ID   — issuer uuid
 *   APP_STORE_ASC_KEY_P8      — full PEM contents of the .p8 file
 *                               (or APP_STORE_ASC_KEY_PATH = path)
 *   APP_STORE_APPLE_APP_ID    — numeric app id (defaults to 6766366964)
 *
 * Flags:
 *   --apply         actually call the API (default: dry-run)
 *   --idempotent    skip subscriptions that already exist (default: on)
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const { buildSubscriptionPriceBody } = require('./price-computer-use-iaps.js');

const APP_ID = process.env.APP_STORE_APPLE_APP_ID || '6766366964';
const KEY_ID = process.env.APP_STORE_ASC_KEY_ID;
const ISSUER_ID = process.env.APP_STORE_ASC_ISSUER_ID;
const KEY_P8 = process.env.APP_STORE_ASC_KEY_P8;
const KEY_PATH = process.env.APP_STORE_ASC_KEY_PATH;

const args = new Set(process.argv.slice(2));
const APPLY = args.has('--apply');

function base64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function makeToken() {
  if (!KEY_ID || !ISSUER_ID) {
    throw new Error('APP_STORE_ASC_KEY_ID and APP_STORE_ASC_ISSUER_ID required');
  }
  const keyPem = KEY_P8 || (KEY_PATH && fs.readFileSync(KEY_PATH, 'utf8'));
  if (!keyPem) {
    throw new Error('APP_STORE_ASC_KEY_P8 (PEM string) or APP_STORE_ASC_KEY_PATH required');
  }
  const header = { alg: 'ES256', kid: KEY_ID, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: ISSUER_ID, iat: now, exp: now + 20 * 60, aud: 'appstoreconnect-v1',
  };
  const headerSeg = base64url(JSON.stringify(header));
  const claimSeg = base64url(JSON.stringify(claims));
  const signingInput = `${headerSeg}.${claimSeg}`;
  const signer = crypto.createSign('SHA256');
  signer.update(signingInput);
  const der = signer.sign(keyPem);
  // Convert DER ECDSA to JOSE (raw r||s).
  const sig = derToJose(der);
  return `${signingInput}.${base64url(sig)}`;
}

function derToJose(der) {
  // Parse DER ECDSA signature: SEQUENCE { INTEGER r, INTEGER s }
  let offset = 0;
  if (der[offset++] !== 0x30) throw new Error('bad DER');
  let len = der[offset++];
  if (len & 0x80) {
    const lenBytes = len & 0x7f;
    len = 0;
    for (let i = 0; i < lenBytes; i++) len = (len << 8) | der[offset++];
  }
  if (der[offset++] !== 0x02) throw new Error('bad DER (r)');
  let rLen = der[offset++];
  let r = der.slice(offset, offset + rLen);
  offset += rLen;
  if (der[offset++] !== 0x02) throw new Error('bad DER (s)');
  let sLen = der[offset++];
  let s = der.slice(offset, offset + sLen);
  // Strip leading zero padding, then left-pad to 32.
  if (r[0] === 0) r = r.slice(1);
  if (s[0] === 0) s = s.slice(1);
  const out = Buffer.alloc(64, 0);
  r.copy(out, 32 - r.length);
  s.copy(out, 64 - s.length);
  return out;
}

function request(method, path, body, token) {
  return new Promise((resolve, reject) => {
    const opts = {
      method,
      hostname: 'api.appstoreconnect.apple.com',
      path,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/json',
      },
    };
    if (body !== undefined) {
      const json = JSON.stringify(body);
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(json);
    }
    const req = https.request(opts, (res) => {
      let chunks = '';
      res.on('data', (c) => (chunks += c));
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(chunks ? JSON.parse(chunks) : {});
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${chunks}`));
        }
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(JSON.stringify(body));
    req.end();
  });
}

const SUBSCRIPTIONS = [
  {
    groupName: 'OpenBurnBar Cloud',
    sku: {
      productId: 'com.openburnbar.pro.monthly',
      name: 'BurnBar Cloud Monthly',
      subscriptionPeriod: 'ONE_MONTH',
      priceUSD: '7.99',
      reviewNote:
        'BurnBar Cloud adds hosted quota refresh, encrypted history backup, ' +
        'cloud search, Intelligence Brief fallback, remote relay, and synced ' +
        'agent memory across the user\'s signed-in devices. It includes a ' +
        '14-day introductory free trial for new subscribers.',
    },
    localization: {
      locale: 'en-US',
      name: 'BurnBar Cloud',
      description: 'Sync quota, encrypted history, and agent memory.',
    },
  },
  {
    groupName: 'OpenBurnBar Cloud',
    sku: {
      productId: 'com.openburnbar.pro.annual',
      name: 'BurnBar Cloud Annual',
      subscriptionPeriod: 'ONE_YEAR',
      priceUSD: '79.00',
      reviewNote:
        'Annual BurnBar Cloud subscription. Includes hosted quota refresh, ' +
        'encrypted history backup, cloud search, Intelligence Brief fallback, ' +
        'remote relay, and synced agent memory. It includes a 14-day ' +
        'introductory free trial for new subscribers.',
    },
    localization: {
      locale: 'en-US',
      name: 'BurnBar Cloud',
      description: 'Annual sync for quota, history, and agent memory.',
    },
  },
  {
    groupName: 'OpenBurnBar Cloud Pro',
    sku: {
      productId: 'com.openburnbar.proMax.v2.monthly',
      name: 'BurnBar Cloud Pro Monthly',
      subscriptionPeriod: 'ONE_MONTH',
      priceUSD: '24.99',
      reviewNote:
        'BurnBar Cloud Pro includes everything in BurnBar Cloud plus Floo ' +
        'phone-to-Mac workflows and supervised Agent Control. Each billing ' +
        'month includes 500 hosted Agent Control actions and 50 relay-accounting ' +
        'GB. Extra hosted usage is prepaid through consumable top-ups. There is ' +
        'no introductory free trial for Cloud Pro.',
    },
    localization: {
      locale: 'en-US',
      name: 'BurnBar Cloud Pro',
      description: 'Cloud plus Floo and supervised Agent Control.',
    },
  },
  {
    groupName: 'OpenBurnBar Cloud Pro',
    sku: {
      productId: 'com.openburnbar.proMax.annual',
      name: 'BurnBar Cloud Pro Annual',
      subscriptionPeriod: 'ONE_YEAR',
      priceUSD: '249.00',
      reviewNote:
        'Annual BurnBar Cloud Pro subscription. Includes BurnBar Cloud plus ' +
        'Floo phone-to-Mac workflows and supervised Agent Control. Each billing ' +
        'year is billed annually, while included hosted-action and relay ' +
        'allowances reset monthly. There is no introductory free trial.',
    },
    localization: {
      locale: 'en-US',
      name: 'BurnBar Cloud Pro',
      description: 'Annual Cloud plus Floo and Agent Control.',
    },
  },
];

async function listExistingProducts(token) {
  const resp = await request(
    'GET',
    `/v1/apps/${APP_ID}/subscriptionGroups?limit=200&include=subscriptions`,
    undefined, token
  );
  const subs = (resp.included || []).filter((x) => x.type === 'subscriptions');
  return new Map(subs.map((s) => [s.attributes.productId, s.id]));
}

async function findExistingGroup(token, referenceName) {
  const resp = await request(
    'GET',
    `/v1/apps/${APP_ID}/subscriptionGroups?limit=200`,
    undefined, token
  );
  return (resp.data || []).find((g) => g.attributes.referenceName === referenceName);
}

async function ensureGroup(token, referenceName, dryRun) {
  const existing = await findExistingGroup(token, referenceName);
  if (existing) {
    console.log(`  group exists: id=${existing.id}  ref=${referenceName}`);
    return existing.id;
  }
  const body = {
    data: {
      type: 'subscriptionGroups',
      attributes: { referenceName },
      relationships: { app: { data: { type: 'apps', id: APP_ID } } },
    },
  };
  if (dryRun) {
    console.log(`  [DRY] POST /v1/subscriptionGroups  ref=${referenceName}`);
    return '<dry-run-group>';
  }
  const resp = await request('POST', '/v1/subscriptionGroups', body, token);
  console.log(`  group created: id=${resp.data.id}  ref=${referenceName}`);
  return resp.data.id;
}

async function ensureGroupLocalization(token, groupId, name, dryRun) {
  if (dryRun || groupId === '<dry-run-group>') {
    console.log(`  [DRY] subscription group localization en-US name=${name}`);
    return;
  }
  // Idempotency: list first.
  const existing = await request(
    'GET',
    `/v1/subscriptionGroups/${groupId}/subscriptionGroupLocalizations?limit=20`,
    undefined, token
  );
  if ((existing.data || []).some((x) => x.attributes.locale === 'en-US')) {
    console.log('  group localization en-US already exists');
    return;
  }
  const body = {
    data: {
      type: 'subscriptionGroupLocalizations',
      attributes: { locale: 'en-US', name, customAppName: null },
      relationships: {
        subscriptionGroup: {
          data: { type: 'subscriptionGroups', id: groupId },
        },
      },
    },
  };
  await request('POST', '/v1/subscriptionGroupLocalizations', body, token);
  console.log('  group localization en-US created');
}

async function ensureSubscription(token, groupId, sku, dryRun) {
  const existingByPid = await listExistingProducts(token);
  if (existingByPid.has(sku.productId)) {
    const existingId = existingByPid.get(sku.productId);
    console.log(`  subscription exists: id=${existingId}  pid=${sku.productId}`);
    return { id: existingId, existed: true };
  }
  const body = {
    data: {
      type: 'subscriptions',
      attributes: {
        name: sku.name,
        productId: sku.productId,
        subscriptionPeriod: sku.subscriptionPeriod,
        reviewNote: sku.reviewNote,
        familySharable: false,
      },
      relationships: {
        group: { data: { type: 'subscriptionGroups', id: groupId } },
      },
    },
  };
  if (dryRun) {
    console.log(`  [DRY] POST /v1/subscriptions  pid=${sku.productId}`);
    return { id: '<dry-run-sub>', existed: false };
  }
  const resp = await request('POST', '/v1/subscriptions', body, token);
  console.log(`  subscription created: id=${resp.data.id}  pid=${sku.productId}`);
  return { id: resp.data.id, existed: false };
}

function buildSubscriptionPatchBody(subId, sku) {
  return {
    data: {
      id: subId,
      type: 'subscriptions',
      attributes: {
        name: sku.name,
        reviewNote: sku.reviewNote,
        familySharable: false,
      },
    },
  };
}

async function updateExistingSubscription(token, subId, sku, dryRun) {
  if (dryRun || subId === '<dry-run-sub>') {
    console.log(`  [DRY] PATCH /v1/subscriptions/${subId}  pid=${sku.productId}`);
    return;
  }
  await request('PATCH', `/v1/subscriptions/${subId}`, buildSubscriptionPatchBody(subId, sku), token);
  console.log(`  subscription metadata updated: id=${subId}  pid=${sku.productId}`);
}

function buildSubscriptionLocalizationBody(subId, loc, localizationId = undefined) {
  const data = {
    type: 'subscriptionLocalizations',
    attributes: { locale: loc.locale, name: loc.name, description: loc.description },
    relationships: {
      subscription: { data: { type: 'subscriptions', id: subId } },
    },
  };
  if (localizationId) {
    data.id = localizationId;
    delete data.attributes.locale;
    delete data.relationships;
  }
  return { data };
}

async function ensureSubLocalization(token, subId, loc, dryRun) {
  if (dryRun || subId === '<dry-run-sub>') {
    console.log(`  [DRY] subscription localization ${loc.locale}: ${loc.name}`);
    return;
  }
  const existing = await request(
    'GET',
    `/v1/subscriptions/${subId}/subscriptionLocalizations?limit=20`,
    undefined, token
  );
  const current = (existing.data || []).find((x) => x.attributes.locale === loc.locale);
  if (current) {
    await request(
      'PATCH',
      `/v1/subscriptionLocalizations/${current.id}`,
      buildSubscriptionLocalizationBody(subId, loc, current.id),
      token,
    );
    console.log(`  subscription localization ${loc.locale} updated`);
    return;
  }
  await request('POST', '/v1/subscriptionLocalizations', buildSubscriptionLocalizationBody(subId, loc), token);
  console.log(`  subscription localization ${loc.locale} created`);
}

async function findUSAPricePoint(token, subscriptionId, customerPrice) {
  const targetPrice = Number(customerPrice);
  let next = `/v1/subscriptions/${subscriptionId}/pricePoints?filter[territory]=USA&limit=200`;
  while (next) {
    const resp = await request('GET', next, undefined, token);
    for (const point of resp.data || []) {
      if (Number(point.attributes.customerPrice) === targetPrice) return point.id;
    }
    next = resp.links && resp.links.next
      ? resp.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
  }
  return null;
}

async function ensureSubscriptionBasePrice(token, subscriptionId, sku, dryRun) {
  if (subscriptionId === '<dry-run-sub>') {
    console.log(`  [DRY] would apply USA base price $${sku.priceUSD} after creating ${sku.productId}`);
    return;
  }
  const pricePointId = await findUSAPricePoint(token, subscriptionId, sku.priceUSD);
  if (!pricePointId) {
    console.log(`  no USA subscription price point matching $${sku.priceUSD}`);
    return;
  }
  if (dryRun) {
    console.log(`  [DRY] POST /v1/subscriptionPrices  pid=${sku.productId} pricePoint=${pricePointId}`);
    return;
  }
  try {
    const resp = await request(
      'POST',
      '/v1/subscriptionPrices',
      buildSubscriptionPriceBody(subscriptionId, pricePointId),
      token,
    );
    console.log(`  subscription USA base price set: id=${resp.data && resp.data.id}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.startsWith('HTTP 409')) {
      console.log('  subscription USA base price already set');
      return;
    }
    throw error;
  }
}

async function main() {
  const token = makeToken();
  const dryRun = !APPLY;
  console.log(`mode: ${dryRun ? 'DRY-RUN' : 'APPLY'}  app=${APP_ID}`);
  for (const item of SUBSCRIPTIONS) {
    console.log(`\n→ ${item.sku.productId}`);
    const groupId = await ensureGroup(token, item.groupName, dryRun);
    await ensureGroupLocalization(token, groupId, item.groupName, dryRun);
    const subscription = await ensureSubscription(token, groupId, item.sku, dryRun);
    if (subscription.existed) await updateExistingSubscription(token, subscription.id, item.sku, dryRun);
    await ensureSubLocalization(token, subscription.id, item.localization, dryRun);
    await ensureSubscriptionBasePrice(token, subscription.id, item.sku, dryRun);
  }
  console.log(dryRun
    ? '\nDry-run complete. Re-run with --apply to create/update subscriptions and apply USA base prices.'
    : '\nCommercial subscriptions and USA base prices ensured in App Store Connect. Add screenshots in ASC, then submit for review.');
}

module.exports = {
  SUBSCRIPTIONS,
  buildSubscriptionLocalizationBody,
  buildSubscriptionPatchBody,
  ensureSubscriptionBasePrice,
  main,
};

if (require.main === module) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
