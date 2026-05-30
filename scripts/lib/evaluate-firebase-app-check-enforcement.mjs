/**
 * Shared Firebase App Check Firestore enforcement probe result evaluator.
 */

export function evaluateFirebaseAppCheckEnforcement(config) {
  if (config?.enforcementMode === "ENFORCED") {
    return {
      ok: true,
      serviceName: config.serviceName ?? null,
      enforcementMode: config.enforcementMode,
      updateTime: config.updateTime ?? null,
      probe: config.probe ?? "live",
    };
  }
  return {
    ok: false,
    serviceName: config?.serviceName ?? null,
    enforcementMode: config?.enforcementMode ?? null,
    updateTime: config?.updateTime ?? null,
    probe: config?.probe ?? "live",
    error: `expected enforcementMode ENFORCED, got ${config?.enforcementMode ?? "null"}`,
  };
}
