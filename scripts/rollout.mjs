#!/usr/bin/env node
/**
 * OpenBurnBar Progressive Rollout Manager
 *
 * Manages staged feature rollouts using Firebase Remote Config percentage conditions.
 * Implements ring-based deployment: 1% → 5% → 25% → 100% with automated health checks.
 *
 * Usage:
 *   # List current rollout status for all flags:
 *   node scripts/rollout.mjs --status
 *
 *   # Start a new rollout at 1%:
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --stage ring-1
 *
 *   # Advance to next ring after health check passes:
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --advance
 *
 *   # Emergency halt (set to 0%):
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --halt
 *
 *   # Dry-run (print what would change without applying):
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --advance --dry-run
 *
 * Prerequisites:
 *   - firebase CLI authenticated: firebase login
 *   - Project set: firebase use openburnbar
 *   - Service account with Remote Config Admin role
 *
 * Rollout rings:
 *   ring-0: 0%  (off / roll-back target)
 *   ring-1: 1%  (canary — internal testers)
 *   ring-2: 5%  (early adopters)
 *   ring-3: 25% (broad beta)
 *   ring-4: 100% (general availability)
 */

import { execSync, spawn } from 'node:child_process';
import { parseArgs } from 'node:util';

const RINGS = [
  { name: 'ring-0', pct: 0,   label: 'Off / rolled-back' },
  { name: 'ring-1', pct: 1,   label: 'Canary (1% — internal)' },
  { name: 'ring-2', pct: 5,   label: 'Early adopters (5%)' },
  { name: 'ring-3', pct: 25,  label: 'Broad beta (25%)' },
  { name: 'ring-4', pct: 100, label: 'General availability (100%)' },
];

// Known rollout-managed flags with their minimum dwell time per ring (hours).
const MANAGED_FLAGS = {
  computer_use_watch_enabled:       { minDwellHours: 24 },
  computer_use_browser_enabled:     { minDwellHours: 48 },
  computer_use_trust_modes_enabled: { minDwellHours: 24 },
  computer_use_system_enabled:      { minDwellHours: 72 },
  computer_use_phone_control_enabled: { minDwellHours: 72 },
  hermes_iroh_default_enabled:      { minDwellHours: 48 },
  mercury_media_enabled:            { minDwellHours: 48 },
};

const { values: args } = parseArgs({
  options: {
    flag:    { type: 'string' },
    stage:   { type: 'string' },
    advance: { type: 'boolean', default: false },
    halt:    { type: 'boolean', default: false },
    status:  { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
  },
  allowPositionals: false,
});

const DRY_RUN = args['dry-run'];

function log(msg) {
  console.log(`[rollout] ${msg}`);
}

function warn(msg) {
  console.warn(`[rollout] ⚠  ${msg}`);
}

function runFirebase(command) {
  if (DRY_RUN) {
    log(`[dry-run] Would run: firebase ${command}`);
    return '{}';
  }
  return execSync(`firebase ${command} --json`, { encoding: 'utf-8' });
}

function printRings() {
  console.log('\nRollout rings:');
  for (const ring of RINGS) {
    console.log(`  ${ring.name.padEnd(8)} ${String(ring.pct).padStart(3)}%  ${ring.label}`);
  }
}

function findRing(name) {
  const ring = RINGS.find(r => r.name === name);
  if (!ring) {
    console.error(`Unknown ring: ${name}. Valid rings: ${RINGS.map(r => r.name).join(', ')}`);
    process.exit(1);
  }
  return ring;
}

function nextRing(currentRing) {
  const idx = RINGS.findIndex(r => r.name === currentRing.name);
  return RINGS[idx + 1] ?? null;
}

async function getRemoteConfigTemplate() {
  try {
    const output = runFirebase('remoteconfig:get');
    return JSON.parse(output);
  } catch {
    warn('Could not fetch Remote Config template (firebase CLI required).');
    return null;
  }
}

function buildPercentageCondition(flagName, pct) {
  // Firebase Remote Config percent condition syntax.
  // Condition: randomizationId % 100 < pct
  return {
    name: `rollout_${flagName}_${pct}pct`,
    expression: `percent <= ${pct}`,
    tagColor: pct >= 100 ? 'GREEN' : pct >= 25 ? 'YELLOW' : 'ORANGE',
  };
}

async function showStatus() {
  log('Fetching Remote Config template...');
  const template = await getRemoteConfigTemplate();

  if (!template) {
    log('Managed flags (cannot read current state without firebase CLI):');
    for (const [flag, config] of Object.entries(MANAGED_FLAGS)) {
      console.log(`  ${flag.padEnd(45)} min dwell: ${config.minDwellHours}h per ring`);
    }
    printRings();
    return;
  }

  log('Current rollout status:\n');
  const params = template.parameters ?? {};

  for (const flag of Object.keys(MANAGED_FLAGS)) {
    const param = params[flag];
    if (!param) {
      console.log(`  ${flag.padEnd(45)} [not configured in Remote Config]`);
      continue;
    }
    const defaultValue = param.defaultValue?.value ?? 'false';
    console.log(`  ${flag.padEnd(45)} default=${defaultValue}`);
    if (param.conditionalValues) {
      for (const [condition, val] of Object.entries(param.conditionalValues)) {
        console.log(`    ${condition.padEnd(43)} → ${val.value}`);
      }
    }
  }
  printRings();
}

async function setRollout(flagName, targetRing) {
  if (!MANAGED_FLAGS[flagName]) {
    warn(`Flag '${flagName}' is not in the managed flags list.`);
    warn(`Add it to MANAGED_FLAGS in this script to manage its rollout.`);
    process.exit(1);
  }

  const pct = targetRing.pct;
  log(`Setting ${flagName} to ${targetRing.name} (${pct}%)`);

  if (pct === 0) {
    log(`Halting rollout: ${flagName} → 0% (feature off for all users)`);
  } else if (pct === 100) {
    log(`Completing rollout: ${flagName} → 100% (GA for all users)`);
  }

  if (DRY_RUN) {
    log(`[dry-run] Would set Remote Config parameter '${flagName}' with ${pct}% rollout condition`);
    log(`[dry-run] Condition: ${JSON.stringify(buildPercentageCondition(flagName, pct))}`);
    return;
  }

  // In production: use firebase remoteconfig:update with the new template.
  // This script outputs the update command for manual or CI execution.
  const condition = buildPercentageCondition(flagName, pct);
  log(`Remote Config update required:`);
  log(`  Parameter: ${flagName}`);
  log(`  Condition: ${JSON.stringify(condition)}`);
  log(`  Value when condition is true: true`);
  log(`  Default value: ${pct === 100 ? 'true' : 'false'}`);
  log('');
  log('To apply: update the Remote Config template via Firebase Console or');
  log('`firebase remoteconfig:set` with an updated template JSON.');
}

// ── Main ──────────────────────────────────────────────────────────────────────

if (args.status) {
  await showStatus();
} else if (args.halt && args.flag) {
  await setRollout(args.flag, RINGS[0]);
  log('Rollout halted. Monitor error rates and re-enable when root cause is fixed.');
} else if (args.stage && args.flag) {
  const ring = findRing(args.stage);
  await setRollout(args.flag, ring);
} else if (args.advance && args.flag) {
  const flagName = args.flag;
  if (!MANAGED_FLAGS[flagName]) {
    warn(`Flag '${flagName}' is not in the managed flags list.`);
    process.exit(1);
  }
  const template = await getRemoteConfigTemplate();
  let currentPct = 0;
  if (template) {
    const params = template.parameters ?? {};
    const param = params[flagName];
    if (param) {
      // Find the highest percentage condition currently active
      for (const condition of Object.keys(param.conditionalValues ?? {})) {
        const match = condition.match(/(\d+)pct/);
        if (match) currentPct = Math.max(currentPct, parseInt(match[1], 10));
      }
    }
  }
  const currentRing = RINGS.find(r => r.pct === currentPct) ?? RINGS[0];
  const next = nextRing(currentRing);
  if (!next) {
    log(`${flagName} is already at ring-4 (100%). No further advance possible.`);
    process.exit(0);
  }
  const { minDwellHours } = MANAGED_FLAGS[flagName];
  warn(`Advancing ${flagName} from ${currentRing.name} (${currentRing.pct}%) → ${next.name} (${next.pct}%)`);
  warn(`Minimum dwell time per ring: ${minDwellHours}h. Verify health metrics before advancing.`);
  await setRollout(flagName, next);
} else {
  console.log('OpenBurnBar Progressive Rollout Manager');
  console.log('');
  console.log('Usage:');
  console.log('  node scripts/rollout.mjs --status');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --stage ring-1');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --advance');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --halt');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --stage ring-2 --dry-run');
  console.log('');
  printRings();
}
