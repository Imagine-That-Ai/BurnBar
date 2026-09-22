import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// docker-compose.yml lives at the repo root; there is no other test home for
// it, so the container-hygiene assertions live with the quota-runner suite.
const compose = readFileSync(new URL("../../docker-compose.yml", import.meta.url), "utf8")
  .split("\n")
  .filter((line) => !line.trim().startsWith("#"))
  .join("\n");

test("emulator healthcheck avoids binaries missing from node:22-slim", () => {
  const healthcheck = compose.slice(compose.indexOf("healthcheck:"));
  assert.notEqual(compose.indexOf("healthcheck:"), -1, "compose file must define a healthcheck");
  assert.doesNotMatch(healthcheck, /\bcurl\b/, "node:22-slim ships no curl");
  assert.doesNotMatch(healthcheck, /\bwget\b/, "node:22-slim ships no wget");
});

test("emulator healthcheck probes the UI port with the node runtime", () => {
  const healthcheck = compose.slice(compose.indexOf("healthcheck:"));
  assert.match(healthcheck, /\bnode\b/, "healthcheck must use the node runtime probe");
  assert.match(healthcheck, /localhost:4000/, "healthcheck must probe the emulator UI");
});
