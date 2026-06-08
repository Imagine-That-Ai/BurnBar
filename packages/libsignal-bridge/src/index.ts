import * as libsignal from "@signalapp/libsignal-client";

export * from "@signalapp/libsignal-client";
export * from "./protocolHarness.js";

export const LIBSIGNAL_PIN = {
  packageName: "@signalapp/libsignal-client",
  version: "0.94.4",
  upstreamRepository: "https://github.com/signalapp/libsignal",
  upstreamTag: "v0.94.4",
  upstreamTagObject: "03c449017b57eccbda715b8b018dce5dff603ac6",
  upstreamCommit: "46d867c986f66201e34e7ae20ce423eec742bf3f",
  license: "AGPL-3.0-only",
} as const;

export const REQUIRED_SIGNAL_PROTOCOL_SYMBOLS = [
  "IdentityKeyPair",
  "PreKeyRecord",
  "SignedPreKeyRecord",
  "KyberPreKeyRecord",
  "SessionRecord",
  "ProtocolAddress",
  "processPreKeyBundle",
  "signalEncrypt",
  "signalDecrypt",
  "signalDecryptPreKey",
  "Fingerprint",
] as const;

export interface LibsignalReadinessReport {
  ok: true;
  pin: typeof LIBSIGNAL_PIN;
  requiredSymbols: typeof REQUIRED_SIGNAL_PROTOCOL_SYMBOLS;
}

export function assertOfficialLibsignalReady(): LibsignalReadinessReport {
  const client = libsignal as Record<string, unknown>;
  const missing = REQUIRED_SIGNAL_PROTOCOL_SYMBOLS.filter((symbol) => client[symbol] === undefined);
  if (missing.length > 0) {
    throw new Error(`Official libsignal client is missing required symbols: ${missing.join(", ")}`);
  }
  return {
    ok: true,
    pin: LIBSIGNAL_PIN,
    requiredSymbols: REQUIRED_SIGNAL_PROTOCOL_SYMBOLS,
  };
}

export { libsignal };
