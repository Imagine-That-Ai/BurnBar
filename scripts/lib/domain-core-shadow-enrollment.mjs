export const DOMAIN_CORE_SHADOW_CHANNELS = new Set(["internal", "beta"]);
export const DOMAIN_CORE_SHADOW_CONSUMERS = new Set(["apple", "windows", "android", "console", "functions"]);

export function normalizeDomainCoreShadowEnrollment(channel, consumers) {
  if (!DOMAIN_CORE_SHADOW_CHANNELS.has(channel)) throw new Error("channel must be internal or beta");
  const normalized = [...new Set(consumers.map((consumer) => consumer.trim().toLowerCase()).filter(Boolean))].sort();
  if (normalized.length === 0 || normalized.some((consumer) => !DOMAIN_CORE_SHADOW_CONSUMERS.has(consumer))) {
    throw new Error("consumers must be a non-empty list of known domain-core consumers");
  }
  return { channel, consumers: normalized };
}

export function mergeDomainCoreShadowClaims(existing, enrollment) {
  return {
    ...existing,
    domainCoreShadowChannel: enrollment.channel,
    domainCoreShadowConsumers: enrollment.consumers,
  };
}

export function clearDomainCoreShadowClaims(existing) {
  const next = { ...existing };
  delete next.domainCoreShadowChannel;
  delete next.domainCoreShadowConsumers;
  return next;
}

export function enrollmentMatches(claims, enrollment) {
  return claims.domainCoreShadowChannel === enrollment.channel &&
    Array.isArray(claims.domainCoreShadowConsumers) &&
    JSON.stringify([...claims.domainCoreShadowConsumers].sort()) === JSON.stringify(enrollment.consumers);
}
