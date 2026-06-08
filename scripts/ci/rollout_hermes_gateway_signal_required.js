#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");

const SIGNAL_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true";
const SOURCE_COMMIT_ENV = "OPENBURNBAR_SOURCE_COMMIT";
const SOURCE_URL_ENV = "OPENBURNBAR_CORRESPONDING_SOURCE_URL";
const SERVICES = ["burnbarhermesgateway", "enqueuehermesgatewayevent"];
const GIT_SHA_RE = /^[0-9a-f]{40}$/;

function parseArgs(argv) {
  const options = {
    action: "dry_run",
    projectId: undefined,
    region: "us-central1",
    mutatesCloudRun: false,
    deployedCommit: undefined,
    sourceLocation: undefined,
  };
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
    else if (arg === "--deployed-commit") options.deployedCommit = next();
    else if (arg === "--source-location") options.sourceLocation = next();
    else if (arg === "--dry-run") options.mutatesCloudRun = false;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (options.action === "enable-hermes-gateway-signal-required") {
    if (!GIT_SHA_RE.test(options.deployedCommit || "")) {
      throw new Error("--deployed-commit is required and must be the 40-character commit deployed to Cloud Functions");
    }
    if (!/^https:\/\/|^git@/.test(options.sourceLocation || "")) {
      throw new Error("--source-location is required and must be an https:// or git@ source URL");
    }
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
    const envVars = [
      SIGNAL_ENV,
      `${SOURCE_COMMIT_ENV}=${options.deployedCommit}`,
      `${SOURCE_URL_ENV}=${options.sourceLocation}`,
    ].join(",");
    for (const service of SERVICES) {
      gcloud([service, "--update-env-vars", envVars], options);
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
