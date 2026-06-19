/**
 * Backend analytics configuration — the API key + zone are read from the
 * platform's EXISTING secret/config mechanism. ZERO keys are committed.
 *
 *  - `AMPLITUDE_API_KEY` is a Secret Manager secret (`defineSecret`), resolved at
 *    request time via `.value()` (secrets only populate `process.env` inside a
 *    handler that declared them in its `secrets:` array). It falls back to the
 *    plain env var for local/emulator/CI runs. With neither set it is `""`, and
 *    the recorder's key gate keeps the whole stream dark by construction.
 *  - `AMPLITUDE_SERVER_ZONE` selects US (default) vs EU data residency.
 */
import { defineSecret } from "firebase-functions/params";
import type { ServerZone } from "./amplitudeTransport.js";

type SecretParam = ReturnType<typeof defineSecret>;

const AMPLITUDE_API_KEY: SecretParam = defineSecret("AMPLITUDE_API_KEY");

/** Spread into a handler's `secrets:` option so `.value()` resolves at runtime. */
export const ANALYTICS_SECRETS: SecretParam[] = [AMPLITUDE_API_KEY];

/** Resolve the Amplitude key at request time. Empty string ⇒ analytics stays dark. */
export function amplitudeApiKey(): string {
  let fromSecret = "";
  try {
    fromSecret = AMPLITUDE_API_KEY.value().trim();
  } catch {
    // `.value()` throws if accessed outside a secret-bound handler; fall back.
    fromSecret = "";
  }
  return fromSecret || (process.env.AMPLITUDE_API_KEY ?? "").trim();
}

export function amplitudeServerZone(): ServerZone {
  return (process.env.AMPLITUDE_SERVER_ZONE ?? "").trim().toUpperCase() === "EU" ? "EU" : "US";
}

/** Marketing/build version stamped onto every event as `app_version`. */
export function backendAppVersion(): string {
  return (process.env.FUNCTION_VERSION ?? "").trim() || "backend";
}
