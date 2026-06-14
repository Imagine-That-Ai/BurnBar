/**
 * remediation(B3): Runtime rollout gate for the official-libsignal `signalEnvelope`
 * (relay key version 4). This is the second of the two PLANNED kill levers the
 * Signal rollback drill rehearses (scripts/ops/signal-rollback-drill.sh):
 *
 *   1. SIGNAL_ENVELOPE_V4_DISABLED (env) — the synchronous, always-available HARD
 *      kill, wired directly in hermesGateway.ts so it needs no RC fetch.
 *   2. signal_envelope_v4_enabled (Remote Config) — the soft ENABLE flag wired
 *      here, used by the activation/advertisement path to decide whether v4 is
 *      offered as a NEW production version.
 *
 * Precedence (fail-closed at every step):
 *   ENV-disable  -> v4 NEVER advertised (hard kill wins over RC + required-mode)
 *   else RC flag === "true" (parsed from the RC template) AND v4 already SUPPORTED
 *                -> v4 enabled
 *   else (missing param / RC read error / value !== "true")
 *                -> v4 DISABLED (default-closed)
 *
 * A lever may only narrow what production emits; it can NEVER add a version that is
 * not already in HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS, so the read-side
 * decode tolerance (which rejects forged/future versions) is never loosened.
 */

import { getRemoteConfig } from "firebase-admin/remote-config";
import { remoteConfigStringValue } from "./remoteConfigGuards.js";
import {
  HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL,
  HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS,
  gatewaySignalEnvelopeV4Disabled,
  productionGatewaySignalEnvelopeVersions,
} from "./hermesGateway.js";

// The Remote Config parameter that gates whether v4 may be advertised/enabled as a
// NEW production version. Mirrors the computer_use_kill_switch naming convention.
export const SIGNAL_ENVELOPE_V4_ENABLED_PARAM = "signal_envelope_v4_enabled";

/**
 * Read the `signal_envelope_v4_enabled` Remote Config flag, FAIL-CLOSED.
 *
 * Uses the exact getRemoteConfig().getTemplate() + remoteConfigStringValue pattern
 * the rest of the functions package uses (computerUseRemoteConfig.ts,
 * computerUseBudget.ts). Returns true ONLY when the param is present and its
 * default value is the literal string "true". Any other value, a missing param, or
 * an RC fetch error is treated as DISABLED.
 */
export async function isSignalEnvelopeV4RemoteConfigEnabled(): Promise<boolean> {
  try {
    const template = await getRemoteConfig().getTemplate();
    const params = template.parameters ?? {};
    const value = remoteConfigStringValue(params[SIGNAL_ENVELOPE_V4_ENABLED_PARAM]?.defaultValue);
    return value === "true";
  } catch {
    // RC unreadable (cold start, offline, permission error) => fail closed.
    return false;
  }
}

/**
 * Resolve the active set of production signal-envelope versions, applying BOTH
 * levers with the documented precedence. This is the async resolver the
 * activation/advertisement path uses when it can afford an RC round-trip; the
 * synchronous productionGatewaySignalEnvelopeVersions() (already env-gated) remains
 * the authoritative gate for the per-request write/capability hot paths.
 *
 * - ENV-disable wins: returns an empty set regardless of RC / required-mode.
 * - Otherwise v4 is included ONLY when the RC flag is enabled AND v4 is already in
 *   the env-resolved production set (so we can never ADD an unsupported version —
 *   the RC flag can only KEEP an already-eligible v4, never widen the set).
 */
export async function resolveActiveSignalEnvelopeVersions(): Promise<Set<number>> {
  // ENV hard kill short-circuits before any RC read — the kill must hold even when
  // Remote Config is unreachable.
  if (gatewaySignalEnvelopeV4Disabled()) {
    return new Set<number>();
  }

  // The sync, env-resolved baseline (Signal-required mode or the compile-time
  // PRODUCTION set). The RC flag can only intersect this — never extend it.
  const envResolved = productionGatewaySignalEnvelopeVersions();

  const rcEnabled = await isSignalEnvelopeV4RemoteConfigEnabled();
  if (!rcEnabled) {
    // RC flag off/absent/errored => drop v4 from the advertised set (fail-closed),
    // leaving any non-Signal versions the baseline already permitted untouched.
    const withoutV4 = new Set(envResolved);
    withoutV4.delete(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
    return withoutV4;
  }

  // RC flag on: keep v4 ONLY if the env baseline already eligibility-gated it AND
  // it is a read-SUPPORTED version. This guarantees a lever never injects a version
  // that the read path would reject as forged/future.
  if (
    envResolved.has(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL) &&
    HERMES_GATEWAY_SUPPORTED_SIGNAL_ENVELOPE_VERSIONS.has(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL)
  ) {
    return new Set(envResolved);
  }
  // RC says "true" but the env baseline does not yet eligibility-gate v4 (production
  // set still empty and not in required-mode): stay closed — RC alone cannot turn on
  // v4 without the production set / required-mode also electing it.
  const withoutV4 = new Set(envResolved);
  withoutV4.delete(HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
  return withoutV4;
}
