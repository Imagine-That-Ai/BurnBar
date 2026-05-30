#!/usr/bin/env node
/**
 * Log-based alert policy templates for Computer Use + Media budget guardrails.
 * Emits Monitoring alert JSON snippets for ops/computer_use_budget_status/events/
 * and ops/media_budget_status/events/ (Firestore audit path — not BigQuery history).
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const outDir = join(dirname(fileURLToPath(import.meta.url)), "..", "artifacts", "budget-alerts");
mkdirSync(outDir, { recursive: true });

const policies = {
  computer_use_budget_evaluate_failed: {
    displayName: "Computer Use budget evaluate failed",
    filter: 'resource.type="cloud_function" AND jsonPayload.event="computer_use_budget_evaluate_failed"',
    severity: "CRITICAL",
  },
  computer_use_budget_hard_cap: {
    displayName: "Computer Use budget hard cap",
    filter: 'resource.type="cloud_function" AND jsonPayload.event="computer_use_budget_evaluated" AND jsonPayload.level="hard_cap"',
    severity: "CRITICAL",
  },
  computer_use_budget_soft_cap: {
    displayName: "Computer Use budget soft cap (informational)",
    filter: 'resource.type="cloud_function" AND jsonPayload.event="computer_use_budget_evaluated" AND jsonPayload.level="soft_cap"',
    severity: "WARNING",
  },
  media_budget_evaluate_failed: {
    displayName: "Media budget evaluate failed",
    filter: 'resource.type="cloud_function" AND jsonPayload.event="media.budget.evaluate_failed"',
    severity: "CRITICAL",
  },
  media_budget_hard_cap: {
    displayName: "Media budget hard cap",
    filter: 'resource.type="cloud_function" AND jsonPayload.event="media.budget.evaluated" AND jsonPayload.level="hard_cap"',
    severity: "CRITICAL",
  },
};

for (const [name, body] of Object.entries(policies)) {
  writeFileSync(join(outDir, `${name}.json`), JSON.stringify(body, null, 2) + "\n");
}

console.log(`Wrote ${Object.keys(policies).length} alert policy templates to ${outDir}`);
