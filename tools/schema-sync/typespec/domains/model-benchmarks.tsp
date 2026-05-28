/**
 * Model benchmark snapshot and source-status Firestore contracts.
 * Collections: model_benchmark_snapshots, model_benchmark_source_status
 */
namespace OpenBurnBar.Firestore.ModelBenchmarks;

/** Firestore: model_benchmark_snapshots/{source_model_task_timestamp} */
model ModelBenchmarkSnapshotDoc {
  id: string;
  source: string;
  sourceURL?: string;
  attribution?: string;
  fetchedAt: string;
  modelID: string;
  providerID?: string;
  taskCategory: string;
  score?: float32;
  rank?: int32;
  costSignal?: float32;
  inputCostPerMtoken?: float32;
  outputCostPerMtoken?: float32;
  blendedCostPerMtoken?: float32;
  latencySignal?: float32;
  contextWindowTokens?: int32;
  reliabilitySignal?: float32;
  confidence?: float32;
  freshness: string;
  schemaVersion: int32;
  updatedAt: string;
}

/** Firestore: model_benchmark_source_status/{source} */
model ModelBenchmarkSourceStatusDoc {
  source: string;
  status: string;
  fetchedAt?: string;
  message: string;
  attribution?: string;
  schemaVersion: int32;
  updatedAt: string;
}
