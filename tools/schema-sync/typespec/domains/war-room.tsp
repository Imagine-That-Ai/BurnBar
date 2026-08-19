/**
 * War Room Firestore contracts: machine-bound Hermes identity ("bodies"),
 * Wire grants between bodies, and STARTED BY work attribution.
 * Collections:
 *   users/{uid}/hermes_bodies/{bodyId}
 *   users/{uid}/war_wire_grants/{pairId}
 */
namespace OpenBurnBar.Firestore.WarRoom;

union HermesBodyPresenceState {
  online: "online",
  idle: "idle",
  offline: "offline",
}

/** Static hardware identity for a body. Unknown fields stay absent and render em-dash. */
model HermesBodyHardware {
  hardwareModel?: string;
  chipBrand?: string;
  coresPerformance?: int32;
  coresEfficiency?: int32;
  memBytes?: int64;
  gpu?: string;
}

model HermesBodyHermesState {
  installed: boolean;
  gatewayReachable: boolean;
  version?: string;
  gatewayClientId?: string;
  botCount?: int32;
  botsUpdatedAt?: string;
}

model HermesBodyEndpoints {
  irohNodeId?: string;
  pairingConnectionId: string;
}

model HermesBodyPresence {
  state: HermesBodyPresenceState;
  lastHeartbeatAt: string;
  wireReachable: boolean;
}

/**
 * Firestore: users/{uid}/hermes_bodies/{bodyId}
 * bodyId == relay-host-<installationUUID> (the canonical per-Mac Hermes
 * connection id). Written only by the owning Mac; the body is the join of the
 * device doc, the Hermes connection, the iroh endpoint, and the hardware.
 */
model HermesBodyDoc {
  id: string;
  deviceID: string;
  displayName: string;
  machineName: string;
  platform: string;
  hardware: HermesBodyHardware;
  hermes: HermesBodyHermesState;
  endpoints: HermesBodyEndpoints;
  presence: HermesBodyPresence;
  capabilities: string[];
  schemaVersion: int32;
  createdAt: string;
  updatedAt: string;
}

union OriginatorKind {
  userLocal: "user_local",
  userRemote: "user_remote",
  flame: "flame",
  wand: "wand",
  mission: "mission",
  hermesBot: "hermes_bot",
  hermesCron: "hermes_cron",
  external: "external",
  unknownKind: "unknown",
}

union OriginatorConfidence {
  exact: "exact",
  inferred: "inferred",
  unknownConfidence: "unknown",
}

/** STARTED BY attribution stamped wherever work begins (Command Board column). */
model OriginatorRef {
  kind: OriginatorKind;
  label: string;
  bodyID?: string;
  decisionID?: string;
  missionID?: string;
  missionGroupID?: string;
  botName?: string;
  confidence: OriginatorConfidence;
}

union WarWireGrantState {
  active: "active",
  revoked: "revoked",
}

/**
 * Firestore: users/{uid}/war_wire_grants/{pairId}
 * pairId == the two bodyIds sorted lexicographically and joined with "__".
 * Revocable from either machine; unverifiable state reads as revoked.
 */
model WarWireGrantDoc {
  id: string;
  bodyIdA: string;
  bodyIdB: string;
  state: WarWireGrantState;
  grantedByDeviceID: string;
  grantedAt: string;
  revokedByDeviceID?: string;
  revokedAt?: string;
  schemaVersion: int32;
  createdAt: string;
  updatedAt: string;
}
