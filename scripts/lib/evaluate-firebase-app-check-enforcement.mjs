/**
 * Shared Firebase App Check enforcement probe result evaluators.
 */

export const REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS = Object.freeze([
  "firestore.googleapis.com",
  "firebasestorage.googleapis.com",
]);

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

export function evaluateFirebaseAppCheckServiceSet(
  configs,
  requiredServiceIds = REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
) {
  const safeConfigs = Array.isArray(configs) ? configs : [];
  const byServiceId = new Map(
    safeConfigs
      .filter((config) => config?.serviceId)
      .map((config) => [config.serviceId, config]),
  );
  const services = requiredServiceIds.map((serviceId) => {
    const config = byServiceId.get(serviceId);
    if (!config) {
      return {
        ok: false,
        serviceId,
        serviceName: null,
        enforcementMode: null,
        updateTime: null,
        probe: "live",
        error: "missing App Check service config probe",
      };
    }
    return {
      serviceId,
      ...evaluateFirebaseAppCheckEnforcement(config),
    };
  });
  const failed = services.filter((service) => !service.ok);
  return {
    ok: failed.length === 0,
    requiredServiceIds,
    services,
    error:
      failed.length === 0
        ? undefined
        : failed.map((service) => `${service.serviceId}: ${service.error}`).join("; "),
  };
}
