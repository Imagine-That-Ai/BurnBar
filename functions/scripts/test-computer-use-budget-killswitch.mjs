#!/usr/bin/env node
/**
 * Unit-style checks for hard_cap → Remote Config kill switch wiring.
 * Runs against compiled lib/ output (no emulator required).
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const budgetSrc = readFileSync(join(root, "src/computerUseBudget.ts"), "utf8");
const mediaBudgetSrc = readFileSync(join(root, "src/mediaBudget.ts"), "utf8");
const rcSrc = readFileSync(join(root, "src/computerUseRemoteConfig.ts"), "utf8");

assert.match(budgetSrc, /syncKillSwitchForBudgetLevel/);
assert.match(budgetSrc, /computer_use_budget_soft_usd/);
assert.match(budgetSrc, /computer_use_budget_soft_cap_usd/);
assert.match(mediaBudgetSrc, /media_budget_soft_usd/);
assert.match(mediaBudgetSrc, /media_budget_soft_cap_usd/);
assert.match(rcSrc, /computer_use_kill_switch/);
assert.match(rcSrc, /budget_hard_cap/);
assert.match(rcSrc, /ops\/computer_use_budget_status\/events/);
assert.match(budgetSrc, /metrics\/current/);
assert.match(budgetSrc, /state\/current/);

console.log("test-computer-use-budget-killswitch: ok");
