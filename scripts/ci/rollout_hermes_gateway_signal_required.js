#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");

const SIGNAL_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true";
const SERVICES = ["burnbarhermesgateway", "enqueuehermesgatewayevent"];

function parseArgs(argv) {
  const options = { action: "dry_run", projectId: undefined, region: "us-central1", mutatesCloudRun: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[index];
    };
    if (arg === "enable-hermes-gateway-signal-required") {
      options.action = "enable-hermes-gateway-signal-required";
      options.mutatesCloudRun = true;
    } else if (arg === "rollback-hermes-gateway-signal-required") {
      options.action = "rollback-hermes-gateway-signal-required";
      options.mutatesCloudRun = true;
    } else if (arg === "--project-id") options.projectId = next();
    else if (arg === "--region") options.region = next();
    else if (arg === "--dry-run") options.mutatesCloudRun = false;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return options;
}

function gcloud(args, options) {
  const command = ["run", "services", "update", ...args, "--region", options.region];
  if (options.projectId) command.push("--project", options.projectId);
  if (!options.mutatesCloudRun) {
    console.log(`[dry_run] gcloud ${command.join(" ")}`);
    return;
  }
  const result = spawnSync("gcloud", command, { encoding: "utf8", stdio: "inherit" });
  if (result.status !== 0) throw new Error(`gcloud failed for ${command.join(" ")}`);
}

function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.action === "enable-hermes-gateway-signal-required") {
    for (const service of SERVICES) {
      gcloud([service, "--update-env-vars", SIGNAL_ENV], options);
    }
  } else if (options.action === "rollback-hermes-gateway-signal-required") {
    for (const service of SERVICES) {
      gcloud([service, "--remove-env-vars", "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED"], options);
    }
  } else {
    console.log("[dry_run] choose enable-hermes-gateway-signal-required or rollback-hermes-gateway-signal-required");
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  }
}
