import { HttpsError } from "firebase-functions/v2/https";

import {
  gatewaySignalRequiredMode,
  sanitizeGatewayRelayEnvelopeCapabilities,
} from "@openburnbar/functions-shared/hermesGatewayEnvelope.js";
import type { HermesGatewaySignalPrekeyBundleDoc } from "@openburnbar/functions-shared/types/generated/hermes-gateway.js";
import { parseGatewaySignalPrekeyBundle } from "../hermesGatewaySignalPrekeys.js";

type GatewayCapabilities = ReturnType<typeof sanitizeGatewayRelayEnvelopeCapabilities>;

type AgentSignalState = {
  agentCapabilities?: GatewayCapabilities;
  agentSignalPrekeyBundle?: HermesGatewaySignalPrekeyBundleDoc;
};

export function parsePhoneSignalPairing(
  requestData: Record<string, unknown>,
  phoneCapabilities: GatewayCapabilities | undefined,
): HermesGatewaySignalPrekeyBundleDoc | undefined {
  const phoneSignalPrekeyBundle = parseGatewaySignalPrekeyBundle(requestData, "phone", (message) => {
    throw new HttpsError("invalid-argument", message);
  });
  if (phoneCapabilities?.supportsSignalEnvelope === true && !phoneSignalPrekeyBundle) {
    throw new HttpsError(
      "invalid-argument",
      "missing_phone_signal_prekey_bundle: Signal-capable pairings require a PQXDH bundle.",
    );
  }
  return phoneSignalPrekeyBundle;
}

export function signalPairingNeedsRequiredFailure(
  agentRelay: AgentSignalState,
  phoneCapabilities: GatewayCapabilities | undefined,
  phoneSignalPrekeyBundle: HermesGatewaySignalPrekeyBundleDoc | undefined,
): boolean {
  return (
    gatewaySignalRequiredMode() &&
    (agentRelay.agentCapabilities?.supportsSignalEnvelope !== true ||
      !agentRelay.agentSignalPrekeyBundle ||
      phoneCapabilities?.supportsSignalEnvelope !== true ||
      !phoneSignalPrekeyBundle)
  );
}
