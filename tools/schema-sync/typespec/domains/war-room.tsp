/**
 * War Room Hermes body registry Firestore contracts.
 * Collection: users/{uid}/hermes_bodies/{bodyId}
 *
 * A "body" is a MACHINE that has joined the War Room. A body is never a bot, a
 * persona, a chat profile, or a provider account: `bodyId` IS the existing
 * Hermes relay connection id (`relay-host-<installationUUID>`), so joining the
 * War Room mints no new identity and moves no credentials.
 *
 * Every field a probe cannot read is absent, never fabricated. A dry fountain
 * is reported dry.
 */
namespace OpenBurnBar.Firestore.WarRoom;

/**
 * Hardware a body reports about itself, read from sysctl on the machine.
 * Every field is optional: a probe that cannot read a value omits it rather
 * than substituting a zero or a guess.
 */
model HermesBodyHardwareDoc {
  hardwareModel?: string;
  chip?: string;
  memoryBytes?: int64;
  performanceCoreCount?: int32;
  efficiencyCoreCount?: int32;
  osVersion?: string;
}

/** Liveness of a body, derived from its own heartbeat — never inferred from traffic. */
model HermesBodyPresenceDoc {
  state: "online" | "idle" | "offline" | "unknown";
  lastHeartbeatAt: string;
  heartbeatIntervalSeconds: int32;
}

/** Firestore: users/{uid}/hermes_bodies/{bodyId} */
model HermesBodyDoc {
  bodyId: string;
  installationId: string;
  displayName: string;
  platform: "android" | "ios" | "linux" | "macos" | "windows";
  hardware: HermesBodyHardwareDoc;
  capabilities: ("advise" | "missionRun" | "observe" | "relayClient" | "relayHost")[];
  presence: HermesBodyPresenceDoc;
  joinedAt: string;
  updatedAt: string;
  schemaVersion: int32;
}

/**
 * Who caused a write. Embedded in usage, mission, and run documents so every
 * record names the door it came through.
 *
 * `confidence` is load-bearing: only a write the daemon itself spawned may
 * claim `exact`. Anything reconstructed from a log, a file mtime, or a
 * heuristic is `inferred`; anything unattributable is `unknown`.
 */
model OriginatorDoc {
  bodyId: string;
  kind: "agent" | "daemon" | "human" | "mission" | "unknown";
  surface: string;
  confidence: "exact" | "inferred" | "unknown";
  provenanceDetail?: string;
  label?: string;
  missionId?: string;
  runId?: string;
  recordedAt: string;
  schemaVersion: int32;
}
