#!/usr/bin/env node
/**
 * Fan out pricing across every supported territory for the Computer
 * Use IAPs. Apple's API requires explicit per-territory pricing before
 * a subscription can move from MISSING_METADATA → READY_TO_SUBMIT.
 *
 * Strategy:
 *   1. Read the existing USA price point's "tier" identifier.
 *   2. For each other territory the subscription is available in,
 *      find that territory's price point at the same tier.
 *   3. POST a subscriptionPrice for that territory + price point.
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');

const KEY_ID = process.env.APP_STORE_ASC_KEY_ID;
const ISSUER_ID = process.env.APP_STORE_ASC_ISSUER_ID;
const KEY_PATH = process.env.APP_STORE_ASC_KEY_PATH;
const APPLY = process.argv.includes('--apply');

const TARGETS = [
  { sub: '6770276669', usaPriceUSD: '14.99' },
  { sub: '6770276926', usaPriceUSD: '24.99' },
];

function b64u(s){return Buffer.from(s).toString('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');}
function derToJose(d){let o=0;if(d[o++]!==0x30)throw'';let l=d[o++];if(l&0x80){const n=l&0x7f;l=0;for(let i=0;i<n;i++)l=(l<<8)|d[o++];}if(d[o++]!==0x02)throw'';let rL=d[o++],r=d.slice(o,o+rL);o+=rL;if(d[o++]!==0x02)throw'';let sL=d[o++],s=d.slice(o,o+sL);if(r[0]===0)r=r.slice(1);if(s[0]===0)s=s.slice(1);const out=Buffer.alloc(64,0);r.copy(out,32-r.length);s.copy(out,64-s.length);return out;}
function makeToken(){
  const keyPem=fs.readFileSync(KEY_PATH,'utf8');
  const header=b64u(JSON.stringify({alg:'ES256',kid:KEY_ID,typ:'JWT'}));
  const now=Math.floor(Date.now()/1000);
  const claims=b64u(JSON.stringify({iss:ISSUER_ID,iat:now,exp:now+1200,aud:'appstoreconnect-v1'}));
  const si=header+'.'+claims;
  const sg=crypto.createSign('SHA256');sg.update(si);
  return si+'.'+b64u(derToJose(sg.sign(keyPem)));
}
function api(method,path,body,token){
  return new Promise((res,rej)=>{
    const opts={method,hostname:'api.appstoreconnect.apple.com',path,headers:{Authorization:`Bearer ${token}`,Accept:'application/json'}};
    if(body!==undefined){const j=JSON.stringify(body);opts.headers['Content-Type']='application/json';opts.headers['Content-Length']=Buffer.byteLength(j);}
    const r=https.request(opts,(rsp)=>{let c='';rsp.on('data',d=>c+=d);rsp.on('end',()=>{if(rsp.statusCode>=200&&rsp.statusCode<300){res(c?JSON.parse(c):{});}else{rej(new Error(`HTTP ${rsp.statusCode}: ${c.substring(0,300)}`));}});});
    r.on('error',rej);if(body!==undefined)r.write(JSON.stringify(body));r.end();
  });
}

async function listAllPricePointsForTerritory(sub, territory, token) {
  const out = [];
  let next = `/v1/subscriptions/${sub}/pricePoints?filter[territory]=${territory}&limit=200`;
  while (next) {
    const resp = await api('GET', next, undefined, token);
    out.push(...(resp.data || []));
    next = resp.links && resp.links.next
      ? resp.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
  }
  return out;
}

async function listAvailableTerritories(sub, token) {
  // The /subscriptionAvailability endpoint doesn't accept &limit.
  const resp = await api(
    'GET',
    `/v1/subscriptions/${sub}/subscriptionAvailability?include=availableTerritories`,
    undefined, token,
  );
  const out = [];
  for (const t of resp.included || []) {
    if (t.type === 'territories') out.push(t.id);
  }
  return out;
}

async function ensurePrice(sub, territory, pricePointId, token) {
  try {
    await api('POST', '/v1/subscriptionPrices', {
      data: {
        type: 'subscriptionPrices',
        attributes: { preserveCurrentPrice: false },
        relationships: {
          subscription: { data: { type: 'subscriptions', id: sub } },
          subscriptionPricePoint: { data: { type: 'subscriptionPricePoints', id: pricePointId } },
          territory: { data: { type: 'territories', id: territory } },
        },
      },
    }, token);
    return 'ok';
  } catch (e) {
    if (e.message.includes('HTTP 409')) return 'exists';
    return `err: ${e.message.substring(0, 80)}`;
  }
}

(async () => {
  const token = makeToken();
  for (const t of TARGETS) {
    console.log(`\n→ sub=${t.sub}  USA=$${t.usaPriceUSD}`);

    // 1. USA price points: find the matching tier id.
    const usaPP = await listAllPricePointsForTerritory(t.sub, 'USA', token);
    const usaMatch = usaPP.find((p) => p.attributes.customerPrice === t.usaPriceUSD);
    if (!usaMatch) {
      console.error(`  could not find USA price point for $${t.usaPriceUSD}`);
      continue;
    }
    // The price-point id is opaque; the "p" field inside the base64 is
    // Apple's tier number. Decode it.
    let usaJson;
    try { usaJson = JSON.parse(Buffer.from(usaMatch.id, 'base64').toString()); } catch (_) {}
    const tier = usaJson && usaJson.p;
    console.log(`  USA price point ${usaMatch.id} tier=${tier}`);

    // 2. Fetch availability list.
    const territories = await listAvailableTerritories(t.sub, token);
    console.log(`  ${territories.length} territories enabled`);

    if (!APPLY) {
      console.log(`  [DRY] would fan out ${territories.length} prices at tier=${tier}`);
      continue;
    }

    // 3. For each non-USA territory, find that territory's price point
    //    with the same tier (Apple's matrix is opaque — query each).
    let ok = 0, exists = 0, err = 0;
    for (const territory of territories) {
      if (territory === 'USA') { exists++; continue; }
      const pp = await listAllPricePointsForTerritory(t.sub, territory, token);
      const match = pp.find((p) => {
        try {
          const j = JSON.parse(Buffer.from(p.id, 'base64').toString());
          return j.p === tier;
        } catch (_) { return false; }
      });
      if (!match) { err++; console.log(`    ${territory}: no matching tier`); continue; }
      const result = await ensurePrice(t.sub, territory, match.id, token);
      if (result === 'ok') ok++;
      else if (result === 'exists') exists++;
      else { err++; console.log(`    ${territory}: ${result}`); }
    }
    console.log(`  ${ok} added · ${exists} already · ${err} errored`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
