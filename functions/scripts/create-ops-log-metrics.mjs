#!/usr/bin/env node
/**
 * Creates user-defined log metrics required by ops-alert-policy-definitions.mjs.
 * Idempotent: skips metrics that already exist.
 */
import { execFileSync } from "node:child_process";

const project = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar";

const METRICS = [
  {
    name: "openburnbar_callable_error",
    description: "Cloud Functions callable_error structured logs",
    filter: 'resource.type="cloud_function" AND jsonPayload.event="callable_error"',
  },
  {
    name: "openburnbar_circuit_breaker_tripped",
    description: "Resilience circuit breaker open events",
    filter: 'jsonPayload.event="circuit_breaker_tripped"',
  },
  {
    name: "openburnbar_hosted_mcp_5xx",
    description: "Hosted MCP 5xx responses",
    filter:
      'resource.type="cloud_run_revision" AND resource.labels.service_name="openburnbar-hosted-mcp" AND httpRequest.status>=500',
  },
  // Rollup full-rebuild health (P0-7). The pre-existing "Circuit breaker open"
  // policy watches the cockatiel resilience breakers (circuit_breaker_tripped),
  // a DIFFERENT family — the 2026-06-11 review found rollup breaker events had
  // no metric and no alert. Event keys must match functions/src exactly.
  {
    name: "openburnbar_rollup_breaker_open",
    description: "Per-user rollup full-rebuild circuit breaker opened/skipped",
    filter: 'jsonPayload.event="rollup.full_rebuild_circuit_open"',
  },
  {
    name: "openburnbar_rollup_rebuild_failed",
    description: "Rollup full-rebuild failures (in-process or stale attempt marker)",
    filter: 'jsonPayload.event="rollup.rebuild_failed"',
  },
  {
    name: "openburnbar_rollup_delta_drain_capped",
    description: "Pending-delta drains stopped by the per-invocation page cap (queue backlog)",
    filter: 'jsonPayload.event="rollup.delta_drain_capped"',
  },
];

function listMetrics() {
  try {
    const out = execFileSync(
      "gcloud",
      ["logging", "metrics", "list", `--project=${project}`, "--format=json"],
      { encoding: "utf8" },
    );
    return JSON.parse(out || "[]");
  } catch {
    return [];
  }
}

const existing = new Set(listMetrics().map((m) => m.name?.split("/").pop()));

for (const metric of METRICS) {
  if (existing.has(metric.name)) {
    console.error(`skip (exists): ${metric.name}`);
    continue;
  }
  console.error(`create: ${metric.name}`);
  execFileSync(
    "gcloud",
    [
      "logging",
      "metrics",
      "create",
      metric.name,
      `--description=${metric.description}`,
      `--log-filter=${metric.filter}`,
      `--project=${project}`,
    ],
    { stdio: "inherit" },
  );
}
