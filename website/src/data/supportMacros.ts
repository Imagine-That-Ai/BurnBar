export interface SupportMacro {
  id: string;
  title: string;
  summary: string;
}

export const SUPPORT_MACROS: SupportMacro[] = [
  {
    id: "refund",
    title: "Refund request",
    summary:
      "Ask where the purchase was made, route Apple/Google purchases to store policy, and handle eligible Stripe refunds through support."
  },
  {
    id: "chargeback",
    title: "Chargeback or disputed payment",
    summary:
      "Explain that confirmed disputes revoke the matching entitlement and ask for the Stripe payment or store transaction reference."
  },
  {
    id: "cancellation",
    title: "Cancel a subscription",
    summary:
      "Send the user to Apple, Google Play, or Stripe billing management; cancellation stops renewal but keeps access until the paid period expires."
  },
  {
    id: "top-up-exhausted",
    title: "Cloud Pro top-up exhausted",
    summary:
      "Explain that hosted actions and relay are prepaid before use, BYOK actions do not consume hosted action credits, and monthly caps still apply."
  },
  {
    id: "permission-denied",
    title: "App Check or permission denied",
    summary:
      "Confirm sign-in, app version, entitlement status, and device trust before escalating with UID and timestamp."
  },
  {
    id: "grandfathered-subscriber",
    title: "Grandfathered Hosted Quota Sync",
    summary:
      "Clarify that legacy subscribers keep Group A Cloud features, but the legacy $4.99 plan is not a new purchase path and does not unlock Cloud Pro."
  },
  {
    id: "trial-conversion",
    title: "Trial or introductory offer",
    summary:
      "BurnBar Cloud monthly and annual include a 14-day introductory free trial for new subscribers. BurnBar Cloud Pro and top-ups do not include an introductory trial."
  }
];
