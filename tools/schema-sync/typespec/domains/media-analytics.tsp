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
  day: string;
  sessionCount: int32;
  bytesTransferred: float32;
}
