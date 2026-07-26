#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  PRODUCTION_FIREBASE_FRAGMENTS,
  loadStagingFirebasePublicConfig
} from "./staging-firebase-public-config.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const STAGING_FIREBASE_PUBLIC_CONFIG = loadStagingFirebasePublicConfig();
const args = process.argv.slice(2);
let baseUrl = "https://burnbar-staging.web.app";
let distPath = join(ROOT, "dist");
let attempts = 8;
let retryDelayMs = 3_000;

for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (arg === "--base-url") baseUrl = args[++index] ?? "";
  else if (arg === "--dist") distPath = resolve(args[++index] ?? "");
  else if (arg === "--attempts") attempts = Number.parseInt(args[++index] ?? "", 10);
  else if (arg === "--retry-delay-ms") {
    retryDelayMs = Number.parseInt(args[++index] ?? "", 10);
  } else throw new Error(`Unknown argument: ${arg}`);
}

assert.match(baseUrl, /^https:\/\/[a-z0-9.-]+$/u, "--base-url must be an HTTPS origin");
assert.ok(Number.isSafeInteger(attempts) && attempts >= 1 && attempts <= 20);
assert.ok(Number.isSafeInteger(retryDelayMs) && retryDelayMs >= 0 && retryDelayMs <= 30_000);
assert.ok(statSync(distPath).isDirectory(), `dist directory not found: ${distPath}`);

function walk(directory, out = []) {
  for (const entry of readdirSync(directory)) {
    const absolute = join(directory, entry);
    if (statSync(absolute).isDirectory()) walk(absolute, out);
    else out.push(absolute);
  }
  return out;
}

const configNeedles = Object.values(STAGING_FIREBASE_PUBLIC_CONFIG);
const localAssets = walk(distPath).filter((file) => /\.(?:html|js|mjs)$/u.test(file));
const configAssets = localAssets.filter((file) => {
  const body = readFileSync(file, "utf8");
  return configNeedles.some((needle) => body.includes(needle));
});
assert.ok(configAssets.length > 0, "staging Firebase config is absent from the local artifact");
const localConfigBody = configAssets.map((file) => readFileSync(file, "utf8")).join("\n");
for (const expected of configNeedles) {
  assert.ok(
    localConfigBody.includes(expected),
    `staging Firebase identifier is absent from the local artifact: ${expected}`
  );
}

const sleep = (milliseconds) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));
async function retry(label, operation) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (attempt < attempts) await sleep(retryDelayMs);
    }
  }
  throw new Error(`${label} failed after ${attempts} attempt(s): ${lastError}`);
}

await retry("staging /subscribe verification", async () => {
  const subscribe = await fetch(`${baseUrl}/subscribe`, {
    redirect: "error",
    cache: "no-store"
  });
  assert.equal(subscribe.status, 200, `staging /subscribe returned ${subscribe.status}`);
  assert.match(
    subscribe.headers.get("content-security-policy") ?? "",
    /firebaseappcheck\.googleapis\.com/u,
    "staging /subscribe CSP must allow Firebase App Check"
  );
  assert.match(
    subscribe.headers.get("x-robots-tag") ?? "",
    /noindex/u,
    "staging Hosting must be excluded from search indexing"
  );
});

const deployedConfigBodies = [];
for (const localFile of configAssets) {
  const assetPath = `/${relative(distPath, localFile).split("\\").join("/")}`;
  const localBody = readFileSync(localFile);
  const expectedHash = createHash("sha256").update(localBody).digest("hex");
  const body = await retry(`deployed staging asset ${assetPath}`, async () => {
    const response = await fetch(`${baseUrl}${assetPath}`, {
      redirect: "error",
      cache: "no-store"
    });
    assert.equal(response.status, 200, `deployed staging asset missing: ${assetPath}`);
    const deployedBody = Buffer.from(await response.arrayBuffer());
    const deployedHash = createHash("sha256").update(deployedBody).digest("hex");
    assert.equal(
      deployedHash,
      expectedHash,
      `deployed ${assetPath} does not match the reviewed candidate artifact`
    );
    return deployedBody.toString("utf8");
  });
  deployedConfigBodies.push(body);
  for (const forbidden of PRODUCTION_FIREBASE_FRAGMENTS) {
    assert.ok(
      !body.includes(forbidden),
      `deployed ${assetPath} contains production Firebase identifier ${forbidden}`
    );
  }
}

const deployedConfigBody = deployedConfigBodies.join("\n");
for (const expected of configNeedles) {
  assert.ok(
    deployedConfigBody.includes(expected),
    `deployed staging assets are missing Firebase identifier: ${expected}`
  );
}

const rewriteProbes = [
  {
    label: "router rundown rewrite",
    path: "/api/router-rundown/2020-01-01",
    expectedStatus: 404
  },
  {
    label: "CLI link start rewrite",
    path: "/api/cli-link/start",
    expectedStatus: 400,
    init: {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}"
    }
  },
  {
    label: "CLI link poll rewrite",
    path: "/api/cli-link/poll",
    expectedStatus: 400,
    init: {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}"
    }
  },
  {
    label: "Hermes Gateway rewrite",
    path: "/v1/hermes-gateway/__staging-verification__",
    expectedStatus: 404
  }
];

for (const probe of rewriteProbes) {
  await retry(probe.label, async () => {
    const response = await fetch(`${baseUrl}${probe.path}`, {
      redirect: "error",
      cache: "no-store",
      ...probe.init
    });
    assert.equal(
      response.status,
      probe.expectedStatus,
      `${probe.label} returned ${response.status}, expected ${probe.expectedStatus}`
    );
  });
}

console.log(
  `✓ Staging deployment: ${configAssets.length} Firebase-bearing asset(s) exactly match ` +
    `the reviewed ${STAGING_FIREBASE_PUBLIC_CONFIG.PUBLIC_FIREBASE_PROJECT_ID} artifact; ` +
    `/subscribe is CSP-protected and noindex; ${rewriteProbes.length} reviewed Hosting ` +
    `rewrite probes reached their expected Functions.`
);
