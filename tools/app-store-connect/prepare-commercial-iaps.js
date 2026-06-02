#!/usr/bin/env node
/**
 * Idempotently prepare the GTM commercial App Store products.
 *
 * This covers the metadata Apple requires before products leave
 * MISSING_METADATA: subscription metadata/localization, availability,
 * all-territory subscription prices, Cloud introductory trials, consumable
 * localization, consumable availability, and consumable base pricing.
 *
 * It intentionally does not create subscriptions. Missing products are
 * reported so the operator can recover/create them in ASC.
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
const APPLY = process.argv.includes('--apply');

const SUBSCRIPTIONS = [
  {
    productId: 'com.openburnbar.pro.monthly',
    name: 'OpenBurnBar Cloud Monthly',
    priceUSD: '7.99',
    groupLevel: 1,
    trial: true,
    localizationName: 'BurnBar Cloud',
    localizationDescription: 'Quota, conversations, search, and agent memory sync.',
    reviewNote:
      'BurnBar Cloud syncs quota refresh, encrypted conversations, cloud search, agent memory, and remote companion state across signed-in devices. It has a 14-day free trial for new subscribers; after trial it renews monthly at the displayed App Store price. In app: You tab -> Settings -> OpenBurnBar Cloud.',
  },
  {
    productId: 'com.openburnbar.pro.annual',
    name: 'OpenBurnBar Cloud Annual',
    priceUSD: '79.00',
    groupLevel: 1,
    trial: true,
    localizationName: 'BurnBar Cloud',
    localizationDescription: 'Annual quota, history, search, and memory sync.',
    reviewNote:
      'Annual BurnBar Cloud subscription. Same Cloud features as monthly: quota refresh, encrypted conversations, cloud search, agent memory, and remote companion state. It has a 14-day free trial for new subscribers; after trial it renews annually at the displayed App Store price.',
  },
  {
    productId: 'com.openburnbar.proMax.v2.monthly',
    name: 'OpenBurnBar Cloud Pro Monthly',
    priceUSD: '24.99',
    groupLevel: 1,
    trial: false,
    localizationName: 'BurnBar Cloud Pro',
    localizationDescription: 'Cloud plus Floo and supervised Agent Control.',
    reviewNote:
      'BurnBar Cloud Pro includes BurnBar Cloud plus Floo phone-to-Mac workflows and supervised Agent Control. Included hosted allowance resets monthly: 500 Agent Control actions and 50 GB Floo relay accounting. Extra hosted usage is prepaid with consumable top-ups. No free trial.',
  },
  {
    productId: 'com.openburnbar.proMax.annual',
    name: 'OpenBurnBar Cloud Pro Annual',
    priceUSD: '249.00',
    groupLevel: 1,
    trial: false,
    localizationName: 'BurnBar Cloud Pro',
    localizationDescription: 'Cloud plus Floo and supervised Agent Control.',
    reviewNote:
      'BurnBar Cloud Pro includes BurnBar Cloud plus Floo phone-to-Mac workflows and supervised Agent Control. Included hosted allowance resets monthly: 500 Agent Control actions and 50 GB Floo relay accounting. Extra hosted usage is prepaid with consumable top-ups. No free trial.',
  },
];

const TOP_UPS = [
  {
    productId: 'com.openburnbar.agentControl.actions100',
    name: 'Agent Control 100 Actions',
    description: 'Adds 100 hosted Agent Control actions.',
    priceUSD: '4.99',
    reviewNote:
      'Consumable top-up for BurnBar Cloud Pro subscribers. Adds 100 hosted Agent Control actions to the signed-in user allowance ledger. In app: You tab -> Settings -> OpenBurnBar Cloud Pro -> Agent Control top-ups.',
  },
  {
    productId: 'com.openburnbar.floo.relay50gb',
    name: 'Floo Relay 50 GB',
    description: 'Adds 50 GB of Floo relay bandwidth.',
    priceUSD: '4.99',
    reviewNote:
      'Consumable top-up for BurnBar Cloud Pro subscribers. Adds 50 GB of Floo relay bandwidth allowance to the signed-in user ledger. In app: You tab -> Settings -> OpenBurnBar Cloud Pro -> Floo Relay top-ups.',
  },
];

function b64u(value) {
  return Buffer.from(value).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function derToJose(der) {
  let offset = 0;
  if (der[offset++] !== 0x30) throw new Error('bad DER');
  let len = der[offset++];
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | der[offset++];
  }
  if (der[offset++] !== 0x02) throw new Error('bad DER r');
  let rLen = der[offset++];
  let r = der.slice(offset, offset + rLen);
  offset += rLen;
  if (der[offset++] !== 0x02) throw new Error('bad DER s');
  let sLen = der[offset++];
  let s = der.slice(offset, offset + sLen);
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
    iss: ISSUER_ID,
    iat: now,
    exp: now + 1200,
    aud: 'appstoreconnect-v1',
  }));
  const input = `${header}.${claims}`;
  const signer = crypto.createSign('SHA256');
  signer.update(input);
  return `${input}.${b64u(derToJose(signer.sign(keyPem)))}`;
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
    let json;
    if (body !== undefined) {
      json = JSON.stringify(body);
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(json);
    }
    const req = https.request(opts, (res) => {
      let content = '';
      res.on('data', (chunk) => { content += chunk; });
      res.on('end', () => {
        const parsed = content ? JSON.parse(content) : {};
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(parsed);
        } else {
          const error = new Error(`HTTP ${res.statusCode}: ${content}`);
          error.statusCode = res.statusCode;
          error.payload = parsed;
          reject(error);
        }
      });
    });
    req.on('error', reject);
    if (json) req.write(json);
    req.end();
  });
}

async function listAll(path, token) {
  const out = [];
  let next = path;
  while (next) {
    const response = await api('GET', next, undefined, token);
    out.push(...(response.data || []));
    next = response.links && response.links.next
      ? response.links.next.replace('https://api.appstoreconnect.apple.com', '')
      : null;
  }
  return out;
}

async function listTerritoryIds(token) {
  const territories = await listAll('/v1/territories?limit=200', token);
  return territories.map((territory) => territory.id).sort();
}

async function listSubscriptionsByProduct(token) {
  const response = await api(
    'GET',
    `/v1/apps/${APP_ID}/subscriptionGroups?include=subscriptions&limit=200`,
    undefined,
    token,
  );
  const subscriptions = (response.included || [])
    .filter((entry) => entry.type === 'subscriptions');
  return new Map(subscriptions.map((subscription) => [
    subscription.attributes.productId,
    subscription,
  ]));
}

async function listInAppPurchasesByProduct(token) {
  const purchases = await listAll(`/v1/apps/${APP_ID}/inAppPurchasesV2?limit=200`, token);
  return new Map(purchases.map((purchase) => [purchase.attributes.productId, purchase]));
}

async function maybeWrite(label, fn) {
  if (!APPLY) {
    console.log(`  [DRY] ${label}`);
    return null;
  }
  console.log(`  [APPLY] ${label}`);
  return fn();
}

async function ensureSubscriptionMetadata(subscription, target, token) {
  await maybeWrite(`PATCH subscription metadata ${target.productId}`, () => api(
    'PATCH',
    `/v1/subscriptions/${subscription.id}`,
    {
      data: {
        id: subscription.id,
        type: 'subscriptions',
        attributes: {
          name: target.name,
          reviewNote: target.reviewNote,
          groupLevel: target.groupLevel,
          familySharable: false,
        },
      },
    },
    token,
  ));

  const localizations = await listAll(
    `/v1/subscriptions/${subscription.id}/subscriptionLocalizations?limit=20`,
    token,
  );
  const current = localizations.find((entry) => entry.attributes.locale === 'en-US');
  if (current) {
    await maybeWrite(`PATCH subscription localization ${current.id}`, () => api(
      'PATCH',
      `/v1/subscriptionLocalizations/${current.id}`,
      {
        data: {
          id: current.id,
          type: 'subscriptionLocalizations',
          attributes: {
            name: target.localizationName,
            description: target.localizationDescription,
          },
        },
      },
      token,
    ));
  } else {
    await maybeWrite(`POST subscription localization en-US`, () => api(
      'POST',
      '/v1/subscriptionLocalizations',
      {
        data: {
          type: 'subscriptionLocalizations',
          attributes: {
            locale: 'en-US',
            name: target.localizationName,
            description: target.localizationDescription,
          },
          relationships: {
            subscription: { data: { type: 'subscriptions', id: subscription.id } },
          },
        },
      },
      token,
    ));
  }
}

async function ensureSubscriptionAvailability(subscription, territoryIds, token) {
  try {
    await api('GET', `/v1/subscriptions/${subscription.id}/subscriptionAvailability`, undefined, token);
    return;
  } catch (error) {
    if (error.statusCode !== 404) throw error;
  }

  await maybeWrite(`POST subscriptionAvailability ${subscription.attributes.productId}`, () => api(
    'POST',
    '/v1/subscriptionAvailabilities',
    {
      data: {
        type: 'subscriptionAvailabilities',
        attributes: { availableInNewTerritories: true },
        relationships: {
          subscription: { data: { type: 'subscriptions', id: subscription.id } },
          availableTerritories: {
            data: territoryIds.map((territory) => ({ type: 'territories', id: territory })),
          },
        },
      },
    },
    token,
  ));
}

async function findSubscriptionPricePoint(subscriptionId, territory, priceUSD, token) {
  const targetPrice = Number(priceUSD);
  const points = await listAll(
    `/v1/subscriptions/${subscriptionId}/pricePoints?filter[territory]=${territory}&limit=200`,
    token,
  );
  return points.find((point) => Number(point.attributes.customerPrice) === targetPrice);
}

async function ensureSubscriptionPrice(subscriptionId, territory, pricePointId, token) {
  if (!APPLY) return null;
  return maybeWrite(`POST subscription price ${territory}`, async () => {
    try {
      await api(
        'POST',
        '/v1/subscriptionPrices',
        {
          data: {
            type: 'subscriptionPrices',
            attributes: { preserveCurrentPrice: false },
            relationships: {
              subscription: { data: { type: 'subscriptions', id: subscriptionId } },
              subscriptionPricePoint: {
                data: { type: 'subscriptionPricePoints', id: pricePointId },
              },
              territory: { data: { type: 'territories', id: territory } },
            },
          },
        },
        token,
      );
    } catch (error) {
      if (error.statusCode !== 409) throw error;
    }
  });
}

async function ensureSubscriptionPrices(subscription, target, token) {
  const existingPrices = await countRelationship(
    `/v1/subscriptions/${subscription.id}/relationships/prices?limit=200`,
    token,
  );
  if (existingPrices >= 175) {
    console.log(`  subscription prices already complete (${existingPrices})`);
    return;
  }
  const base = await findSubscriptionPricePoint(subscription.id, 'USA', target.priceUSD, token);
  if (!base) {
    console.log(`  no USA price point matching $${target.priceUSD}`);
    return;
  }
  await ensureSubscriptionPrice(subscription.id, 'USA', base.id, token);

  const equalizations = await listAll(
    `/v1/subscriptionPricePoints/${base.id}/equalizations?limit=200`,
    token,
  );
  for (const pricePoint of equalizations) {
    let territory;
    try {
      territory = JSON.parse(Buffer.from(pricePoint.id, 'base64').toString()).t;
    } catch (_) {
      territory = null;
    }
    if (!territory) continue;
    await ensureSubscriptionPrice(subscription.id, territory, pricePoint.id, token);
  }
}

async function ensureSubscriptionTrials(subscription, target, token) {
  if (!target.trial) return;
  const availability = await api(
    'GET',
    `/v1/subscriptions/${subscription.id}/subscriptionAvailability`,
    undefined,
    token,
  );
  const territoryRefs = await listAll(
    `/v1/subscriptionAvailabilities/${availability.data.id}/relationships/availableTerritories?limit=200`,
    token,
  );
  const existingOffers = await listAll(
    `/v1/subscriptions/${subscription.id}/introductoryOffers?limit=200`,
    token,
  );
  if (existingOffers.length >= territoryRefs.length) {
    console.log(`  introductory offers already complete (${existingOffers.length})`);
    return;
  }
  const existingTerritories = new Set(existingOffers.map((offer) => (
    offer.relationships &&
    offer.relationships.territory &&
    offer.relationships.territory.data &&
    offer.relationships.territory.data.id
  )).filter(Boolean));

  for (const territory of territoryRefs.map((entry) => entry.id)) {
    if (existingTerritories.has(territory)) continue;
    if (!APPLY) continue;
    await maybeWrite(`POST 14-day trial ${territory}`, async () => {
      try {
        await api(
          'POST',
          '/v1/subscriptionIntroductoryOffers',
          {
            data: {
              type: 'subscriptionIntroductoryOffers',
              attributes: {
                startDate: null,
                endDate: null,
                duration: 'TWO_WEEKS',
                offerMode: 'FREE_TRIAL',
                numberOfPeriods: 1,
              },
              relationships: {
                subscription: { data: { type: 'subscriptions', id: subscription.id } },
                territory: { data: { type: 'territories', id: territory } },
              },
            },
          },
          token,
        );
      } catch (error) {
        if (error.statusCode !== 409) throw error;
      }
    });
  }
}

async function countRelationship(path, token) {
  return (await listAll(path, token)).length;
}

async function ensureInAppPurchaseLocalization(iap, target, token) {
  const localizations = await listAll(
    `/v2/inAppPurchases/${iap.id}/inAppPurchaseLocalizations?limit=20`,
    token,
  );
  const current = localizations.find((entry) => entry.attributes.locale === 'en-US');
  const createLocalization = (locale) => maybeWrite(`POST IAP localization ${locale}`, () => api(
    'POST',
    '/v1/inAppPurchaseLocalizations',
    {
      data: {
        type: 'inAppPurchaseLocalizations',
        attributes: { locale, name: target.name, description: target.description },
        relationships: {
          inAppPurchaseV2: { data: { type: 'inAppPurchases', id: iap.id } },
        },
      },
    },
    token,
  ));
  if (current && current.attributes.state === 'REJECTED') {
    const temporaryLocale = 'en-GB';
    const temporary = localizations.find((entry) => entry.attributes.locale === temporaryLocale);
    if (!temporary) {
      await createLocalization(temporaryLocale);
    }
    await maybeWrite(`DELETE rejected IAP localization ${current.id}`, () => api(
      'DELETE',
      `/v1/inAppPurchaseLocalizations/${current.id}`,
      undefined,
      token,
    ));
    await createLocalization('en-US');
    const refreshed = await listAll(
      `/v2/inAppPurchases/${iap.id}/inAppPurchaseLocalizations?limit=20`,
      token,
    );
    const temporaryAfterRepair = refreshed.find(
      (entry) => entry.attributes.locale === temporaryLocale,
    );
    if (temporaryAfterRepair) {
      await maybeWrite(`DELETE temporary IAP localization ${temporaryAfterRepair.id}`, () => api(
        'DELETE',
        `/v1/inAppPurchaseLocalizations/${temporaryAfterRepair.id}`,
        undefined,
        token,
      ));
    }
    return;
  }
  if (current) {
    await maybeWrite(`PATCH IAP localization ${current.id}`, () => api(
      'PATCH',
      `/v1/inAppPurchaseLocalizations/${current.id}`,
      {
        data: {
          id: current.id,
          type: 'inAppPurchaseLocalizations',
          attributes: { name: target.name, description: target.description },
        },
      },
      token,
    ));
  } else {
    await createLocalization('en-US');
  }
}

async function ensureInAppPurchaseMetadata(iap, target, token) {
  await maybeWrite(`PATCH IAP metadata ${target.productId}`, () => api(
    'PATCH',
    `/v2/inAppPurchases/${iap.id}`,
    {
      data: {
        id: iap.id,
        type: 'inAppPurchases',
        attributes: {
          name: target.name,
          reviewNote: target.reviewNote,
          familySharable: false,
        },
      },
    },
    token,
  ));
}

async function ensureInAppPurchaseAvailability(iap, territoryIds, token) {
  try {
    await api('GET', `/v2/inAppPurchases/${iap.id}/inAppPurchaseAvailability`, undefined, token);
    return;
  } catch (error) {
    if (error.statusCode !== 404) throw error;
  }
  await maybeWrite(`POST IAP availability ${iap.attributes.productId}`, () => api(
    'POST',
    '/v1/inAppPurchaseAvailabilities',
    {
      data: {
        type: 'inAppPurchaseAvailabilities',
        attributes: { availableInNewTerritories: true },
        relationships: {
          inAppPurchase: { data: { type: 'inAppPurchases', id: iap.id } },
          availableTerritories: {
            data: territoryIds.map((territory) => ({ type: 'territories', id: territory })),
          },
        },
      },
    },
    token,
  ));
}

async function findInAppPurchasePricePoint(iapId, priceUSD, token) {
  const targetPrice = Number(priceUSD);
  const points = await listAll(
    `/v2/inAppPurchases/${iapId}/pricePoints?filter[territory]=USA&limit=200`,
    token,
  );
  return points.find((point) => Number(point.attributes.customerPrice) === targetPrice);
}

async function ensureInAppPurchasePriceSchedule(iap, target, token) {
  try {
    await api('GET', `/v2/inAppPurchases/${iap.id}/iapPriceSchedule`, undefined, token);
    return;
  } catch (error) {
    if (error.statusCode !== 404) throw error;
  }
  const pricePoint = await findInAppPurchasePricePoint(iap.id, target.priceUSD, token);
  if (!pricePoint) {
    console.log(`  no IAP USA price point matching $${target.priceUSD}`);
    return;
  }
  await maybeWrite(`POST IAP price schedule $${target.priceUSD}`, () => api(
    'POST',
    '/v1/inAppPurchasePriceSchedules',
    {
      data: {
        type: 'inAppPurchasePriceSchedules',
        relationships: {
          inAppPurchase: { data: { type: 'inAppPurchases', id: iap.id } },
          baseTerritory: { data: { type: 'territories', id: 'USA' } },
          manualPrices: { data: [{ type: 'inAppPurchasePrices', id: '${p0}' }] },
        },
      },
      included: [{
        type: 'inAppPurchasePrices',
        id: '${p0}',
        attributes: { startDate: null },
        relationships: {
          inAppPurchasePricePoint: {
            data: { type: 'inAppPurchasePricePoints', id: pricePoint.id },
          },
        },
      }],
    },
    token,
  ));
}

async function printSubscriptionSummary(subscription, target, token) {
  const latest = await api('GET', `/v1/subscriptions/${subscription.id}`, undefined, token);
  const prices = await countRelationship(`/v1/subscriptions/${subscription.id}/relationships/prices?limit=200`, token);
  const offers = await countRelationship(`/v1/subscriptions/${subscription.id}/introductoryOffers?limit=200`, token);
  console.log(`  state=${latest.data.attributes.state} prices=${prices} introOffers=${offers} groupLevel=${latest.data.attributes.groupLevel}`);
  if (target.trial && offers === 0) console.log('  warning: Cloud trial is missing');
}

async function main() {
  const token = makeToken();
  const territoryIds = await listTerritoryIds(token);
  const subscriptions = await listSubscriptionsByProduct(token);
  const iaps = await listInAppPurchasesByProduct(token);
  console.log(`mode=${APPLY ? 'APPLY' : 'DRY-RUN'} app=${APP_ID} territories=${territoryIds.length}`);

  for (const target of SUBSCRIPTIONS) {
    console.log(`\n→ subscription ${target.productId}`);
    const subscription = subscriptions.get(target.productId);
    if (!subscription) {
      console.log('  missing in visible App Store Connect subscription groups');
      continue;
    }
    await ensureSubscriptionMetadata(subscription, target, token);
    await ensureSubscriptionAvailability(subscription, territoryIds, token);
    await ensureSubscriptionPrices(subscription, target, token);
    await ensureSubscriptionTrials(subscription, target, token);
    await printSubscriptionSummary(subscription, target, token);
  }

  for (const target of TOP_UPS) {
    console.log(`\n→ in-app purchase ${target.productId}`);
    const iap = iaps.get(target.productId);
    if (!iap) {
      console.log('  missing in visible App Store Connect in-app purchases');
      continue;
    }
    await ensureInAppPurchaseMetadata(iap, target, token);
    await ensureInAppPurchaseLocalization(iap, target, token);
    await ensureInAppPurchaseAvailability(iap, territoryIds, token);
    await ensureInAppPurchasePriceSchedule(iap, target, token);
    const latest = await api('GET', `/v2/inAppPurchases/${iap.id}`, undefined, token);
    console.log(`  state=${latest.data.attributes.state}`);
  }

  console.log(APPLY ? '\nCommercial IAP prep complete.' : '\nDry-run complete. Add --apply to write.');
}

module.exports = {
  SUBSCRIPTIONS,
  TOP_UPS,
  main,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error.message);
    if (error.payload) console.error(JSON.stringify(error.payload, null, 2));
    process.exit(1);
  });
}
