#!/usr/bin/env node
/**
 * Idempotently prepares OpenBurnBar Google Play one-time products.
 *
 * Uses the current Google Play monetization.onetimeproducts API. Dry-run by
 * default:
 *   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(firebase functions:secrets:access GOOGLE_PLAY_SERVICE_ACCOUNT_JSON --project burnbar)" \
 *     node tools/google-play/prepare-commercial-iaps.mjs
 *
 * Apply:
 *   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(firebase functions:secrets:access GOOGLE_PLAY_SERVICE_ACCOUNT_JSON --project burnbar)" \
 *     node tools/google-play/prepare-commercial-iaps.mjs --apply
 */

import { createRequire } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import process from "node:process";
import { pathToFileURL } from "node:url";

const require = createRequire(import.meta.url);
const { google } = require("../../functions/node_modules/googleapis");

const ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const DEFAULT_PACKAGE_NAME = "com.openburnbar";
const DEFAULT_LANGUAGE = "en-US";
const PURCHASE_OPTION_ID = "buy";
const AVAILABLE = "AVAILABLE";
const ACTIVE = "ACTIVE";
const DIGITAL_CONTENT_WITHDRAWAL_RIGHT = "WITHDRAWAL_RIGHT_DIGITAL_CONTENT";

export const GOOGLE_PLAY_TOP_UPS = Object.freeze([
  {
    productId: "com.openburnbar.agentcontrol.actions100",
    name: "Agent Control · 100 actions",
    description: "Prepaid top-up for 100 hosted Agent Control actions in BurnBar Cloud Pro.",
    priceUSD: "4.99",
  },
  {
    productId: "com.openburnbar.floo.relay50gb",
    name: "Floo relay · 50 GB",
    description: "Prepaid top-up for 50 GB of Floo relay accounting in BurnBar Cloud Pro.",
    priceUSD: "4.99",
  },
  {
    productId: "com.openburnbar.elderwand.searches100",
    name: "Elder Wand Search 100",
    description: "Adds 100 hosted Elder Wand Fusion web_search credits.",
    priceUSD: "4.99",
  },
  {
    productId: "com.openburnbar.elderwand.searches500",
    name: "Elder Wand Search 500",
    description: "Adds 500 hosted Elder Wand Fusion web_search credits.",
    priceUSD: "19.99",
  },
  {
    productId: "com.openburnbar.memory.boost.text.1m",
    name: "Memory Boost · 1M text",
    description: "Prepaid 1 million text tokens for usage-memory extraction.",
    priceUSD: "2.99",
  },
  {
    productId: "com.openburnbar.memory.boost.text.5m",
    name: "Memory Boost · 5M text",
    description: "Prepaid 5 million text tokens for usage-memory extraction.",
    priceUSD: "9.99",
  },
  {
    productId: "com.openburnbar.memory.boost.vision.1m",
    name: "Vision Memory Boost · 1M",
    description: "Prepaid 1 million multimodal tokens for usage-memory extraction.",
    priceUSD: "6.99",
  },
]);

export function priceUSDMicros(priceUSD) {
  const cents = parseUSDCents(priceUSD);
  return String(cents * 10_000);
}

export function moneyFromUSD(priceUSD) {
  const cents = parseUSDCents(priceUSD);
  return {
    currencyCode: "USD",
    units: String(Math.floor(cents / 100)),
    nanos: (cents % 100) * 10_000_000,
  };
}

export function moneyToUSD(money) {
  if (!money || money.currencyCode !== "USD") return null;
  const units = Number.parseInt(money.units ?? "0", 10);
  const nanos = Number(money.nanos ?? 0);
  if (!Number.isFinite(units) || !Number.isFinite(nanos)) return null;
  const cents = units * 100 + Math.round(nanos / 10_000_000);
  return `$${(cents / 100).toFixed(2)}`;
}

export function buildOneTimeProduct(target, packageName, convertedPrices) {
  const regionalConfigs = Object.values(convertedPrices.convertedRegionPrices ?? {})
    .filter((entry) => entry?.regionCode && entry?.price)
    .map((entry) => ({
      regionCode: entry.regionCode,
      price: entry.price,
      availability: AVAILABLE,
    }))
    .sort((left, right) => left.regionCode.localeCompare(right.regionCode));

  if (regionalConfigs.length === 0) {
    throw new Error(`Google Play did not return regional prices for ${target.productId}`);
  }
  if (!convertedPrices.convertedOtherRegionsPrice?.usdPrice || !convertedPrices.convertedOtherRegionsPrice?.eurPrice) {
    throw new Error(`Google Play did not return other-regions prices for ${target.productId}`);
  }

  return {
    packageName,
    productId: target.productId,
    listings: [
      {
        languageCode: DEFAULT_LANGUAGE,
        title: target.name,
        description: target.description,
      },
    ],
    taxAndComplianceSettings: {
      isTokenizedDigitalAsset: false,
    },
    purchaseOptions: [
      {
        purchaseOptionId: PURCHASE_OPTION_ID,
        buyOption: {
          legacyCompatible: true,
          multiQuantityEnabled: false,
        },
        regionalPricingAndAvailabilityConfigs: regionalConfigs,
        newRegionsConfig: {
          usdPrice: convertedPrices.convertedOtherRegionsPrice.usdPrice,
          eurPrice: convertedPrices.convertedOtherRegionsPrice.eurPrice,
          availability: AVAILABLE,
        },
        taxAndComplianceSettings: {
          withdrawalRightType: DIGITAL_CONTENT_WITHDRAWAL_RIGHT,
        },
      },
    ],
  };
}

export function diffOneTimeProduct(existing, target) {
  const changes = [];
  if (!existing || existing.readError) {
    changes.push(existing?.readError ? "unreadable" : "missing");
    return changes;
  }

  const listing = (existing.listings ?? []).find((entry) => entry.languageCode === DEFAULT_LANGUAGE);
  if (!listing) changes.push("listing:missing");
  if (listing && listing.title !== target.name) changes.push("title");
  if (listing && listing.description !== target.description) changes.push("description");

  const purchaseOption = findBuyOption(existing);
  if (!purchaseOption) {
    changes.push("purchaseOption:missing");
  } else {
    if (purchaseOption.buyOption?.legacyCompatible !== true) changes.push("legacyCompatible");
    if (purchaseOption.buyOption?.multiQuantityEnabled === true) changes.push("multiQuantityEnabled");
    if (purchaseOption.state !== ACTIVE) changes.push(`state:${purchaseOption.state ?? "unset"}->${ACTIVE}`);
    if (purchaseOption.newRegionsConfig?.availability !== AVAILABLE) changes.push("newRegionsAvailability");
    const usConfig = (purchaseOption.regionalPricingAndAvailabilityConfigs ?? []).find(
      (entry) => entry.regionCode === "US",
    );
    const expectedPrice = `$${Number(target.priceUSD).toFixed(2)}`;
    const actualPrice = moneyToUSD(usConfig?.price);
    if (!usConfig) changes.push("usPrice:missing");
    if (usConfig && actualPrice !== expectedPrice) changes.push(`usPrice:${actualPrice ?? "unknown"}->${expectedPrice}`);
  }

  return changes;
}

function parseUSDCents(priceUSD) {
  const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(priceUSD);
  if (!match) throw new Error(`Invalid USD price: ${priceUSD}`);
  const dollars = Number.parseInt(match[1], 10);
  const cents = Number.parseInt((match[2] ?? "").padEnd(2, "0"), 10);
  return dollars * 100 + cents;
}

function findBuyOption(product) {
  return (product.purchaseOptions ?? []).find((option) => option.purchaseOptionId === PURCHASE_OPTION_ID);
}

function parseArgs(argv) {
  const options = {
    apply: false,
    json: false,
    packageName: process.env.GOOGLE_PLAY_PACKAGE_NAME || DEFAULT_PACKAGE_NAME,
    productIds: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--apply") {
      options.apply = true;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "--package-name") {
      options.packageName = requiredNext(argv, index, arg);
      index += 1;
    } else if (arg === "--product") {
      options.productIds.push(requiredNext(argv, index, arg));
      index += 1;
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return options;
}

function requiredNext(argv, index, flag) {
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function printHelp() {
  console.log(`Usage: node tools/google-play/prepare-commercial-iaps.mjs [--apply] [--json] [--package-name com.openburnbar] [--product sku]

Environment:
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON  Full service-account JSON, or a path to a JSON file.
  GOOGLE_APPLICATION_CREDENTIALS    Service-account JSON path when GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is not set.
  GOOGLE_PLAY_PACKAGE_NAME          Defaults to com.openburnbar.
`);
}

function loadCredentials() {
  const raw = process.env.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON?.trim();
  if (raw) {
    const json = raw.startsWith("{") ? raw : readFileSync(raw, "utf8");
    return { credentials: JSON.parse(json) };
  }
  const credentialsPath = process.env.GOOGLE_APPLICATION_CREDENTIALS?.trim();
  if (credentialsPath) {
    if (!existsSync(credentialsPath)) throw new Error(`GOOGLE_APPLICATION_CREDENTIALS does not exist: ${credentialsPath}`);
    return { keyFile: credentialsPath };
  }
  return {};
}

async function createAndroidPublisher() {
  const auth = new google.auth.GoogleAuth({
    ...loadCredentials(),
    scopes: [ANDROID_PUBLISHER_SCOPE],
  });
  const authClient = await auth.getClient();
  return google.androidpublisher({ version: "v3", auth: authClient });
}

async function getOneTimeProduct(androidpublisher, packageName, productId) {
  try {
    const response = await androidpublisher.monetization.onetimeproducts.get({ packageName, productId });
    return response.data;
  } catch (error) {
    if (isGoogleNotFound(error)) return null;
    return { readError: googleErrorSummary(error) };
  }
}

async function getLegacyInAppProduct(androidpublisher, packageName, sku) {
  try {
    const response = await androidpublisher.inappproducts.get({ packageName, sku });
    return response.data;
  } catch (error) {
    if (isGoogleNotFound(error)) return null;
    return { readError: googleErrorSummary(error) };
  }
}

async function convertRegionalPrices(androidpublisher, packageName, target) {
  const response = await androidpublisher.monetization.convertRegionPrices({
    packageName,
    requestBody: {
      price: moneyFromUSD(target.priceUSD),
    },
  });
  const converted = response.data;
  if (!converted.regionVersion?.version) {
    throw new Error(`Google Play did not return a region version for ${target.productId}`);
  }
  return converted;
}

async function upsertOneTimeProduct(androidpublisher, packageName, target) {
  const convertedPrices = await convertRegionalPrices(androidpublisher, packageName, target);
  const desired = buildOneTimeProduct(target, packageName, convertedPrices);
  await androidpublisher.monetization.onetimeproducts.patch({
    packageName,
    productId: target.productId,
    allowMissing: true,
    "regionsVersion.version": convertedPrices.regionVersion.version,
    updateMask: "listings,taxAndComplianceSettings,purchaseOptions",
    requestBody: desired,
  });
}

async function activatePurchaseOptionIfNeeded(androidpublisher, packageName, product) {
  const purchaseOption = findBuyOption(product);
  if (purchaseOption?.state === ACTIVE) return false;
  await androidpublisher.monetization.onetimeproducts.purchaseOptions.batchUpdateStates({
    packageName,
    productId: product.productId,
    requestBody: {
      requests: [
        {
          activatePurchaseOptionRequest: {
            packageName,
            productId: product.productId,
            purchaseOptionId: PURCHASE_OPTION_ID,
          },
        },
      ],
    },
  });
  return true;
}

function isGoogleNotFound(error) {
  const code = error?.code ?? error?.response?.status;
  return code === 404;
}

function googleErrorSummary(error) {
  const code = error?.code ?? error?.response?.status ?? "unknown";
  const message = error?.errors?.[0]?.message ?? error?.response?.data?.error?.message ?? error?.message ?? "unknown";
  return `HTTP ${code}: ${message}`;
}

async function ensureProduct(androidpublisher, target, options) {
  const before = await getOneTimeProduct(androidpublisher, options.packageName, target.productId);
  const changes = diffOneTimeProduct(before, target);
  let action = "noop";
  let activated = false;
  let after = before;

  if (changes.length > 0 && before?.readError) {
    action = "blocked";
  } else if (changes.length > 0 && options.apply) {
    await upsertOneTimeProduct(androidpublisher, options.packageName, target);
    action = before ? "patched" : "created";
    after = await getOneTimeProduct(androidpublisher, options.packageName, target.productId);
    activated = await activatePurchaseOptionIfNeeded(androidpublisher, options.packageName, after);
    if (activated) after = await getOneTimeProduct(androidpublisher, options.packageName, target.productId);
  } else if (changes.length > 0) {
    action = before ? "would_patch" : "would_create";
  }

  const legacyReadback = await getLegacyInAppProduct(androidpublisher, options.packageName, target.productId);
  return summarizeProduct(target, action, changes, after, legacyReadback, activated);
}

function summarizeProduct(target, action, changes, product, legacyReadback, activated) {
  const purchaseOption = product && !product.readError ? findBuyOption(product) : null;
  const listing = product && !product.readError
    ? (product.listings ?? []).find((entry) => entry.languageCode === DEFAULT_LANGUAGE)
    : null;
  const usConfig = (purchaseOption?.regionalPricingAndAvailabilityConfigs ?? []).find((entry) => entry.regionCode === "US");
  const legacyStatus = legacyReadback?.readError
    ? legacyReadback.readError
    : legacyReadback
      ? `${legacyReadback.status ?? "unknown"}/${legacyReadback.purchaseType ?? "unknown"}`
      : "not_present";

  return {
    productId: target.productId,
    action,
    changes,
    exists: Boolean(product && !product.readError),
    readError: product?.readError ?? null,
    purchaseOptionState: purchaseOption?.state ?? null,
    legacyCompatible: purchaseOption?.buyOption?.legacyCompatible ?? null,
    priceUSD: moneyToUSD(usConfig?.price),
    title: listing?.title ?? null,
    activated,
    legacyInAppReadback: legacyStatus,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const selected = options.productIds.length > 0
    ? GOOGLE_PLAY_TOP_UPS.filter((product) => options.productIds.includes(product.productId))
    : GOOGLE_PLAY_TOP_UPS;
  if (selected.length !== (options.productIds.length || GOOGLE_PLAY_TOP_UPS.length)) {
    const known = new Set(GOOGLE_PLAY_TOP_UPS.map((product) => product.productId));
    const unknown = options.productIds.filter((productId) => !known.has(productId));
    throw new Error(`Unknown Google Play product id(s): ${unknown.join(", ")}`);
  }

  const androidpublisher = await createAndroidPublisher();
  const results = [];
  for (const target of selected) {
    results.push(await ensureProduct(androidpublisher, target, options));
  }

  if (options.json) {
    console.log(JSON.stringify({ apply: options.apply, packageName: options.packageName, results }, null, 2));
    return;
  }

  console.log(`Google Play package: ${options.packageName}`);
  console.log(`Mode: ${options.apply ? "apply" : "dry-run"}`);
  for (const result of results) {
    const changeText = result.changes.length > 0 ? result.changes.join(",") : "current";
    const state = result.readError ?? (result.purchaseOptionState ?? "missing");
    console.log(
      `${result.productId}: ${result.action}; oneTime=${state}; legacyCompatible=${result.legacyCompatible ?? "missing"}; price=${result.priceUSD ?? "missing"}; changes=${changeText}; legacy=${result.legacyInAppReadback}`,
    );
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(googleErrorSummary(error));
    process.exit(1);
  });
}
