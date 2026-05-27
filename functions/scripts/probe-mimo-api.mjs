#!/usr/bin/env node
/**
 * Probe Xiaomi MiMo API endpoints without storing secrets in output.
 *
 * Usage:
 *   MIMO_TP_KEY=tp-… MIMO_REGION=sgp node functions/scripts/probe-mimo-api.mjs
 *   MIMO_SK_KEY=sk-… node functions/scripts/probe-mimo-api.mjs
 *   node functions/scripts/probe-mimo-api.mjs --validate-fixture
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_PATH = join(__dirname, "fixtures", "mimo-api-probe.fixture.json");

const regions = {
  cn: "https://token-plan-cn.xiaomimimo.com/v1",
  sgp: "https://token-plan-sgp.xiaomimimo.com/v1",
  ams: "https://token-plan-ams.xiaomimimo.com/v1",
};

const payg = "https://api.xiaomimimo.com/v1";

async function probe(url, key, label) {
  const headers = { Accept: "application/json", Authorization: `Bearer ${key}` };
  const result = { label, url, status: null, ok: false, shape: null, error: null };
  try {
    const response = await fetch(url, { method: "GET", headers });
    result.status = response.status;
    result.ok = response.ok;
    const text = await response.text();
    try {
      const json = JSON.parse(text);
      result.shape =
        json && typeof json === "object"
          ? Object.keys(json).slice(0, 12)
          : typeof json;
    } catch {
      result.shape = text.slice(0, 120);
    }
  } catch (err) {
    result.error = String(err);
  }
  return result;
}

function validateFixture() {
  const fixture = JSON.parse(readFileSync(FIXTURE_PATH, "utf8"));
  const encoded = JSON.stringify(fixture);
  if (/tp-[A-Za-z0-9]{8,}/.test(encoded) || /sk-[A-Za-z0-9]{8,}/.test(encoded)) {
    throw new Error("Fixture contains key-like secrets");
  }
  if (!Array.isArray(fixture.probes) || fixture.probes.length === 0) {
    throw new Error("Fixture probes array is missing");
  }
  if (!fixture.responseSamples) {
    throw new Error("Fixture responseSamples is missing");
  }
  console.log(JSON.stringify({ ok: true, fixture: FIXTURE_PATH, probes: fixture.probes.length }, null, 2));
}

async function main() {
  if (process.argv.includes("--validate-fixture")) {
    validateFixture();
    return;
  }

  const report = { generatedAt: new Date().toISOString(), probes: [] };

  const sk = process.env.MIMO_SK_KEY?.trim();
  if (sk) {
    report.probes.push(await probe(`${payg}/models`, sk, "payg.models"));
  }

  const tp = process.env.MIMO_TP_KEY?.trim();
  const region = process.env.MIMO_REGION?.trim() || "sgp";
  if (tp) {
    const base = regions[region] ?? regions.sgp;
    report.probes.push(await probe(`${base}/models`, tp, `${region}.models`));
    report.probes.push(
      await probe(`${base}/token_plan/remains`, tp, `${region}.token_plan.remains`)
    );
  }

  if (report.probes.length === 0) {
    console.log(
      JSON.stringify(
        {
          message:
            "No keys provided. Set MIMO_SK_KEY and/or MIMO_TP_KEY (+ optional MIMO_REGION=cn|sgp|ams).",
          hosts: { payg, regions },
          fixture: FIXTURE_PATH,
        },
        null,
        2
      )
    );
    process.exit(0);
  }

  console.log(JSON.stringify(report, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
