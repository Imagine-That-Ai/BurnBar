#!/usr/bin/env node
/**
 * Fail-closed drift check: the LIVE GCP billing budget vs the committed
 * contract in governance/ops-billing-budget.json (W0-5).
 *
 * The alert plane's cost guard is a billing budget whose Pub/Sub notifications
 * feed the ops alert policies. If the budget is deleted or its amount,
 * thresholds, project filter, or notification topic change out of band, the
 * alert plane is silently blind; this check makes that a loud red.
 *
 * Modes:
 *   (default, CI)  `gcloud billing budgets list --billing-account=$OPS_BILLING_ACCOUNT
 *                  --format=json`, then diff. Needs gcloud auth with roles/billing.viewer.
 *   --live <file>  Diff a saved JSON snapshot instead (offline, used by the self-test).
 *   --self-test    Prove the diff reports MATCH for a faithful snapshot and DRIFT for
 *                  every mutation this guard exists to catch.
 *
 * Exit codes: 0 MATCH · 1 DRIFT · 2 could not read live/committed state.
 */
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const COMMITTED_PATH = join(HERE, "..", "..", "governance", "ops-billing-budget.json");

export function loadCommitted(path = COMMITTED_PATH) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function toNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function amountUsd(budget) {
  const money = budget?.amount?.specifiedAmount;
  if (!money) return null;
  const units = toNumber(money.units ?? 0) ?? 0;
  const nanos = toNumber(money.nanos ?? 0) ?? 0;
  if ((money.currencyCode ?? "USD") !== "USD") return null;
  return units + nanos / 1e9;
}

function thresholds(budget) {
  return (budget?.thresholdRules ?? [])
    .map((rule) => toNumber(rule?.thresholdPercent))
    .filter((value) => value !== null)
    .sort((left, right) => left - right);
}

/**
 * Pure diff: committed contract vs the live budget list. Returns
 * { ok, differences: string[], matched: budget|null }.
 */
export function diffBillingBudget(committed, liveBudgets) {
  const differences = [];
  const budgets = Array.isArray(liveBudgets) ? liveBudgets : [];
  const matches = budgets.filter((budget) => budget?.displayName === committed.displayName);
  if (matches.length === 0) {
    differences.push(`missing: no live budget named "${committed.displayName}"`);
    return { ok: false, differences, matched: null };
  }
  if (matches.length > 1) {
    differences.push(`duplicate: ${matches.length} live budgets named "${committed.displayName}"`);
  }
  const live = matches[0];

  const liveAmount = amountUsd(live);
  if (liveAmount !== committed.amountUsd) {
    differences.push(`amount: live ${liveAmount ?? "unset/non-USD"} USD, committed ${committed.amountUsd} USD`);
  }

  const wantThresholds = [...committed.thresholdPercents].sort((left, right) => left - right);
  const liveThresholds = thresholds(live);
  if (JSON.stringify(liveThresholds) !== JSON.stringify(wantThresholds)) {
    differences.push(`thresholds: live [${liveThresholds.join(", ")}], committed [${wantThresholds.join(", ")}]`);
  }

  const liveProjects = [...(live?.budgetFilter?.projects ?? [])].sort();
  const wantProjects = [`projects/${committed.projectId}`];
  if (JSON.stringify(liveProjects) !== JSON.stringify(wantProjects)) {
    differences.push(
      `project filter: live [${liveProjects.join(", ") || "account-wide"}], committed [${wantProjects.join(", ")}]`,
    );
  }

  const liveTopic = live?.notificationsRule?.pubsubTopic ?? null;
  if (liveTopic !== committed.pubsubTopic) {
    differences.push(`notification topic: live ${liveTopic ?? "none"}, committed ${committed.pubsubTopic}`);
  }

  return { ok: differences.length === 0, differences, matched: live };
}

export function formatResult(committed, result) {
  if (result.ok) {
    return `MATCH: live billing budget "${committed.displayName}" equals governance/ops-billing-budget.json`;
  }
  return [
    `DRIFT: live billing budget vs governance/ops-billing-budget.json`,
    ...result.differences.map((difference) => `  - ${difference}`),
    "  The committed file wins: fix the live budget with scripts/ops/create-billing-budget.sh, or change the file in a reviewed PR.",
  ].join("\n");
}

/** A live budget that is faithful to the committed contract (test fixture). */
export function faithfulSnapshot(committed) {
  return [
    {
      name: "billingAccounts/000000-AAAAAA-BBBBBB/budgets/fixture",
      displayName: committed.displayName,
      amount: { specifiedAmount: { currencyCode: "USD", units: String(Math.trunc(committed.amountUsd)), nanos: 0 } },
      thresholdRules: committed.thresholdPercents.map((thresholdPercent) => ({ thresholdPercent, spendBasis: "CURRENT_SPEND" })),
      budgetFilter: { projects: [`projects/${committed.projectId}`], calendarPeriod: "MONTH" },
      notificationsRule: { pubsubTopic: committed.pubsubTopic, schemaVersion: "1.0" },
    },
  ];
}

function fetchLive(billingAccount) {
  const result = spawnSync(
    "gcloud",
    ["billing", "budgets", "list", `--billing-account=${billingAccount}`, "--format=json"],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    return { ok: false, error: result.stderr || result.stdout || result.error?.message || "gcloud failed" };
  }
  try {
    return { ok: true, budgets: JSON.parse(result.stdout || "[]") };
  } catch (error) {
    return { ok: false, error: `unparseable gcloud output: ${error.message}` };
  }
}

function selfTest() {
  const committed = loadCommitted();
  const failures = [];
  const check = (label, live, expectOk) => {
    const result = diffBillingBudget(committed, live);
    if (result.ok !== expectOk) failures.push(`${label}: expected ${expectOk ? "MATCH" : "DRIFT"}, got ${result.ok ? "MATCH" : "DRIFT"}`);
  };
  check("faithful snapshot", faithfulSnapshot(committed), true);
  check("foreign budget alongside", [...faithfulSnapshot(committed), { displayName: "someone-elses-budget" }], true);
  check("empty account", [], false);
  const mutate = (apply) => { const snapshot = faithfulSnapshot(committed); apply(snapshot[0]); return snapshot; };
  check("amount changed", mutate((b) => { b.amount.specifiedAmount.units = String(committed.amountUsd * 2); }), false);
  check("threshold dropped", mutate((b) => { b.thresholdRules.pop(); }), false);
  check("account-wide filter", mutate((b) => { delete b.budgetFilter.projects; }), false);
  check("topic changed", mutate((b) => { b.notificationsRule.pubsubTopic = "projects/burnbar/topics/other"; }), false);
  check("duplicate names", [...faithfulSnapshot(committed), ...faithfulSnapshot(committed)], false);
  if (failures.length > 0) {
    console.error("FAIL: billing budget drift self-test");
    for (const failure of failures) console.error(`  - ${failure}`);
    return 1;
  }
  console.log("PASS: billing budget drift self-test (2 positive controls + 6 drift controls)");
  return 0;
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--self-test") args.selfTest = true;
    else if (argv[index] === "--live") args.live = argv[index + 1], index += 1;
    else { console.error(`unknown argument: ${argv[index]}`); process.exit(2); }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.selfTest) process.exit(selfTest());
  const committed = loadCommitted();
  let live;
  if (args.live) {
    try {
      live = JSON.parse(readFileSync(args.live, "utf8"));
    } catch (error) {
      console.error(`could not read live snapshot: ${error.message}`);
      process.exit(2);
    }
  } else {
    const billingAccount = process.env.OPS_BILLING_ACCOUNT ?? "";
    if (!billingAccount) {
      console.error("::error::billing-account-not-configured — set the OPS_BILLING_ACCOUNT repo variable (governance/ops-plane-verifier-sa.json) so the live budget can be compared with governance/ops-billing-budget.json. Failing closed instead of skipping.");
      process.exit(2);
    }
    const fetched = fetchLive(billingAccount);
    if (!fetched.ok) {
      console.error(`could not read live billing budgets: ${fetched.error}`);
      process.exit(2);
    }
    live = fetched.budgets;
  }
  const result = diffBillingBudget(committed, live);
  console.log(formatResult(committed, result));
  process.exit(result.ok ? 0 : 1);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) main();
