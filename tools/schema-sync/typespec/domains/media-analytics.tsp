/** Mercury media analytics and quota rollup contracts. */
namespace OpenBurnBar.Firestore.MediaAnalytics;

model MediaQuotaUsageDoc {
  id: string;
  schemaVersion: int32;
  bytesUploadedFile: float32;
  bytesDownloadedFile: float32;
  screenShareSecondsUsed: float32;
  videoCallSecondsUsed: float32;
}

model MediaSessionDailyRollupDoc {
  id: string;
  date: string;
  windowStart: string;
  windowEnd: string;
  generatedAt: string;
  totalEvents: int32;
  uniqueUsers: int32;
  perFeature: Record<MediaSessionDailyFeatureRollup>;
  schemaVersion: int32;
}

model MediaSessionDailyFeatureRollup {
  sessionCount: int32;
  successRate: float32;
  fallbackRate: float32;
  totalSeconds: int32;
  totalBytes: float32;
  rttMillis: MediaSessionPercentileSummary;
  bitsPerSecond: MediaSessionPercentileSummary;
  freezeCount: MediaSessionPercentileSummary;
}

model MediaSessionPercentileSummary {
  count: int32;
  p50?: float32;
  p95?: float32;
  p99?: float32;
  sketchBase64?: string;
}
