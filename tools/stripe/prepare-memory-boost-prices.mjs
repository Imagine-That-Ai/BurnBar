#!/usr/bin/env node
/**
 * Idempotently create Stripe one-time prices for Memory Boost packs.
 *
 * Lookup keys are the commercial contract (`memory_boost_text_1m`,
 * `memory_boost_text_5m`, `memory_boost_vision_1m`). Existing prices are
 * reused; amount/currency mismatches fail closed instead of rewriting live
 * prices. Run once with the live secret and once with the test secret.
 *
 * Dry-run:
 *   STRIPE_SECRET_KEY="$(firebase functions:secrets:access STRIPE_SECRET_KEY --project burnbar)" \
 *     node tools/stripe/prepare-memory-boost-prices.mjs
 *
 * Apply + write Functions dotenv:
 *   STRIPE_SECRET_KEY="$(firebase functions:secrets:access STRIPE_SECRET_KEY --project burnbar)" \
 *     node tools/stripe/prepare-memory-boost-prices.mjs --apply --write-env
 *
 * Staging / test mode:
 *   STRIPE_SECRET_KEY="$(firebase functions:secrets:access STRIPE_SECRET_KEY --project burnbar-staging)" \
 *     node tools/stripe/prepare-memory-boost-prices.mjs --apply --write-env
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const STRIPE_API = "https://api.stripe.com/v1";

export const MEMORY_BOOST_STRIPE_PACKS = Object.freeze([
  {
    packId: "text_1m",
    lookupKey: "memory_boost_text_1m",
    envKey: "STRIPE_MEMORY_BOOST_TEXT_1M_PRICE_ID",
    name: "Memory Boost · 1M text tokens",
    description: "Prepaid 1 million text tokens for usage-memory extraction.",
    unitAmount: 299,
  },
  {
    packId: "text_5m",
    lookupKey: "memory_boost_text_5m",
    envKey: "STRIPE_MEMORY_BOOST_TEXT_5M_PRICE_ID",
    name: "Memory Boost · 5M text tokens",
    description: "Prepaid 5 million text tokens for usage-memory extraction.",
    unitAmount: 999,
  },
  {
    packId: "vision_1m",
    lookupKey: "memory_boost_vision_1m",
    envKey: "STRIPE_MEMORY_BOOST_VISION_1M_PRICE_ID",
    name: "Vision Memory Boost · 1M multimodal tokens",
    description: "Prepaid 1 million multimodal tokens for usage-memory extraction.",
    unitAmount: 699,
  },
]);

export function envFileForMode(livemode) {
  return livemode
    ? resolve(REPO_ROOT, "functions/.env.burnbar.production")
    : resolve(REPO_ROOT, "functions/.env.burnbar-staging");
}

export function upsertEnvVars(contents, updates) {
  const remaining = { ...updates };
  const lines = String(contents).split("\n");
  const out = [];
  for (const line of lines) {
    const match = /^([A-Z0-9_]+)=/.exec(line);
    if (match && Object.prototype.hasOwnProperty.call(remaining, match[1])) {
      out.push(`${match[1]}=${remaining[match[1]]}`);
      delete remaining[match[1]];
    } else {
      out.push(line);
    }
  }
  const extras = Object.entries(remaining).map(([key, value]) => `${key}=${value}`);
  if (extras.length === 0) return out.join("\n");
  while (out.length && out[out.length - 1] === "") out.pop();
  out.push(...extras, "");
  return out.join("\n");
}

export function assertPriceMatches(price, pack) {
  const problems = [];
  if (price.lookup_key !== pack.lookupKey) {
    problems.push(`lookup_key ${price.lookup_key} != ${pack.lookupKey}`);
  }
  if (price.currency !== "usd") problems.push(`currency ${price.currency} != usd`);
  if (price.type !== "one_time") problems.push(`type ${price.type} != one_time`);
  if (price.unit_amount !== pack.unitAmount) {
    problems.push(`unit_amount ${price.unit_amount} != ${pack.unitAmount}`);
  }
  if (price.active !== true) problems.push("price is inactive");
  if (problems.length) {
    throw new Error(`Stripe price ${price.id} for ${pack.packId} is wrong: ${problems.join("; ")}`);
  }
}

function parseArgs(argv) {
  const options = { apply: false, writeEnv: false, json: false };
  for (const arg of argv) {
    if (arg === "--apply") options.apply = true;
    else if (arg === "--write-env") options.writeEnv = true;
    else if (arg === "--json") options.json = true;
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return options;
}

function printHelp() {
  console.log(`Usage: node tools/stripe/prepare-memory-boost-prices.mjs [--apply] [--write-env] [--json]

Environment:
  STRIPE_SECRET_KEY  Live or test secret. Run once per mode.
`);
}

function formBody(params) {
  const body = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;
    body.append(key, String(value));
  }
  return body;
}

async function stripeRequest(secretKey, method, path, params) {
  const isGet = method === "GET";
  const url = isGet && params
    ? `${STRIPE_API}${path}?${formBody(params).toString()}`
    : `${STRIPE_API}${path}`;
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${secretKey}`,
      ...(isGet ? {} : { "Content-Type": "application/x-www-form-urlencoded" }),
    },
    body: isGet ? undefined : formBody(params),
  });
  const json = await response.json();
  if (!response.ok) {
    const message = json?.error?.message || `HTTP ${response.status}`;
    throw new Error(`Stripe ${method} ${path}: ${message}`);
  }
  return json;
}

async function findPriceByLookupKey(secretKey, lookupKey) {
  const listed = await stripeRequest(secretKey, "GET", "/prices", {
    "lookup_keys[]": lookupKey,
    "expand[]": "data.product",
    limit: "1",
  });
  return listed.data?.[0] ?? null;
}

async function findProductByPackId(secretKey, packId) {
  const search = await stripeRequest(secretKey, "GET", "/products/search", {
    query: `metadata['kind']:'memory_pack' AND metadata['packId']:'${packId}'`,
    limit: "1",
  });
  return search.data?.[0] ?? null;
}

async function ensureProduct(secretKey, pack, apply) {
  const existing = await findProductByPackId(secretKey, pack.packId);
  if (existing) return { product: existing, created: false };
  if (!apply) return { product: null, created: false };
  const product = await stripeRequest(secretKey, "POST", "/products", {
    name: pack.name,
    description: pack.description,
    "metadata[kind]": "memory_pack",
    "metadata[packId]": pack.packId,
    "metadata[lookupKey]": pack.lookupKey,
  });
  return { product, created: true };
}

async function ensurePrice(secretKey, pack, productId, apply) {
  const existing = await findPriceByLookupKey(secretKey, pack.lookupKey);
  if (existing) {
    assertPriceMatches(existing, pack);
    return { price: existing, created: false };
  }
  if (!apply) return { price: null, created: false };
  if (!productId) {
    throw new Error(`Cannot create Stripe price ${pack.lookupKey} without a product`);
  }
  const price = await stripeRequest(secretKey, "POST", "/prices", {
    product: productId,
    currency: "usd",
    unit_amount: String(pack.unitAmount),
    lookup_key: pack.lookupKey,
    transfer_lookup_key: "true",
    "metadata[kind]": "memory_pack",
    "metadata[packId]": pack.packId,
  });
  assertPriceMatches(price, pack);
  return { price, created: true };
}

export async function prepareMemoryBoostPrices(secretKey, { apply = false } = {}) {
  if (!secretKey) throw new Error("STRIPE_SECRET_KEY is required");
  const rows = [];
  let livemode = /(?:sk|rk)_live_/.test(secretKey);
  for (const pack of MEMORY_BOOST_STRIPE_PACKS) {
    const existingPrice = await findPriceByLookupKey(secretKey, pack.lookupKey);
    if (existingPrice) {
      assertPriceMatches(existingPrice, pack);
      livemode = existingPrice.livemode === true;
      rows.push({
        packId: pack.packId,
        lookupKey: pack.lookupKey,
        envKey: pack.envKey,
        productId: typeof existingPrice.product === "string"
          ? existingPrice.product
          : existingPrice.product?.id,
        priceId: existingPrice.id,
        unitAmount: existingPrice.unit_amount,
        createdPrice: false,
        createdProduct: false,
        action: "unchanged",
      });
      continue;
    }
    const productResult = await ensureProduct(secretKey, pack, apply);
    const priceResult = await ensurePrice(secretKey, pack, productResult.product?.id, apply);
    if (priceResult.price) livemode = priceResult.price.livemode === true;
    rows.push({
      packId: pack.packId,
      lookupKey: pack.lookupKey,
      envKey: pack.envKey,
      productId: productResult.product?.id ?? null,
      priceId: priceResult.price?.id ?? null,
      unitAmount: pack.unitAmount,
      createdPrice: priceResult.created,
      createdProduct: productResult.created,
      action: priceResult.price ? (priceResult.created ? "created" : "unchanged") : "missing",
    });
  }
  return { livemode, rows };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const secretKey = process.env.STRIPE_SECRET_KEY?.trim();
  if (!secretKey) throw new Error("STRIPE_SECRET_KEY is required");
  const result = await prepareMemoryBoostPrices(secretKey, { apply: options.apply });
  if (options.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(`mode=${options.apply ? "APPLY" : "DRY-RUN"} livemode=${result.livemode}`);
    for (const row of result.rows) {
      console.log(
        `  ${row.packId} ${row.lookupKey} price=${row.priceId || "MISSING"} product=${row.productId || "MISSING"} ${row.action}`,
      );
    }
  }
  if (options.writeEnv) {
    const missing = result.rows.filter((row) => !row.priceId);
    if (missing.length) {
      throw new Error(
        `Cannot write env; missing prices: ${missing.map((row) => row.lookupKey).join(", ")}. Re-run with --apply.`,
      );
    }
    const envPath = envFileForMode(result.livemode);
    const updates = Object.fromEntries(result.rows.map((row) => [row.envKey, row.priceId]));
    const next = upsertEnvVars(readFileSync(envPath, "utf8"), updates);
    writeFileSync(envPath, next);
    console.log(`wrote ${Object.keys(updates).length} price IDs to ${envPath}`);
  }
  if (!options.apply && result.rows.some((row) => row.action === "missing")) {
    process.exitCode = 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
