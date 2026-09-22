import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const dockerfile = readFileSync(new URL("../Dockerfile", import.meta.url), "utf8");
const lines = dockerfile
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith("#"));

function lastInstruction(keyword) {
  const matches = lines.filter((line) => line.startsWith(`${keyword} `));
  return matches.length > 0 ? matches[matches.length - 1] : undefined;
}

test("quota-runner image drops to a non-root user", () => {
  const user = lastInstruction("USER");
  assert.ok(user, "Dockerfile must declare a USER");
  const name = user.split(/\s+/)[1];
  assert.ok(name && name !== "root" && name !== "0", `expected non-root USER, got: ${user}`);
});

test("quota-runner drops privileges after install steps and keeps /app readable", () => {
  const userIndex = lines.findLastIndex((line) => line.startsWith("USER "));
  const lastRunIndex = lines.findLastIndex((line) => line.startsWith("RUN "));
  assert.ok(userIndex > lastRunIndex, "USER must come after the install RUN steps");
  assert.match(
    dockerfile,
    /chown -R \S+ \/app/,
    "expected /app ownership handoff before dropping privileges",
  );
});

test("quota-runner image probes /healthz without external binaries", () => {
  const healthcheck = lines.find((line) => line.startsWith("HEALTHCHECK "));
  assert.ok(healthcheck, "Dockerfile must declare a HEALTHCHECK");
  assert.match(dockerfile, /\/healthz/, "HEALTHCHECK must probe the /healthz endpoint");
  assert.doesNotMatch(lines.join("\n"), /curl|wget/, "HEALTHCHECK must not depend on curl/wget");
});
