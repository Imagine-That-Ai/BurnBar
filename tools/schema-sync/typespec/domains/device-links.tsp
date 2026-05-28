/**
 * Provider account device link Firestore contracts.
 * Collection: users/{uid}/provider_account_device_links/{accountID}_{deviceID}
 */
namespace OpenBurnBar.Firestore.DeviceLinks;

/** Firestore: users/{uid}/provider_account_device_links/{accountID}_{deviceID} */
model ProviderAccountDeviceLinkDoc {
  id: string;
  accountID: string;
  deviceID: string;
  deviceDisplayName: string;
  capability: string;
  status: string;
  lastObservedAt: string;
  createdAt: string;
  updatedAt: string;
  schemaVersion: int32;
}
