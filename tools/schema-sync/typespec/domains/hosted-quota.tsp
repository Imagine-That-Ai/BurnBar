/** Hosted quota entitlement and binding contracts. */
namespace OpenBurnBar.Firestore.HostedQuota;

model EntitlementBindingDoc {
  appAccountToken: string;
  uid: string;
  createdAt: string;
}

model EntitlementEventDoc {
  eventType: string;
  signedDateMs: int64;
  originalTransactionId?: string;
  createdAt: string;
}
