#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const PRIVACY_MARKER = "aggregate_counts_only_no_document_values_or_identifiers";
const SIGNAL_REQUIRED_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED";
const DEFAULT_PROJECT_ID = "burnbar";
const DEFAULT_REGION = "us-central1";
const DEFAULT_WRITE_PATH_SERVICES = ["burnbarhermesgateway", "enqueuehermesgatewayevent"];
const ENABLE_CONFIRMATION = "enable-hermes-gateway-signal-required";
const ROLLBACK_CONFIRMATION = "rollback-hermes-gateway-signal-required";
const ACTIONS = new Set(["enable", "rollback"]);

function updateCommandForService(service, options) {
  const args = [
    "run",
    "services",
    "update",
    service,
    "--project",
    options.projectId,
    "--region",
    options.region,
  ];
  if (options.action === "rollback") {
    args.push("--remove-env-vars", SIGNAL_REQUIRED_ENV);
  } else {
    args.push("--update-env-vars", `${SIGNAL_REQUIRED_ENV}=true`);
  }
  return ["gcloud", ...args];
}

function expectedConfirmation(action) {
  return action === "rollback" ? ROLLBACK_CONFIRMATION : ENABLE_CONFIRMATION;
}

function buildRolloutPlan(options) {
  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    privacy: PRIVACY_MARKER,
    mode: options.execute ? "execute" : "dry_run",
    action: options.action,
    safety: {
      executeConfirmation: options.execute ? expectedConfirmation(options.action) : "not_requested",
      mutatesCloudRun: options.execute,
    },
    projectId: options.projectId,
    region: options.region,
    signalRequiredEnv: SIGNAL_REQUIRED_ENV,
    services: options.services.map((service) => ({
      service,
      command: updateCommandForService(service, options),
    })),
    followUpEvidence: {
      collector: "scripts/ci/write_hermes_gateway_migration_drain_evidence.js",
      validator: "scripts/ci/check_hermes_gateway_migration_drain.py",
      runtimeModeFlag: "--runtime-mode-from-gcloud",
      drain: "scripts/ci/drain_hermes_gateway_legacy_records.js",
    },
  };
}

function parseArgs(argv) {
  const options = {
    action: "enable",
    confirm: undefined,
    execute: false,
    output: undefined,
    projectId: DEFAULT_PROJECT_ID,
    region: DEFAULT_REGION,
    selfTest: false,
    services: [...DEFAULT_WRITE_PATH_SERVICES],
    servicesOverridden: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) {
        throw new Error(`${arg} requires a value`);
      }
      return argv[index];
    };
    if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg === "--execute") {
      options.execute = true;
    } else if (arg === "--rollback") {
      options.action = "rollback";
    } else if (arg === "--action") {
      options.action = next();
    } else if (arg === "--confirm") {
      options.confirm = next();
    } else if (arg === "--output") {
      options.output = next();
    } else if (arg === "--project-id") {
      options.projectId = next();
    } else if (arg === "--region") {
      options.region = next();
    } else if (arg === "--service") {
      if (!options.servicesOverridden) {
        options.services = [];
        options.servicesOverridden = true;
      }
      options.services.push(next());
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (!ACTIONS.has(options.action)) {
    throw new Error(`--action must be one of ${[...ACTIONS].join(", ")}`);
  }
  if (!options.services.length || options.services.some((service) => typeof service !== "string" || !service.trim())) {
    throw new Error("--service must name at least one Cloud Run service");
  }
  if (options.execute && options.confirm !== expectedConfirmation(options.action)) {
    throw new Error(`--execute ${options.action} requires --confirm ${expectedConfirmation(options.action)}`);
  }
  return options;
}

function runCommand(command) {
  const result = spawnSync(command[0], command.slice(1), { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`${command.join(" ")} failed: ${(result.stderr || result.stdout).trim()}`);
  }
}

function writePlan(plan, output) {
  const body = `${JSON.stringify(plan, null, 2)}\n`;
  if (output) {
    const outputPath = path.resolve(output);
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, body, "utf8");
    console.log(`Wrote Hermes Gateway Signal-required rollout plan: ${outputPath}`);
  } else {
    process.stdout.write(body);
  }
}

function executeRollout(plan) {
  for (const service of plan.services) {
    runCommand(service.command);
  }
}

function runSelfTest() {
  const enable = parseArgs([]);
  assert.equal(enable.action, "enable");
  assert.equal(enable.execute, false);
  assert.deepEqual(enable.services, DEFAULT_WRITE_PATH_SERVICES);
  assert.throws(
    () => parseArgs(["--execute", "--confirm", ROLLBACK_CONFIRMATION]),
    /--execute enable requires --confirm enable-hermes-gateway-signal-required/,
  );
  const rollback = parseArgs(["--rollback", "--execute", "--confirm", ROLLBACK_CONFIRMATION]);
  assert.equal(rollback.action, "rollback");
  assert.equal(rollback.execute, true);

  const enablePlan = buildRolloutPlan(enable);
  assert.equal(enablePlan.mode, "dry_run");
  assert.equal(enablePlan.action, "enable");
  assert.equal(enablePlan.safety.mutatesCloudRun, false);
  assert.equal(enablePlan.services.length, 2);
  assert.deepEqual(enablePlan.services[0].command, [
    "gcloud",
    "run",
    "services",
    "update",
    "burnbarhermesgateway",
    "--project",
    "burnbar",
    "--region",
    "us-central1",
    "--update-env-vars",
    "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true",
  ]);

  const rollbackPlan = buildRolloutPlan(rollback);
  assert.equal(rollbackPlan.mode, "execute");
  assert.equal(rollbackPlan.safety.executeConfirmation, ROLLBACK_CONFIRMATION);
  assert.equal(rollbackPlan.services[0].command.includes("--remove-env-vars"), true);
  assert.equal(JSON.stringify(enablePlan).includes("aggregate_counts_only_no_document_values_or_identifiers"), true);
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.selfTest) {
    runSelfTest();
    console.log("PASS: Hermes Gateway Signal-required rollout self-test passed");
    return;
  }

  const plan = buildRolloutPlan(options);
  if (options.execute) {
    executeRollout(plan);
  }
  writePlan(plan, options.output);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = {
  ENABLE_CONFIRMATION,
  ROLLBACK_CONFIRMATION,
  SIGNAL_REQUIRED_ENV,
  buildRolloutPlan,
  expectedConfirmation,
  parseArgs,
  updateCommandForService,
};
