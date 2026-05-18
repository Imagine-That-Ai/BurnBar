#!/usr/bin/env node
/**
 * Create the Computer Use subscriptions in App Store Connect — in
 * DRAFT state. The user reviews + submits-for-review manually in ASC.
 *
 * Two SKUs (master plan § E.1):
 *   com.openburnbar.hostedComputerUseSync.monthly  ($14.99 / mo)
 *   com.openburnbar.proMax.monthly                  ($24.99 / mo)
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
    groupName: 'OpenBurnBar Computer Use',
    sku: {
      productId: 'com.openburnbar.hostedComputerUseSync.monthly',
      name: 'OpenBurnBar Computer Use Monthly',
      subscriptionPeriod: 'ONE_MONTH',
      reviewNote:
        'OpenBurnBar Computer Use lets the user run an AI agent that operates ' +
        'their Mac with explicit consent. Every action passes through an ' +
        'approval gate visible on the Mac and the paired iPhone/iPad. The ' +
        'agent can be halted by global hotkey (Ctrl+Option+Cmd+.), by a ' +
        'three-finger gesture on the phone, or by locking the Mac. Browser ' +
        'mode runs sandboxed inside Chromium and ships in the MAS build. ' +
        'System mode requires the macOS Accessibility permission and ships ' +
        'only via direct download outside MAS. A tamper-evident BLAKE3 ' +
        'hash-chain audit log records every action.',
    },
    localization: {
      locale: 'en-US',
      name: 'OpenBurnBar Computer Use',
      description: 'Watch and approve an AI agent driving your Mac.',
    },
  },
  {
    groupName: 'OpenBurnBar Pro Max',
    sku: {
      productId: 'com.openburnbar.proMax.monthly',
      name: 'OpenBurnBar Pro Max Monthly',
      subscriptionPeriod: 'ONE_MONTH',
      reviewNote: 'Umbrella subscription bundling Cloud + Mercury Media + Computer Use.',
    },
    localization: {
      locale: 'en-US',
      name: 'OpenBurnBar Pro Max',
      description: 'Cloud + Mercury Media + Computer Use bundled.',
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
    return existingId;
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
    return '<dry-run-sub>';
  }
  const resp = await request('POST', '/v1/subscriptions', body, token);
  console.log(`  subscription created: id=${resp.data.id}  pid=${sku.productId}`);
  return resp.data.id;
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
  if ((existing.data || []).some((x) => x.attributes.locale === loc.locale)) {
    console.log(`  subscription localization ${loc.locale} already exists`);
    return;
  }
  const body = {
    data: {
      type: 'subscriptionLocalizations',
      attributes: { locale: loc.locale, name: loc.name, description: loc.description },
      relationships: {
        subscription: { data: { type: 'subscriptions', id: subId } },
      },
    },
  };
  await request('POST', '/v1/subscriptionLocalizations', body, token);
  console.log(`  subscription localization ${loc.locale} created`);
}

(async () => {
  const token = makeToken();
  const dryRun = !APPLY;
  console.log(`mode: ${dryRun ? 'DRY-RUN' : 'APPLY'}  app=${APP_ID}`);
  for (const item of SUBSCRIPTIONS) {
    console.log(`\n→ ${item.sku.productId}`);
    const groupId = await ensureGroup(token, item.groupName, dryRun);
    await ensureGroupLocalization(token, groupId, item.groupName, dryRun);
    const subId = await ensureSubscription(token, groupId, item.sku, dryRun);
    await ensureSubLocalization(token, subId, item.localization, dryRun);
  }
  console.log(dryRun
    ? '\nDry-run complete. Re-run with --apply to create draft IAPs.'
    : '\nDraft IAPs ensured in App Store Connect. Add pricing + screenshots in ASC, then submit for review.');
})().catch((e) => { console.error(e); process.exit(1); });
