/** Insight canvas and widget Firestore contracts. */
namespace OpenBurnBar.Firestore.Insights;

model InsightCanvasDoc {
  id: string;
  title: string;
  theme: string;
  origin: string;
  updatedAt: string;
}

model InsightWidgetDoc {
  kind: string;
  canvasId: string;
  payloadJson: string;
  freshness: string;
}
