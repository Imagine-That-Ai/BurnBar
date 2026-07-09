import assert from "node:assert/strict";
import test from "node:test";

import { parseDashboardArgs, runDashboard } from "./community-rollout-dashboard.mjs";

function argv(...args) {
  return ["node", "community-rollout-dashboard.mjs", ...args];
}

test("parseDashboardArgs accepts explicit canary and stale options", () => {
  const options = parseDashboardArgs(argv(
    "--project", "burnbar-staging",
    "--api-key", "web-key",
    "--threshold-doc", "today_world_threshold",
    "--live-doc", "today_world_live",
    "--revoked-anon-id", "revoked-1",
    "--database", "community-db",
    "--stale-hours", "6",
    "--strict",
    "--json",
  ), {});

  assert.equal(options.project, "burnbar-staging");
  assert.equal(options.apiKey, "web-key");
  assert.equal(options.thresholdDoc, "today_world_threshold");
  assert.equal(options.liveDoc, "today_world_live");
  assert.equal(options.revokedAnonId, "revoked-1");
  assert.equal(options.database, "community-db");
  assert.equal(options.staleHours, 6);
  assert.equal(options.strict, true);
  assert.equal(options.json, true);
});

test("parseDashboardArgs rejects invalid staleness windows", () => {
  assert.throws(
    () => parseDashboardArgs(argv("--project", "burnbar-staging", "--stale-hours", "-1"), {}),
    /--stale-hours must be a non-negative number/,
  );
});

test("runDashboard fails closed when canary inputs are incomplete", async () => {
  await assert.rejects(
    () => runDashboard({
      project: "burnbar-staging",
      apiKey: "",
      uid: "community-canary",
      thresholdDoc: "",
      liveDoc: "",
      revokedAnonId: "",
      database: "(default)",
      staleHours: 48,
      strict: false,
      skipCanary: false,
      json: false,
    }),
    /canary inputs are incomplete/,
  );
});
