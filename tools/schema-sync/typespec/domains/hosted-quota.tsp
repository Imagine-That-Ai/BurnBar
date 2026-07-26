/** Hosted quota entitlement and binding contracts. */
namespace OpenBurnBar.Firestore.HostedQuota;

model EntitlementBindingDoc {
  id: string;
  appAccountToken: string;
  uid: string;
  productID: string;
  clientPlatform?: "ios" | "ipados" | "macos";
  consumedAt?: string;
  createdAt: string;
  schemaVersion: int32;
}

model EntitlementEventDoc {
  eventType: string;
  signedDateMs: int64;
  originalTransactionId?: string;
  createdAt: string;
}
