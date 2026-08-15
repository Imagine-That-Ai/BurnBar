type GooglePlayBillingRecordKind = "purchase" | "topup" | "memory_pack";

const GOOGLE_PLAY_BILLING_DOCS: Record<GooglePlayBillingRecordKind, string> = {
  purchase: "google_play_purchases",
  topup: "google_play_topups",
  memory_pack: "google_play_memory_packs",
};

export function googlePlayBillingRecordPath(uid: string, kind: GooglePlayBillingRecordKind, tokenHash: string): string {
  const billingDoc = GOOGLE_PLAY_BILLING_DOCS[kind];
  return `users/${uid}/billing/${billingDoc}/tokens/${tokenHash}`;
}
