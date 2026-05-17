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
const KEY_PATH = process.env.APP_STORE_ASC_KEY_PATH;

const args = process.argv.slice(2);
const IMAGE = (() => {
  const i = args.indexOf('--image');
  return i >= 0 ? args[i + 1] : null;
})();
const APPLY = args.includes('--apply');

const TARGET_SUBS = [
  '6770276669', // com.openburnbar.hostedComputerUseSync.monthly
  '6770276926', // com.openburnbar.proMax.monthly
];

function b64u(s) { return Buffer.from(s).toString('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_'); }
function derToJose(d){let o=0;if(d[o++]!==0x30)throw'';let l=d[o++];if(l&0x80){const n=l&0x7f;l=0;for(let i=0;i<n;i++)l=(l<<8)|d[o++];}if(d[o++]!==0x02)throw'';let rL=d[o++],r=d.slice(o,o+rL);o+=rL;if(d[o++]!==0x02)throw'';let sL=d[o++],s=d.slice(o,o+sL);if(r[0]===0)r=r.slice(1);if(s[0]===0)s=s.slice(1);const out=Buffer.alloc(64,0);r.copy(out,32-r.length);s.copy(out,64-s.length);return out;}
function makeToken(){
  const keyPem = fs.readFileSync(KEY_PATH,'utf8');
  const header=b64u(JSON.stringify({alg:'ES256',kid:KEY_ID,typ:'JWT'}));
  const now=Math.floor(Date.now()/1000);
  const claims=b64u(JSON.stringify({iss:ISSUER_ID,iat:now,exp:now+1200,aud:'appstoreconnect-v1'}));
  const si=header+'.'+claims;
  const sg=crypto.createSign('SHA256');sg.update(si);
  return si+'.'+b64u(derToJose(sg.sign(keyPem)));
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

function putBytes(uploadUrl, headersList, bytes) {
  return new Promise((resolve, reject) => {
    const u = new URL(uploadUrl);
    const headers = {};
    for (const h of headersList) headers[h.name] = h.value;
    headers['Content-Length'] = bytes.length;
    const opts = { method: 'PUT', hostname: u.hostname, path: u.pathname + u.search, headers };
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
  const fileSize = fs.statSync(imagePath).size;
  const fileName = path.basename(imagePath);
  if (dryRun) {
    console.log(`  [DRY] would upload ${fileName} (${fileSize} bytes) for sub ${subId}`);
    return;
  }
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
  const bytes = fs.readFileSync(imagePath);
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

(async () => {
  if (!IMAGE) {
    console.error('--image PATH required (1024×1024 PNG recommended)');
    process.exit(2);
  }
  if (!fs.existsSync(IMAGE)) {
    console.error(`image not found: ${IMAGE}`);
    process.exit(2);
  }
  if (!KEY_ID || !ISSUER_ID || !KEY_PATH) {
    console.error('APP_STORE_ASC_KEY_ID, APP_STORE_ASC_ISSUER_ID, APP_STORE_ASC_KEY_PATH required');
    process.exit(2);
  }
  const token = makeToken();
  console.log(`mode: ${APPLY ? 'APPLY' : 'DRY-RUN'}  image=${IMAGE}`);
  for (const sub of TARGET_SUBS) {
    await uploadFor(sub, IMAGE, token, !APPLY);
  }
  console.log(APPLY
    ? '\nReview screenshots uploaded. Check ASC state in a few seconds.'
    : '\nDry-run complete. Add --apply to upload.');
})().catch((e) => { console.error(e); process.exit(1); });
