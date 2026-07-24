import { generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";

const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

export function rawEd25519PublicKey(publicKey: KeyObject): Buffer {
  return publicKey.export({ format: "der", type: "spki" }).subarray(-32);
}

export function base32NoPad(raw: Buffer): string {
  let accumulator = 0;
  let bitCount = 0;
  let encoded = "";
  for (const byte of raw) {
    accumulator = (accumulator << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5) {
      bitCount -= 5;
      encoded += BASE32_ALPHABET[(accumulator >> bitCount) & 31];
      accumulator &= (1 << bitCount) - 1;
    }
  }
  if (bitCount > 0) encoded += BASE32_ALPHABET[(accumulator << (5 - bitCount)) & 31];
  return encoded;
}

export function callableRunner(callable: unknown): (request: unknown) => Promise<unknown> {
  const run =
    callable && (typeof callable === "object" || typeof callable === "function")
      ? Reflect.get(callable, "run")
      : undefined;
  if (typeof run !== "function") throw new Error("callable test target is missing run()");
  return (request: unknown) => run.call(callable, request);
}

export function callableRequest(uid: string, data: Record<string, unknown>, appId = "1:123:ios:route-test") {
  return {
    auth: { uid, token: {} },
    app: { appId },
    data,
    rawRequest: { headers: {} },
  };
}

type RouteChallenge = {
  challengeId: string;
  canonicalPayloadBase64: string;
  proofKind: "bootstrap" | "transport-renewal";
  requiresAuthorityProof: boolean;
  registrationGeneration: number;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (isRecord(value)) return value;
  throw new Error(`${label} must be an object`);
}

function requireString(value: unknown, label: string): string {
  if (typeof value === "string") return value;
  throw new Error(`${label} must be a string`);
}

function requireBoolean(value: unknown, label: string): boolean {
  if (typeof value === "boolean") return value;
  throw new Error(`${label} must be a boolean`);
}

export function requireNumber(value: unknown, label: string): number {
  if (typeof value === "number") return value;
  throw new Error(`${label} must be a number`);
}

export function requireRouteChallenge(value: unknown): RouteChallenge {
  const record = requireRecord(value, "route challenge");
  const proofKind = record.proofKind;
  if (proofKind !== "bootstrap" && proofKind !== "transport-renewal") {
    throw new Error("route challenge proofKind is invalid");
  }
  return {
    challengeId: requireString(record.challengeId, "route challenge challengeId"),
    canonicalPayloadBase64: requireString(record.canonicalPayloadBase64, "route challenge canonicalPayloadBase64"),
    proofKind,
    requiresAuthorityProof: requireBoolean(record.requiresAuthorityProof, "route challenge requiresAuthorityProof"),
    registrationGeneration: requireNumber(record.registrationGeneration, "route challenge registrationGeneration"),
  };
}

export function requireActiveRouteResolution(value: unknown): { uid: string; routes: Array<Record<string, unknown>> } {
  const record = requireRecord(value, "route resolution");
  const routesValue = record.routes;
  if (!Array.isArray(routesValue)) throw new Error("route resolution routes must be an array");
  return {
    uid: requireString(record.uid, "route resolution uid"),
    routes: routesValue.map((route, index) => requireRecord(route, `route resolution route ${index}`)),
  };
}

export function snapshotTenantPaths(
  store: Map<string, Record<string, unknown>>,
  uid: string,
): Map<string, Record<string, unknown>> {
  return new Map([...store].filter(([path]) => path.startsWith(`users/${uid}/`)));
}

export function seedRouteTrustGraph(args: {
  connectionId: string;
  hostDeviceId: string;
  sourceDeviceId: string;
  store: Map<string, Record<string, unknown>>;
  uid: string;
}) {
  const host = generateKeyPairSync("ed25519");
  const hostPublic = rawEd25519PublicKey(host.publicKey);
  const hostNodeId = randomBytes(32).toString("hex");
  const publishedAtMillis = Date.now();
  const canonicalPairing = Buffer.from(
    `openburnbar.iroh.pairing.v1|${args.uid}|${args.connectionId}|${hostNodeId}|||${publishedAtMillis}`,
    "utf8",
  );
  const authority = generateKeyPairSync("ed25519");
  const authorityPublic = rawEd25519PublicKey(authority.publicKey);
  const authorityPeerNodeId = `ios-phone-${authorityPublic.subarray(0, 12).toString("hex")}`;
  const transport = generateKeyPairSync("ed25519");
  const transportNodeId = rawEd25519PublicKey(transport.publicKey).toString("hex");

  args.store.set(`users/${args.uid}/escrow_devices/${args.hostDeviceId}`, {
    deviceId: args.hostDeviceId,
    platform: "Linux",
    trustState: "trusted",
  });
  args.store.set(`users/${args.uid}/escrow_devices/${args.sourceDeviceId}`, {
    deviceId: args.sourceDeviceId,
    platform: "iOS",
    trustState: "trusted",
    peerNodeId: authorityPeerNodeId,
  });
  args.store.set(`users/${args.uid}/iroh_pairing_keys/host`, {
    id: "host",
    publicKeyBase64: hostPublic.toString("base64"),
    publishedByDeviceId: args.hostDeviceId,
  });
  args.store.set(`users/${args.uid}/iroh_pairing/${args.connectionId}`, {
    id: args.connectionId,
    nodeId: hostNodeId,
    directAddresses: [],
    publishedAtMillis,
    protocolVersion: 1,
    signature: sign(null, canonicalPairing, host.privateKey).toString("base64"),
    publishedByDeviceId: args.hostDeviceId,
    authorizedControllerDeviceIds: [args.sourceDeviceId],
  });
  args.store.set(`users/${args.uid}/iroh_pairing/${args.connectionId}/controllers/${authorityPeerNodeId}`, {
    id: authorityPeerNodeId,
    connectionId: args.connectionId,
    peerNodeId: authorityPeerNodeId,
    deviceId: args.sourceDeviceId,
    publicKeyBase64: authorityPublic.toString("base64"),
    signingKeyKind: "ed25519",
  });
  return { authority, authorityPeerNodeId, transport, transportNodeId };
}
