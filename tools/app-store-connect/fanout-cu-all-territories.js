#!/usr/bin/env node
/**
 * Brute-force version of fanout: prices Computer Use IAPs in ALL 175
 * Apple territories at the price tier matching the USA base price.
 *
 * Required env: APP_STORE_ASC_KEY_ID, APP_STORE_ASC_ISSUER_ID, APP_STORE_ASC_KEY_PATH
 * Flag --apply to actually write.
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
    const r=https.request(opts,(rsp)=>{let c='';rsp.on('data',d=>c+=d);rsp.on('end',()=>{if(rsp.statusCode>=200&&rsp.statusCode<300){res(c?JSON.parse(c):{});}else{rej(new Error(`HTTP ${rsp.statusCode}: ${c.substring(0,200)}`));}});});
    r.on('error',rej);if(body!==undefined)r.write(JSON.stringify(body));r.end();
  });
}

async function listAllPricePointsForTerritory(sub, territory, token) {
  const out = [];
  let next = `/v1/subscriptions/${sub}/pricePoints?filter[territory]=${territory}`;
  while (next) {
    let resp;
    try { resp = await api('GET', next, undefined, token); }
    catch (e) { return out; }
    out.push(...(resp.data || []));
    next = resp.links && resp.links.next
      ? resp.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
  }
  return out;
}

async function listAllTerritories(token) {
  const out = [];
  let next = '/v1/territories?limit=200';
  while (next) {
    const resp = await api('GET', next, undefined, token);
    out.push(...(resp.data || []).map((x) => x.id));
    next = resp.links && resp.links.next
      ? resp.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
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
    return `err:${e.message.substring(0, 60)}`;
  }
}

(async () => {
  const token = makeToken();
  console.log('Listing all territories…');
  const territories = await listAllTerritories(token);
  console.log(`  ${territories.length} territories total`);

  for (const t of TARGETS) {
    console.log(`\n→ sub=${t.sub}  USA tier @ $${t.usaPriceUSD}`);
    const usaPP = await listAllPricePointsForTerritory(t.sub, 'USA', token);
    const match = usaPP.find((p) => p.attributes.customerPrice === t.usaPriceUSD);
    if (!match) { console.error(`  no USA price point for $${t.usaPriceUSD}`); continue; }
    let usaJson; try { usaJson = JSON.parse(Buffer.from(match.id, 'base64').toString()); } catch (_) {}
    const tier = usaJson && usaJson.p;
    console.log(`  USA tier=${tier}`);

    if (!APPLY) {
      console.log(`  [DRY] fan out ${territories.length} territories at tier=${tier}`);
      continue;
    }

    let ok = 0, exists = 0, err = 0, notier = 0;
    const concurrency = 8;
    for (let i = 0; i < territories.length; i += concurrency) {
      const slice = territories.slice(i, i + concurrency);
      const results = await Promise.all(slice.map(async (territory) => {
        const pp = await listAllPricePointsForTerritory(t.sub, territory, token);
        const m = pp.find((p) => {
          try { return JSON.parse(Buffer.from(p.id, 'base64').toString()).p === tier; }
          catch (_) { return false; }
        });
        if (!m) return 'notier';
        return ensurePrice(t.sub, territory, m.id, token);
      }));
      for (const r of results) {
        if (r === 'ok') ok++;
        else if (r === 'exists') exists++;
        else if (r === 'notier') notier++;
        else err++;
      }
      process.stdout.write(`  ${i + slice.length}/${territories.length}…\r`);
    }
    console.log(`\n  ${ok} added · ${exists} already · ${notier} no-tier · ${err} errored`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
