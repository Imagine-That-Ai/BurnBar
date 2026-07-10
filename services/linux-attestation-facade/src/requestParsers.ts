import { ATTESTATION_KIND, PROTOCOL_VERSION } from "./contracts.js";
import { PublicError } from "./errors.js";
import { base64, brokerLabel, exactKeys, integer, object, sha256Hex } from "./validation.js";

export function parseBeginEnrollment(value: unknown): { deviceId: string; ekCertificateBase64: string; ekTpmBase64: string; akTpmBase64: string } {
  const source = object(value, "request");
  exactKeys(source, ["deviceId", "ekCertificateBase64", "ekTpmBase64", "akTpmBase64"], "request");
  return {
    deviceId: brokerLabel(source.deviceId, "deviceId"),
    ekCertificateBase64: base64(source.ekCertificateBase64, "ekCertificateBase64", 128 * 1024),
    ekTpmBase64: base64(source.ekTpmBase64, "ekTpmBase64", 64 * 1024),
    akTpmBase64: base64(source.akTpmBase64, "akTpmBase64", 64 * 1024),
  };
}

export function parseCompleteEnrollment(value: unknown): { deviceId: string; activationProof: string } {
  const source = object(value, "request");
  exactKeys(source, ["deviceId", "activationProof"], "request");
  return {
    deviceId: brokerLabel(source.deviceId, "deviceId"),
    activationProof: base64(source.activationProof, "activationProof", 128 * 1024),
  };
}

export function parseCreateUpload(value: unknown): {
  appId: string; deviceId: string; challengeId: string; releaseDigestSha256: string; expectedSha256: string; expectedSize: number;
} {
  const source = object(value, "request");
  exactKeys(source, ["protocolVersion", "attestationKind", "appId", "deviceId", "challengeId", "releaseDigestSha256", "expectedSha256", "expectedSize"], "request");
  if (source.protocolVersion !== PROTOCOL_VERSION || source.attestationKind !== ATTESTATION_KIND) {
    throw new PublicError(400, "bad_request", "Unsupported attestation protocol");
  }
  return {
    appId: brokerLabel(source.appId, "appId"),
    deviceId: brokerLabel(source.deviceId, "deviceId"),
    challengeId: brokerLabel(source.challengeId, "challengeId"),
    releaseDigestSha256: sha256Hex(source.releaseDigestSha256, "releaseDigestSha256"),
    expectedSha256: sha256Hex(source.expectedSha256, "expectedSha256"),
    expectedSize: integer(source.expectedSize, "expectedSize", 1, 64 * 1024 * 1024),
  };
}
