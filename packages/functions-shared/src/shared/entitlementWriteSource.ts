/**
 * Returns whether an entitlement mutation belongs to the same verified
 * provider purchase as the existing document.
 */
export function sameEntitlementWriteSource(
  existing: Record<string, unknown>,
  incoming: {
    source: string;
    externalSubscriptionID?: string;
    purchaseTokenHash?: string;
  },
): boolean {
  if (existing.source !== incoming.source) {
    // A Stripe-bound operator bridge must yield to that same verified subscription.
    return (
      existing.source === "internal_operator_grant" &&
      existing.platform === "stripe" &&
      incoming.source === "stripe_webhook_verified" &&
      typeof incoming.externalSubscriptionID === "string" &&
      existing.externalSubscriptionID === incoming.externalSubscriptionID
    );
  }
  if (
    incoming.externalSubscriptionID &&
    typeof existing.externalSubscriptionID === "string" &&
    existing.externalSubscriptionID === incoming.externalSubscriptionID
  ) {
    return true;
  }
  if (
    incoming.purchaseTokenHash &&
    typeof existing.purchaseTokenHash === "string" &&
    existing.purchaseTokenHash === incoming.purchaseTokenHash
  ) {
    return true;
  }
  return !incoming.externalSubscriptionID && !incoming.purchaseTokenHash;
}
