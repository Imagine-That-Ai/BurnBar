type GooglePlayBillingRecordKind = "purchase" | "topup";

const GOOGLE_PLAY_BILLING_DOCS: Record<GooglePlayBillingRecordKind, string> = {
  purchase: "google_play_purchases",
  topup: "google_play_topups",
};

export function googlePlayBillingRecordPath(uid: string, kind: GooglePlayBillingRecordKind, tokenHash: string): string {
  const billingDoc = GOOGLE_PLAY_BILLING_DOCS[kind];
  return `users/${uid}/billing/${billingDoc}/tokens/${tokenHash}`;
}
