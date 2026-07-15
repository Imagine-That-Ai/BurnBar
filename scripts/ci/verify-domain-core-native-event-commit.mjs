#!/usr/bin/env node

import { fileURLToPath } from "node:url";

const FULL_GIT_SHA1 = /^[0-9a-f]{40}$/u;
const ALLOWED_EVENTS = new Set(["push", "workflow_dispatch"]);

function fullCommit(value, label) {
  if (typeof value !== "string" || !FULL_GIT_SHA1.test(value)) {
    throw new Error(`${label} must be a full lowercase Git SHA-1`);
  }
  return value;
}

export function validateNativeReleaseEventCommit({
  eventName,
  eventCommit,
  releaseCommit,
}) {
  if (!ALLOWED_EVENTS.has(eventName)) {
    throw new Error("native release event must be push or workflow_dispatch");
  }
  const eventSha = fullCommit(eventCommit, "GitHub event commit");
  const resolvedReleaseCommit = fullCommit(
    releaseCommit,
    "resolved release commit",
  );
  if (eventName === "push" && resolvedReleaseCommit !== eventSha) {
    throw new Error(
      `tag push release commit must equal GITHUB_SHA: release=${resolvedReleaseCommit} event=${eventSha}`,
    );
  }
  return {
    eventName,
    eventCommit: eventSha,
    releaseCommit: resolvedReleaseCommit,
  };
}

export function run(argv) {
  if (
    argv.length !== 6 ||
    argv[0] !== "--event-name" ||
    argv[2] !== "--event-commit" ||
    argv[4] !== "--release-commit"
  ) {
    throw new Error(
      "usage: --event-name NAME --event-commit SHA --release-commit SHA",
    );
  }
  const result = validateNativeReleaseEventCommit({
    eventName: argv[1],
    eventCommit: argv[3],
    releaseCommit: argv[5],
  });
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
