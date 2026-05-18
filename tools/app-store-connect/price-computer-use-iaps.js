#!/usr/bin/env node
/**
 * Attach the price tier ($14.99 / $24.99) to the Computer Use IAPs.
 * Run after submit-computer-use-iaps.js has created the draft SKUs.
 *
 * Requires the same env vars as submit-computer-use-iaps.js.
 *
 * Usage:
 *   node tools/app-store-connect/price-computer-use-iaps.js [--apply]
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');

const KEY_ID = process.env.APP_STORE_ASC_KEY_ID;
const ISSUER_ID = process.env.APP_STORE_ASC_ISSUER_ID;
const KEY_P8 = process.env.APP_STORE_ASC_KEY_P8;
const KEY_PATH = process.env.APP_STORE_ASC_KEY_PATH;

const APPLY = new Set(process.argv.slice(2)).has('--apply');

const TARGETS = [
  { productId: 'com.openburnbar.hostedComputerUseSync.monthly', priceUSD: '14.99' },
  { productId: 'com.openburnbar.proMax.monthly', priceUSD: '24.99' },
];

function b64u(s) {
  return Buffer.from(s).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function derToJose(der) {
  let o = 0;
  if (der[o++] !== 0x30) throw new Error('bad DER');
  let len = der[o++];
  if (len & 0x80) {
    const n = len & 0x7f; len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | der[o++];
  }
  if (der[o++] !== 0x02) throw new Error('bad DER r');
  let rL = der[o++]; let r = der.slice(o, o + rL); o += rL;
  if (der[o++] !== 0x02) throw new Error('bad DER s');
  let sL = der[o++]; let s = der.slice(o, o + sL);
  if (r[0] === 0) r = r.slice(1);
  if (s[0] === 0) s = s.slice(1);
  const out = Buffer.alloc(64, 0);
  r.copy(out, 32 - r.length);
  s.copy(out, 64 - s.length);
  return out;
}

function makeToken() {
  const keyPem = KEY_P8 || (KEY_PATH && fs.readFileSync(KEY_PATH, 'utf8'));
  if (!KEY_ID || !ISSUER_ID || !keyPem) {
    throw new Error('Need APP_STORE_ASC_KEY_ID, APP_STORE_ASC_ISSUER_ID, APP_STORE_ASC_KEY_P8|PATH');
  }
  const header = b64u(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const claims = b64u(JSON.stringify({
    iss: ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1',
  }));
  const signingInput = `${header}.${claims}`;
  const signer = crypto.createSign('SHA256');
  signer.update(signingInput);
  return `${signingInput}.${b64u(derToJose(signer.sign(keyPem)))}`;
}

function api(method, path, body, token) {
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
      const j = JSON.stringify(body);
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(j);
    }
    const req = https.request(opts, (res) => {
      let c = '';
      res.on('data', (d) => (c += d));
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(c ? JSON.parse(c) : {});
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${c}`));
        }
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(JSON.stringify(body));
    req.end();
  });
}

async function listSubscriptions(token) {
  const resp = await api('GET',
    `/v1/apps/6766366964/subscriptionGroups?include=subscriptions&limit=200`,
    undefined, token);
  const subs = (resp.included || []).filter((x) => x.type === 'subscriptions');
  const out = {};
  for (const s of subs) out[s.attributes.productId] = s;
  return out;
}

async function findUSAPricePoint(subscriptionId, customerPrice, token) {
  // ASC's API returns pricePoints scoped to a subscription. We filter
  // on territory=USA and find the one matching the requested USD price.
  let next = `/v1/subscriptions/${subscriptionId}/pricePoints?filter[territory]=USA&limit=200`;
  while (next) {
    const resp = await api('GET', next, undefined, token);
    for (const pt of resp.data || []) {
      if (pt.attributes.customerPrice === customerPrice) return pt.id;
    }
    next = resp.links && resp.links.next
      ? resp.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
  }
  return null;
}

async function ensurePrice(subscription, pricePointId, token, dryRun) {
  const body = {
    data: {
      type: 'subscriptionPrices',
      attributes: { startDate: null, preserveCurrentPrice: false },
      relationships: {
        subscription: { data: { type: 'subscriptions', id: subscription.id } },
        subscriptionPricePoint: {
          data: { type: 'subscriptionPricePoints', id: pricePointId },
        },
        territory: { data: { type: 'territories', id: 'USA' } },
      },
    },
  };
  if (dryRun) {
    console.log(`  [DRY] POST /v1/subscriptionPrices  pricePoint=${pricePointId}`);
    return;
  }
  try {
    const resp = await api('POST', '/v1/subscriptionPrices', body, token);
    console.log(`  price set: id=${resp.data && resp.data.id}  pricePoint=${pricePointId}`);
  } catch (e) {
    // 409 = already priced — surface but don't fail.
    if (e.message.startsWith('HTTP 409')) {
      console.log(`  price already set (409)`);
    } else throw e;
  }
}

(async () => {
  const token = makeToken();
  const subs = await listSubscriptions(token);
  for (const t of TARGETS) {
    const sub = subs[t.productId];
    if (!sub) {
      console.error(`  missing subscription for ${t.productId}; run submit-computer-use-iaps.js first`);
      continue;
    }
    console.log(`\n→ ${t.productId} (id=${sub.id})  $${t.priceUSD}`);
    const pricePoint = await findUSAPricePoint(sub.id, t.priceUSD, token);
    if (!pricePoint) {
      console.error(`  no USA price point matching $${t.priceUSD}`);
      continue;
    }
    console.log(`  USA price point id=${pricePoint}`);
    await ensurePrice(sub, pricePoint, token, !APPLY);
  }
  console.log(APPLY
    ? '\nPrices attached. Other territories use auto-conversion from USA base.'
    : '\nDry-run complete. Add --apply to write.');
})().catch((e) => { console.error(e); process.exit(1); });
