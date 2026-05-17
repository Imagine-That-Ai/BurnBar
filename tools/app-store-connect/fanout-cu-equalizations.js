#!/usr/bin/env node
/**
 * Set prices in EVERY Apple territory for the Computer Use IAPs using
 * Apple's `/equalizations` endpoint — each USA base price point has
 * 174 equivalent territory-specific price points pre-computed by
 * Apple. We POST one subscriptionPrice per territory.
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
  { sub: '6770276669', usaBasePricePoint: 'eyJzIjoiNjc3MDI3NjY2OSIsInQiOiJVU0EiLCJwIjoiMTAxNTIifQ', usaPrice: '14.99' },
  { sub: '6770276926', usaBasePricePoint: 'eyJzIjoiNjc3MDI3NjkyNiIsInQiOiJVU0EiLCJwIjoiMTAyMDIifQ', usaPrice: '24.99' },
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

async function listEqualizations(basePP, token) {
  const out = [];
  let next = `/v1/subscriptionPricePoints/${basePP}/equalizations?limit=200`;
  while (next) {
    const resp = await api('GET', next, undefined, token);
    for (const pp of resp.data || []) {
      const decoded = JSON.parse(Buffer.from(pp.id, 'base64').toString());
      out.push({ pricePointId: pp.id, territory: decoded.t });
    }
    next = resp.links && resp.links.next
      ? resp.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
  }
  return out;
}

async function ensurePrice(sub, territory, pricePointId, token) {
  for (let attempt = 0; attempt < 4; attempt++) {
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
      if (e.message.includes('HTTP 429')) {
        await new Promise((r) => setTimeout(r, 2000 * (attempt + 1)));
        continue;
      }
      return `err:${e.message.substring(0, 60)}`;
    }
  }
  return 'err:rate_limit_exhausted';
}

(async () => {
  const token = makeToken();
  for (const t of TARGETS) {
    console.log(`\n→ sub=${t.sub}  USA base=$${t.usaPrice}`);
    const equiv = await listEqualizations(t.usaBasePricePoint, token);
    console.log(`  ${equiv.length} equivalent price points across territories`);

    if (!APPLY) {
      console.log(`  [DRY] would post ${equiv.length} subscriptionPrices`);
      continue;
    }

    let ok = 0, exists = 0, err = 0;
    const concurrency = 3;
    for (let i = 0; i < equiv.length; i += concurrency) {
      const slice = equiv.slice(i, i + concurrency);
      const results = await Promise.all(slice.map((e) =>
        ensurePrice(t.sub, e.territory, e.pricePointId, token)
      ));
      for (const r of results) {
        if (r === 'ok') ok++;
        else if (r === 'exists') exists++;
        else { err++; if (err < 5) console.log(`    ${r}`); }
      }
      process.stdout.write(`  ${i + slice.length}/${equiv.length}…\r`);
      // Small gap to stay under ASC's rate limit.
      await new Promise((r) => setTimeout(r, 250));
    }
    console.log(`\n  ${ok} added · ${exists} already · ${err} errored`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
