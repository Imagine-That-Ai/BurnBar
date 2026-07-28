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
      "Tell us where you bought. App Store purchases follow Apple's refund policy; future Google Play purchases follow Play policy; Stripe Checkout purchases are refunded by support when eligible."
  },
  {
    id: "chargeback",
    title: "Chargeback or disputed payment",
    summary:
      "A confirmed payment dispute revokes the matching subscription or top-up. Include your Stripe payment or store transaction reference so we can trace it quickly."
  },
  {
    id: "cancellation",
    title: "Cancel a subscription",
    summary:
      "Cancel anytime in your Apple subscriptions or Stripe billing portal. Google Play management arrives with the public Android listing. Cancelling stops renewal; access continues until the paid period ends."
  },
  {
    id: "top-up-exhausted",
    title: "Cloud Pro top-up exhausted",
    summary:
      "Hosted actions and relay transfer are prepaid before use. Bring-your-own-key actions never consume hosted action credits, and monthly caps still apply."
  },
  {
    id: "permission-denied",
    title: "App Check or permission denied",
    summary:
      "Check that you're signed in, on the latest app version, and that your subscription is active. Still stuck? Email us the account address and roughly when it happened — we can trace the exact denial."
  },
  {
    id: "grandfathered-subscriber",
    title: "Grandfathered Hosted Quota Sync",
    summary:
      "Legacy $4.99 Hosted Quota Sync subscribers keep BurnBar Cloud's core sync features. That plan is no longer sold and does not unlock Cloud Pro."
  },
  {
    id: "checkout-total",
    title: "Checkout price or renewal",
    summary:
      "No introductory offer is promised. Stripe Checkout or the App Store shows the exact price, cadence, tax, and renewal terms before confirmation."
  }
];
