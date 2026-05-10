export const BILLING_ALERT_POLICIES = [
  {
    displayName: "OpenBurnBar Firestore read spike",
    documentation: {
      content:
        "Firestore document reads are the first scaling cost signal. Inspect scheduled rollups, searchStreams, and mobile dashboard polling before raising thresholds.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["firestore.googleapis.com/document/read_count"],
    conditions: [
      {
        displayName: "Firestore reads exceed 50k/min",
        conditionThreshold: {
          filter:
            'resource.type="firestore_instance" AND metric.type="firestore.googleapis.com/document/read_count"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 50000,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar storage growth",
    documentation: {
      content:
        "Storage growth usually means large backup bodies are leaking into Firestore or Cloud Storage retention is too loose. Check session log manifests, chunks, and object lifecycle rules.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["firestore.googleapis.com/storage/data_and_index_storage_bytes"],
    conditions: [
      {
        displayName: "Firestore storage exceeds 50 GiB",
        conditionThreshold: {
          filter:
            'resource.type="firestore.googleapis.com/Database" AND metric.type="firestore.googleapis.com/storage/data_and_index_storage_bytes"',
          aggregations: [
            {
              alignmentPeriod: "3600s",
              perSeriesAligner: "ALIGN_MEAN",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 53687091200,
          duration: "3600s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar relay spend proxy",
    documentation: {
      content:
        "Cloud Run and Redis are the relay cost centers. This policy catches sustained relay request volume before it becomes a billing surprise.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: ["run.googleapis.com/request_count"],
    conditions: [
      {
        displayName: "Cloud Run request rate exceeds 1k/min",
        conditionThreshold: {
          filter:
            'resource.type="cloud_run_revision" AND metric.type="run.googleapis.com/request_count"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_RATE",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 1000,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
  {
    displayName: "OpenBurnBar Redis pressure",
    documentation: {
      content:
        "Redis pressure is the hosted relay's stateful cost and reliability signal. Inspect Hermes socket fan-out, relay socket limits, and key TTL behavior before raising thresholds.",
      mimeType: "text/markdown",
    },
    combiner: "OR",
    requiredMetricTypes: [
      "redis.googleapis.com/stats/memory/usage_ratio",
      "redis.googleapis.com/clients/connected",
    ],
    conditions: [
      {
        displayName: "Redis memory usage exceeds 80%",
        conditionThreshold: {
          filter:
            'resource.type="redis_instance" AND metric.type="redis.googleapis.com/stats/memory/usage_ratio"',
          aggregations: [
            {
              alignmentPeriod: "300s",
              perSeriesAligner: "ALIGN_MEAN",
              crossSeriesReducer: "REDUCE_MAX",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 0.8,
          duration: "600s",
          trigger: { count: 1 },
        },
      },
      {
        displayName: "Redis connected clients exceed 1k",
        conditionThreshold: {
          filter:
            'resource.type="redis_instance" AND metric.type="redis.googleapis.com/clients/connected"',
          aggregations: [
            {
              alignmentPeriod: "60s",
              perSeriesAligner: "ALIGN_MEAN",
              crossSeriesReducer: "REDUCE_SUM",
            },
          ],
          comparison: "COMPARISON_GT",
          thresholdValue: 1000,
          duration: "300s",
          trigger: { count: 1 },
        },
      },
    ],
  },
];

export function materializeBillingAlertPolicy(policy, notificationChannels) {
  const { requiredMetricTypes: _requiredMetricTypes, ...alertPolicy } = policy;
  return {
    ...alertPolicy,
    enabled: true,
    notificationChannels,
    alertStrategy: { autoClose: "604800s" },
    userLabels: {
      app: "openburnbar",
      launch_gate: "commercial",
    },
  };
}
