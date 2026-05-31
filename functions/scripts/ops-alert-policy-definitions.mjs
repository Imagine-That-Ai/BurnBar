/**
 * Repo-owned Cloud Monitoring alert policies for OpenBurnBar ops (SLO + cost).
 * Apply with: node functions/scripts/apply-ops-alert-policies.mjs
 */

import { BILLING_ALERT_POLICIES } from "./billing-alert-policy-definitions.mjs";

/** Core SLO / reliability policies (GCP-primary paging plane). */
export const OPS_SLO_ALERT_POLICIES = [
  {
    displayName: "OpenBurnBar Callable error spike",
    documentation: {
      content:
        "Structured callable_error logs exceeded threshold. Correlate by trace_id in Cloud Logging; check recent Functions deploy.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["logging.googleapis.com/user/openburnbar_callable_error"],
    conditions: [
      {
        displayName: "Callable errors > 30/min",
        conditionThreshold: {
          filter:
            'metric.type="logging.googleapis.com/user/openburnbar_callable_error" AND resource.type="cloud_function"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 30,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar Circuit breaker open",
    documentation: {
      content:
        "A resilience circuit breaker tripped (Stripe, push, Firestore bulkhead, or external API). Inspect resilience_failure logs.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["logging.googleapis.com/user/openburnbar_circuit_breaker_tripped"],
    conditions: [
      {
        displayName: "Circuit breaker trips > 5/min",
        conditionThreshold: {
          filter:
            'resource.type="cloud_function" AND metric.type="logging.googleapis.com/user/openburnbar_circuit_breaker_tripped"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 5,
          duration: "180s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar healthReady degraded",
    documentation: {
      content:
        "healthReady returned non-ready responses. Firestore or cold-start degradation; run post-deploy-health-gate and rollback if needed.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["run.googleapis.com/request_count"],
    conditions: [
      {
        displayName: "healthReady 5xx rate",
        conditionThreshold: {
          filter:
            'resource.type="cloud_run_revision" AND metric.type="run.googleapis.com/request_count" AND metric.labels.response_code_class="5xx" AND resource.labels.service_name=monitoring.regex.full_match("healthready")',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 1,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar Hosted MCP 5xx spike",
    documentation: {
      content: "Hosted MCP Cloud Run 5xx spike. See docs/REMOTE_MCP_RUNBOOK.md.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["logging.googleapis.com/user/openburnbar_hosted_mcp_5xx"],
    conditions: [
      {
        displayName: "Hosted MCP 5xx > 10/min",
        conditionThreshold: {
          filter:
            'resource.type="cloud_run_revision" AND metric.type="logging.googleapis.com/user/openburnbar_hosted_mcp_5xx"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 10,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
];

/** All policies verified by commercial-launch-gate checkOpsAlerts. */
export const OPS_ALERT_POLICIES = [...OPS_SLO_ALERT_POLICIES, ...BILLING_ALERT_POLICIES];

export function materializeOpsAlertPolicy(policy, notificationChannels) {
  const { requiredMetricTypes: _requiredMetricTypes, ...alertPolicy } = policy;
  return {
    ...alertPolicy,
    enabled: true,
    notificationChannels,
    alertStrategy: { autoClose: "604800s" },
    userLabels: {
      app: "openburnbar",
      launch_gate: "ops",
    },
  };
}
