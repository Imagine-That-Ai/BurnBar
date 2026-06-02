#!/usr/bin/env node
/**
 * Upload an App Store Review screenshot for the Computer Use IAPs.
 * Required by Apple to move a subscription from MISSING_METADATA to
 * READY_TO_SUBMIT.
 *
 * Apple's upload flow has three steps:
 *   1. POST /v1/subscriptionAppStoreReviewScreenshots — declare the asset.
 *      Apple returns one or more uploadOperations with PUT URLs.
 *   2. PUT each chunk to its URL with the supplied headers.
 *   3. PATCH /v1/subscriptionAppStoreReviewScreenshots/{id}  uploaded=true.
 *
 * Usage:
 *   node tools/app-store-connect/upload-cu-review-screenshot.js \
 *       --image /path/to/1024.png --apply
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const path = require('path');
const url = require('url');

const KEY_ID = process.env.APP_STORE_ASC_KEY_ID;
const ISSUER_ID = process.env.APP_STORE_ASC_ISSUER_ID;
const KEY_P8 = process.env.APP_STORE_ASC_KEY_P8;
const KEY_PATH = process.env.APP_STORE_ASC_KEY_PATH;
const APP_ID = process.env.APP_STORE_APPLE_APP_ID || '6766366964';

const args = process.argv.slice(2);
const IMAGE_OVERRIDE = (() => {
  const i = args.indexOf('--image');
  return i >= 0 ? args[i + 1] : null;
})();
const APPLY = args.includes('--apply');

const TARGET_PRODUCT_IDS = [
  'com.openburnbar.pro.monthly',
  'com.openburnbar.pro.annual',
  'com.openburnbar.proMax.v2.monthly',
  'com.openburnbar.proMax.annual',
];
const TOP_UP_PRODUCTS = [
  {
    productId: 'com.openburnbar.agentControl.actions100',
    name: 'Agent Control 100 Actions',
    description: 'Adds 100 hosted Agent Control actions.',
  },
  {
    productId: 'com.openburnbar.floo.relay50gb',
    name: 'Floo Relay 50 GB',
    description: 'Adds 50 GB of Floo relay bandwidth.',
  },
];
const REVIEW_SCREENSHOT_BY_PRODUCT_ID = {
  'com.openburnbar.pro.monthly': 'review-final/burnbar-cloud-review.jpg',
  'com.openburnbar.pro.annual': 'review-final/burnbar-cloud-review.jpg',
  'com.openburnbar.proMax.v2.monthly': 'review-final/burnbar-cloud-pro-review.jpg',
  'com.openburnbar.proMax.annual': 'review-final/burnbar-cloud-pro-review.jpg',
  'com.openburnbar.agentControl.actions100': 'review-final/burnbar-cloud-pro-topups-review.jpg',
  'com.openburnbar.floo.relay50gb': 'review-final/burnbar-cloud-pro-topups-review.jpg',
};
const TRUSTED_UPLOAD_HOST_SUFFIXES = ['.apple.com', '.mzstatic.com', '.icloud-content.com'];

function b64u(s) { return Buffer.from(s).toString('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_'); }
function derToJose(d){
  let o=0;
  if(d[o++]!==0x30)throw new Error('bad DER sequence');
  let l=d[o++];
  if(l&0x80){const n=l&0x7f;l=0;for(let i=0;i<n;i++)l=(l<<8)|d[o++];}
  if(d[o++]!==0x02)throw new Error('bad DER r marker');
  let rL=d[o++],r=d.slice(o,o+rL);o+=rL;
  if(d[o++]!==0x02)throw new Error('bad DER s marker');
  let sL=d[o++],s=d.slice(o,o+sL);
  if(r[0]===0)r=r.slice(1);
  if(s[0]===0)s=s.slice(1);
  const out=Buffer.alloc(64,0);
  r.copy(out,32-r.length);s.copy(out,64-s.length);
  return out;
}
function makeToken(){
  if (!KEY_ID || !ISSUER_ID) throw new Error('APP_STORE_ASC_KEY_ID and APP_STORE_ASC_ISSUER_ID required');
  const keyPem = KEY_P8 || (KEY_PATH && fs.readFileSync(KEY_PATH,'utf8'));
  if (!keyPem) throw new Error('APP_STORE_ASC_KEY_P8 or APP_STORE_ASC_KEY_PATH required');
  const header=b64u(JSON.stringify({alg:'ES256',kid:KEY_ID,typ:'JWT'}));
  const now=Math.floor(Date.now()/1000);
  const claims=b64u(JSON.stringify({iss:ISSUER_ID,iat:now,exp:now+1200,aud:'appstoreconnect-v1'}));
  const si=header+'.'+claims;
  const sg=crypto.createSign('SHA256');sg.update(si);
  return si+'.'+b64u(derToJose(sg.sign(keyPem)));
}

function isTrustedUploadHost(hostname) {
  const host = String(hostname || '').toLowerCase();
  if (TRUSTED_UPLOAD_HOST_SUFFIXES.some((suffix) => host === suffix.slice(1) || host.endsWith(suffix))) {
    return true;
  }
  if (host === 's3.amazonaws.com' || host.endsWith('.s3.amazonaws.com')) return true;
  if (host === 's3-accelerate.amazonaws.com' || host.endsWith('.s3-accelerate.amazonaws.com')) return true;
  if (/^s3[.-][a-z0-9-]+\.amazonaws\.com$/.test(host)) return true;
  if (/^[a-z0-9.-]+\.s3[.-][a-z0-9-]+\.amazonaws\.com$/.test(host)) return true;
  return false;
}

function ascApi(method, p, body, token, extraHeaders={}) {
  return new Promise((resolve, reject) => {
    const opts = {
      method, hostname:'api.appstoreconnect.apple.com', path: p,
      headers: { Authorization:`Bearer ${token}`, Accept:'application/json', ...extraHeaders },
    };
    if (body !== undefined) {
      const j = JSON.stringify(body);
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(j);
    }
    const req = https.request(opts, (res) => {
      let c = ''; res.on('data',(d)=>c+=d);
      res.on('end',() => {
        if (res.statusCode>=200 && res.statusCode<300) resolve(c?JSON.parse(c):{});
        else reject(new Error(`HTTP ${res.statusCode}: ${c}`));
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(JSON.stringify(body));
    req.end();
  });
}

async function deleteExistingReviewScreenshots(subId, token) {
  const subscription = await ascApi(
    'GET',
    `/v1/subscriptions/${subId}?include=appStoreReviewScreenshot`,
    undefined,
    token,
  );
  const existing = (subscription.included || [])
    .filter((entry) => entry.type === 'subscriptionAppStoreReviewScreenshots');
  for (const screenshot of existing) {
    await ascApi('DELETE', `/v1/subscriptionAppStoreReviewScreenshots/${screenshot.id}`, undefined, token);
    console.log(`  deleted prior screenshot ${screenshot.id}`);
  }
}

function putBytes(uploadUrl, headersList, bytes) {
  const u = new URL(uploadUrl);
  if (u.protocol !== 'https:') {
    throw new Error(`Refusing non-HTTPS App Store upload operation: ${u.protocol}`);
  }
  if (u.username || u.password) {
    throw new Error('Refusing App Store upload operation with URL credentials.');
  }
  if (!isTrustedUploadHost(u.hostname)) {
    throw new Error(`Refusing App Store upload operation for unexpected host: ${u.hostname}`);
  }
  return new Promise((resolve, reject) => {
    const headers = {};
    for (const h of headersList) headers[h.name] = h.value;
    headers['Content-Length'] = bytes.length;
    const opts = { method: 'PUT', hostname: u.hostname, port: u.port || undefined, path: u.pathname + u.search, headers };
    const req = https.request(opts, (res) => {
      let c = ''; res.on('data',(d)=>c+=d);
      res.on('end',() => {
        if (res.statusCode>=200 && res.statusCode<300) resolve();
        else reject(new Error(`PUT ${res.statusCode}: ${c}`));
      });
    });
    req.on('error', reject);
    req.write(bytes);
    req.end();
  });
}

async function uploadFor(subId, imagePath, token, dryRun) {
  console.log(`\n→ subscription ${subId}`);
  const fileName = path.basename(imagePath);
  const bytes = fs.readFileSync(imagePath);
  const fileSize = bytes.length;
  if (dryRun) {
    console.log(`  [DRY] would upload ${fileName} (${fileSize} bytes) for sub ${subId}`);
    return;
  }
  await deleteExistingReviewScreenshots(subId, token);
  // 1. Create the screenshot reservation.
  const createBody = {
    data: {
      type: 'subscriptionAppStoreReviewScreenshots',
      attributes: { fileName, fileSize },
      relationships: {
        subscription: { data: { type: 'subscriptions', id: subId } },
      },
    },
  };
  const created = await ascApi('POST', '/v1/subscriptionAppStoreReviewScreenshots', createBody, token);
  const reservation = created.data;
  console.log(`  reservation id=${reservation.id}`);
  const ops = reservation.attributes.uploadOperations || [];
  for (const op of ops) {
    const slice = bytes.slice(op.offset, op.offset + op.length);
    await putBytes(op.url, op.requestHeaders, slice);
    console.log(`  PUT chunk offset=${op.offset} length=${op.length} OK`);
  }
  // 3. Commit.
  const md5 = crypto.createHash('md5').update(bytes).digest('hex');
  await ascApi('PATCH', `/v1/subscriptionAppStoreReviewScreenshots/${reservation.id}`, {
    data: { id: reservation.id, type: 'subscriptionAppStoreReviewScreenshots',
      attributes: { uploaded: true, sourceFileChecksum: md5 } },
  }, token);
  console.log('  commit OK');
}

function defaultImagePath(productId) {
  if (IMAGE_OVERRIDE) return IMAGE_OVERRIDE;
  if (!REVIEW_SCREENSHOT_BY_PRODUCT_ID[productId]) {
    throw new Error(`No review screenshot mapping for product ${productId}`);
  }
  return path.join(process.cwd(), '.appstore-screenshots', REVIEW_SCREENSHOT_BY_PRODUCT_ID[productId]);
}

async function listCommercialSubscriptions(token) {
  const resp = await ascApi(
    'GET',
    `/v1/apps/${APP_ID}/subscriptionGroups?limit=200&include=subscriptions`,
    undefined,
    token,
  );
  const subscriptions = (resp.included || [])
    .filter((entry) => entry.type === 'subscriptions')
    .map((entry) => ({
      id: entry.id,
      productId: entry.attributes && entry.attributes.productId,
      name: entry.attributes && entry.attributes.name,
      state: entry.attributes && entry.attributes.state,
    }));
  const byProductId = new Map(subscriptions.map((subscription) => [subscription.productId, subscription]));
  return TARGET_PRODUCT_IDS.map((productId) => {
    const subscription = byProductId.get(productId);
    return subscription || { productId, missing: true };
  });
}

async function listCommercialInAppPurchases(token) {
  const resp = await ascApi(
    'GET',
    `/v1/apps/${APP_ID}/inAppPurchasesV2?limit=200`,
    undefined,
    token,
  );
  const purchases = (resp.data || [])
    .map((entry) => ({
      id: entry.id,
      productId: entry.attributes && entry.attributes.productId,
      name: entry.attributes && entry.attributes.name,
      state: entry.attributes && entry.attributes.state,
      type: entry.attributes && entry.attributes.inAppPurchaseType,
    }));
  const byProductId = new Map(purchases.map((purchase) => [purchase.productId, purchase]));
  return TOP_UP_PRODUCTS.map((product) => {
    const purchase = byProductId.get(product.productId);
    return purchase ? { ...product, ...purchase } : { ...product, missing: true };
  });
}

async function ensureInAppPurchaseLocalization(iap, token, dryRun) {
  if (dryRun) {
    console.log(`  [DRY] would ensure in-app purchase localization en-US: ${iap.name}`);
    return;
  }
  const existing = await ascApi(
    'GET',
    `/v2/inAppPurchases/${iap.id}/inAppPurchaseLocalizations?limit=20`,
    undefined,
    token,
  );
  const current = (existing.data || []).find((entry) => entry.attributes && entry.attributes.locale === 'en-US');
  if (current) {
    const attrs = current.attributes || {};
    if (attrs.name === iap.name && attrs.description === iap.description) {
      console.log(`  in-app purchase localization en-US already exists`);
      return;
    }
    await ascApi('PATCH', `/v1/inAppPurchaseLocalizations/${current.id}`, {
      data: {
        id: current.id,
        type: 'inAppPurchaseLocalizations',
        attributes: { name: iap.name, description: iap.description },
      },
    }, token);
    console.log(`  in-app purchase localization en-US updated`);
    return;
  }
  await ascApi('POST', '/v1/inAppPurchaseLocalizations', {
    data: {
      type: 'inAppPurchaseLocalizations',
      attributes: { locale: 'en-US', name: iap.name, description: iap.description },
      relationships: {
        inAppPurchaseV2: { data: { type: 'inAppPurchases', id: iap.id } },
      },
    },
  }, token);
  console.log(`  in-app purchase localization en-US created`);
}

async function deleteExistingInAppPurchaseReviewScreenshots(iapId, token) {
  const response = await ascApi(
    'GET',
    `/v2/inAppPurchases/${iapId}?include=appStoreReviewScreenshot`,
    undefined,
    token,
  );
  const existing = (response.included || [])
    .filter((entry) => entry.type === 'inAppPurchaseAppStoreReviewScreenshots');
  for (const screenshot of existing) {
    await ascApi('DELETE', `/v1/inAppPurchaseAppStoreReviewScreenshots/${screenshot.id}`, undefined, token);
    console.log(`  deleted prior in-app purchase screenshot ${screenshot.id}`);
  }
}

async function uploadInAppPurchaseScreenshotFor(iap, imagePath, token, dryRun) {
  console.log(`\n→ in-app purchase ${iap.productId}`);
  const fileName = path.basename(imagePath);
  const bytes = fs.readFileSync(imagePath);
  const fileSize = bytes.length;
  if (dryRun) {
    console.log(`  [DRY] would upload ${fileName} (${fileSize} bytes) for IAP ${iap.id}`);
    return;
  }
  await deleteExistingInAppPurchaseReviewScreenshots(iap.id, token);
  const created = await ascApi('POST', '/v1/inAppPurchaseAppStoreReviewScreenshots', {
    data: {
      type: 'inAppPurchaseAppStoreReviewScreenshots',
      attributes: { fileName, fileSize },
      relationships: {
        inAppPurchaseV2: { data: { type: 'inAppPurchases', id: iap.id } },
      },
    },
  }, token);
  const reservation = created.data;
  console.log(`  reservation id=${reservation.id}`);
  const ops = reservation.attributes.uploadOperations || [];
  for (const op of ops) {
    const slice = bytes.slice(op.offset, op.offset + op.length);
    await putBytes(op.url, op.requestHeaders, slice);
    console.log(`  PUT chunk offset=${op.offset} length=${op.length} OK`);
  }
  const md5 = crypto.createHash('md5').update(bytes).digest('hex');
  await ascApi('PATCH', `/v1/inAppPurchaseAppStoreReviewScreenshots/${reservation.id}`, {
    data: {
      id: reservation.id,
      type: 'inAppPurchaseAppStoreReviewScreenshots',
      attributes: { uploaded: true, sourceFileChecksum: md5 },
    },
  }, token);
  console.log('  commit OK');
}

async function main() {
  const token = makeToken();
  console.log(`mode: ${APPLY ? 'APPLY' : 'DRY-RUN'}  app=${APP_ID}`);
  const targets = await listCommercialSubscriptions(token);
  for (const target of targets) {
    if (target.missing) {
      console.log(`\n→ ${target.productId}`);
      console.log('  missing subscription; skipping review screenshot upload');
      continue;
    }
    const imagePath = defaultImagePath(target.productId);
    if (!fs.existsSync(imagePath)) throw new Error(`image not found: ${imagePath}`);
    console.log(`  target ${target.productId} (${target.name || 'unnamed'}, state=${target.state || 'unknown'})`);
    await uploadFor(target.id, imagePath, token, !APPLY);
  }
  const topUps = await listCommercialInAppPurchases(token);
  for (const topUp of topUps) {
    if (topUp.missing) {
      console.log(`\n→ ${topUp.productId}`);
      console.log('  missing in-app purchase; skipping localization and review screenshot upload');
      continue;
    }
    const imagePath = defaultImagePath(topUp.productId);
    if (!fs.existsSync(imagePath)) throw new Error(`image not found: ${imagePath}`);
    console.log(`  target ${topUp.productId} (${topUp.name || 'unnamed'}, state=${topUp.state || 'unknown'})`);
    await ensureInAppPurchaseLocalization(topUp, token, !APPLY);
    await uploadInAppPurchaseScreenshotFor(topUp, imagePath, token, !APPLY);
  }
  console.log(APPLY
    ? '\nReview screenshots uploaded. Check ASC state in a few seconds.'
    : '\nDry-run complete. Add --apply to upload.');
}

module.exports = {
  derToJose,
  isTrustedUploadHost,
  defaultImagePath,
  main,
};

if (require.main === module) {
  main().catch((e) => { console.error(e.message || e); process.exit(1); });
}
