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
 *   # Preview a new rollout at 1%:
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --stage ring-1
 *
 *   # Apply a rollout to Firebase Remote Config:
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --stage ring-1 --apply --project openburnbar
 *
 *   # Apply a targeted canary (for example, one Firebase installation id):
 *   node scripts/rollout.mjs --flag signal_at_rest_conversations_chat_enabled --stage ring-1 --condition "app.firebaseInstallationId in ['...']" --apply --project burnbar
 *
 *   # Advance to next ring after health check passes:
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --advance
 *
 *   # Preview emergency halt (set to 0%):
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --halt
 *
 *   # Dry-run (print what would change without applying):
 *   node scripts/rollout.mjs --flag computer_use_system_enabled --advance --dry-run
 *
 * Prerequisites:
 *   - firebase CLI authenticated: firebase login
 *   - Project set: firebase use openburnbar
 *   - For --apply: gcloud auth or FIREBASE_TOKEN with Remote Config Admin role
 *
 * Rollout rings:
 *   ring-0: 0%  (off / roll-back target)
 *   ring-1: 1%  (canary — internal testers)
 *   ring-2: 5%  (early adopters)
 *   ring-3: 25% (broad beta)
 *   ring-4: 100% (general availability)
 */

import { execSync } from 'node:child_process';
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
  computer_use_phone_control_attestation_required: { minDwellHours: 72 },
  hermes_iroh_default_enabled:      { minDwellHours: 48 },
  mercury_media_enabled:            { minDwellHours: 48 },
  signal_at_rest_disabled:          { minDwellHours: 0 },
  signal_at_rest_enabled:           { minDwellHours: 72 },
  signal_at_rest_conversations_chat_enabled: { minDwellHours: 72 },
  signal_at_rest_pensieve_enabled:  { minDwellHours: 72 },
};

const { values: args } = parseArgs({
  options: {
    flag:    { type: 'string' },
    stage:   { type: 'string' },
    advance: { type: 'boolean', default: false },
    halt:    { type: 'boolean', default: false },
    status:  { type: 'boolean', default: false },
    apply:   { type: 'boolean', default: false },
    project: { type: 'string' },
    condition: { type: 'string' },
    'dry-run': { type: 'boolean', default: false },
  },
  allowPositionals: false,
});

const DRY_RUN = args['dry-run'];
const APPLY = args.apply;
const PROJECT_ID = args.project ?? process.env.PROJECT_ID ?? '';
const CONDITION_EXPRESSION = args.condition ?? '';

if (APPLY && DRY_RUN) {
  console.error('Use either --apply or --dry-run, not both.');
  process.exit(64);
}

function log(msg) {
  console.log(`[rollout] ${msg}`);
}

function warn(msg) {
  console.warn(`[rollout] ⚠  ${msg}`);
}

function runFirebase(command) {
  return execSync(`firebase ${command} --json`, { encoding: 'utf-8' });
}

function requireProjectForApply() {
  if (!PROJECT_ID) {
    console.error('Remote Config publish requires --project <firebase-project-id> or PROJECT_ID.');
    process.exit(64);
  }
}

function remoteConfigAccessToken() {
  if (process.env.FIREBASE_TOKEN) return process.env.FIREBASE_TOKEN;
  try {
    return execSync('gcloud auth print-access-token', { encoding: 'utf-8' }).trim();
  } catch {
    console.error('Remote Config publish requires FIREBASE_TOKEN or gcloud auth print-access-token.');
    process.exit(1);
  }
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
    const parsed = JSON.parse(output);
    return parsed.result ?? parsed;
  } catch {
    warn('Could not fetch Remote Config template (firebase CLI required).');
    return null;
  }
}

async function fetchRemoteConfigTemplateForPublish() {
  requireProjectForApply();
  const token = remoteConfigAccessToken();
  const url = `https://firebaseremoteconfig.googleapis.com/v1/projects/${PROJECT_ID}/remoteConfig`;
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      'x-goog-user-project': PROJECT_ID,
    },
  });
  if (!response.ok) {
    throw new Error(`Remote Config GET failed (${response.status}): ${await response.text()}`);
  }
  const etag = response.headers.get('etag');
  if (!etag) {
    throw new Error('Remote Config GET did not return an ETag; refusing to publish.');
  }
  return { template: await response.json(), etag, token, url };
}

async function publishRemoteConfigTemplate(template, etag, token, url) {
  const response = await fetch(url, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json; UTF8',
      'If-Match': etag,
      'x-goog-user-project': PROJECT_ID,
    },
    body: JSON.stringify(template),
  });
  if (!response.ok) {
    throw new Error(`Remote Config PUT failed (${response.status}): ${await response.text()}`);
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

function buildCondition(flagName, pct) {
  if (CONDITION_EXPRESSION) {
    return {
      name: `rollout_${flagName}_targeted`,
      expression: CONDITION_EXPRESSION,
      tagColor: 'BLUE',
    };
  }
  return buildPercentageCondition(flagName, pct);
}

function withoutManagedRolloutConditions(template, flagName) {
  const next = structuredClone(template ?? {});
  const rolloutPrefix = `rollout_${flagName}_`;
  const removed = new Set();

  next.conditions = (next.conditions ?? []).filter((condition) => {
    if (typeof condition?.name === 'string' && condition.name.startsWith(rolloutPrefix)) {
      removed.add(condition.name);
      return false;
    }
    return true;
  });

  next.parameters = next.parameters ?? {};
  for (const param of Object.values(next.parameters)) {
    if (!param?.conditionalValues) continue;
    for (const name of removed) delete param.conditionalValues[name];
    if (Object.keys(param.conditionalValues).length === 0) delete param.conditionalValues;
  }

  return next;
}

function buildRolledTemplate(template, flagName, pct) {
  const next = withoutManagedRolloutConditions(template, flagName);
  next.parameters = next.parameters ?? {};
  const condition = pct > 0 && pct < 100 ? buildCondition(flagName, pct) : null;
  const param = {
    ...(next.parameters[flagName] ?? {}),
    defaultValue: { value: pct === 100 ? 'true' : 'false' },
    valueType: 'BOOLEAN',
    description: `OpenBurnBar managed rollout flag (${flagName}). Updated by scripts/rollout.mjs.`,
  };

  const conditionalValues = { ...(param.conditionalValues ?? {}) };
  if (condition) {
    next.conditions = [...(next.conditions ?? []), condition];
    conditionalValues[condition.name] = { value: 'true' };
  }
  if (Object.keys(conditionalValues).length > 0) {
    param.conditionalValues = conditionalValues;
  } else {
    delete param.conditionalValues;
  }
  next.parameters[flagName] = param;
  return { template: next, condition };
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

  if (!APPLY) {
    const liveTemplate = await getRemoteConfigTemplate();
    const { template, condition } = buildRolledTemplate(liveTemplate ?? { conditions: [], parameters: {} }, flagName, pct);
    log(`${DRY_RUN ? '[dry-run] ' : ''}Remote Config preview only; pass --apply --project <id> to publish.`);
    log(`  Parameter: ${flagName}`);
    log(`  Condition: ${condition ? JSON.stringify(condition) : '(none)'}`);
    log(`  Default value: ${template.parameters[flagName].defaultValue.value}`);
    console.log(JSON.stringify({ conditions: template.conditions ?? [], parameter: template.parameters[flagName] }, null, 2));
    return;
  }

  const current = await fetchRemoteConfigTemplateForPublish();
  const { template, condition } = buildRolledTemplate(current.template, flagName, pct);
  log(`Publishing Remote Config update:`);
  log(`  Parameter: ${flagName}`);
  log(`  Condition: ${condition ? JSON.stringify(condition) : '(none)'}`);
  log(`  Default value: ${template.parameters[flagName].defaultValue.value}`);
  await publishRemoteConfigTemplate(template, current.etag, current.token, current.url);
  log(`Remote Config published for ${flagName} at ${targetRing.name}.`);
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
      if ((param.defaultValue?.value ?? 'false') === 'true') currentPct = 100;
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
  console.log('  node scripts/rollout.mjs --flag <flag_name> --stage ring-1 --apply --project openburnbar');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --advance');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --halt');
  console.log('  node scripts/rollout.mjs --flag <flag_name> --stage ring-2 --dry-run');
  console.log('');
  printRings();
}
