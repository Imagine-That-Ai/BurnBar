const PRODUCT_TIERS = {
  'com.openburnbar.pro.monthly': 'cloud',
  'com.openburnbar.pro.annual': 'cloud',
  'com.openburnbar.hostedQuotaSync.cloud.monthly': 'cloud',
  'com.openburnbar.hostedQuotaSync.monthly': 'cloud',
  'com.openburnbar.proMax.v2.monthly': 'pro',
  'com.openburnbar.proMax.annual': 'pro',
  'com.openburnbar.computerUse.monthly': 'pro',
  'com.openburnbar.hostedComputerUseSync.monthly': 'pro',
  'com.openburnbar.proMax.monthly': 'pro',
  'com.openburnbar.proMax.bundle.monthly': 'pro',
  'com.openburnbar.ultra.monthly': 'ultra',
  'com.openburnbar.ultra.annual.v2': 'ultra',
  'com.openburnbar.ultra.annual': 'ultra'
};

const TRUST_STATES = new Set(['trusted', 'pending', 'revoked', 'unregistered']);
const WINDOW_KEYS = new Set(['today', '7d', '30d', '90d', 'all_time']);

function rank(tier) {
  return { none: 0, cloud: 1, pro: 2, ultra: 3 }[tier] ?? 0;
}

function mergeTier(membership, grantActive, expiry, tier) {
  if (!grantActive || tier === 'none') return;
  const apply = (key) => {
    const current = membership[key];
    if (!current.active) {
      membership[key] = { active: true, expiry };
      return;
    }
    if (expiry && (!current.expiry || expiry > current.expiry)) {
      membership[key] = { active: true, expiry };
    }
  };
  if (tier === 'cloud' || tier === 'pro' || tier === 'ultra') apply('cloud');
  if (tier === 'pro' || tier === 'ultra') apply('pro');
  if (tier === 'ultra') apply('ultra');
}

export function effectiveTier(cloud, storeKit, nowIso) {
  const now = Date.parse(nowIso);
  const membership = {
    cloud: { active: false, expiry: null },
    pro: { active: false, expiry: null },
    ultra: { active: false, expiry: null }
  };
  for (const doc of cloud) {
    const notExpired = doc.expiry ? Date.parse(doc.expiry) > now : true;
    const tier = PRODUCT_TIERS[doc.productID] ?? doc.fallbackTier ?? 'none';
    mergeTier(membership, doc.active && notExpired, doc.expiry ?? null, tier);
  }
  const cloudActive = membership.cloud.active || membership.pro.active || membership.ultra.active;
  if (!cloudActive) {
    for (const state of storeKit) {
      const notExpired = state.expiry ? Date.parse(state.expiry) > now : true;
      const tier = PRODUCT_TIERS[state.productID];
      if (!state.uidBound || state.revoked || !notExpired || !tier) continue;
      mergeTier(membership, true, state.expiry ?? null, tier);
    }
  }
  if (membership.ultra.active) return 'ultra';
  if (membership.pro.active) return 'pro';
  if (membership.cloud.active) return 'cloud';
  return 'none';
}

export function quotaStatus(used, limit) {
  if (used == null && limit == null) return { remaining: null, pressure: null, failClosed: true };
  if (limit != null && limit < 0) return { remaining: null, pressure: null, failClosed: false };
  if (used == null || limit == null || limit <= 0) return { remaining: null, pressure: null, failClosed: true };
  const remaining = Math.max(0, limit - used);
  return { remaining, pressure: used / limit, failClosed: false };
}

export function validateWindowKey(key) {
  return WINDOW_KEYS.has(key);
}

export function validateDeviceTrust(trustState, deviceId) {
  if (!deviceId || typeof deviceId !== 'string' || deviceId.trim() === '') return false;
  if (!TRUST_STATES.has(trustState) || trustState === 'revoked' || trustState === 'unregistered') return false;
  return trustState === 'trusted' || trustState === 'pending';
}

export function validateEnvelopeAad(expected, observed) {
  return typeof expected === 'string' && expected.length > 0 && observed === expected;
}

export function validateRelayChunks(sequences, declaredChunkCount) {
  const seen = new Set();
  for (const sequence of sequences) {
    if (sequence < 0) return false;
    seen.add(sequence);
  }
  if (declaredChunkCount <= 0) return seen.size === 0;
  for (const sequence of seen) {
    if (sequence >= declaredChunkCount) return false;
  }
  for (let index = 0; index < declaredChunkCount; index += 1) {
    if (!seen.has(index)) return false;
  }
  return true;
}

export function classifyError(code) {
  switch (code) {
    case 'unauthenticated':
      return 'auth';
    case 'app-check-failed':
      return 'app-check';
    case 'permission-denied':
      return 'denied';
    case 'deadline-exceeded':
      return 'expired';
    case 'unavailable':
      return 'offline';
    default:
      return 'malformed';
  }
}

export function classifyCancellation(status, legacyFallback) {
  if (status === 'cancelled') return 'cancelled';
  if (legacyFallback) return 'legacy-fallback';
  return status;
}

export function authSessionState(firebaseAvailable, signedIn) {
  if (!firebaseAvailable) return 'firebase-unavailable';
  return signedIn ? 'signed-in' : 'signed-out';
}

export function classifyAuthError(code) {
  switch (code) {
    case 'app-check-failed':
      return 'app-check';
    case 'user-disabled':
      return 'revoked-account';
    case 'id-token-expired':
      return 'expired';
    case 'account-switch':
      return 'account-switch';
    case 'permission-denied':
      return 'permission-denied';
    case 'firebase-unavailable':
      return 'firebase-unavailable';
    default:
      return classifyError(code) === 'offline' ? 'network' : classifyError(code);
  }
}

export function shouldServeCachedUid(cacheUid, activeUid, cacheGeneration, activeGeneration) {
  return Boolean(cacheUid) && cacheUid === activeUid && cacheGeneration === activeGeneration;
}

export function syncFreshness({ hasData, failed, offline, stale, partial }) {
  if (failed) return 'failed';
  if (offline) return 'offline';
  if (!hasData) return 'empty';
  if (partial) return 'partial';
  if (stale) return 'stale';
  return 'live';
}

export function shouldApplyRefresh(startedGeneration, currentGeneration, cancelled) {
  return !cancelled && startedGeneration === currentGeneration;
}

export function providerConnectivity(storageScope) {
  return storageScope === 'cloud_refreshable' || storageScope === 'server_private'
    ? 'cloud-connected'
    : 'local-only';
}

export function classifyEscrowImport({
  targetDeviceId,
  currentDeviceId,
  grantStatus,
  grantExpiresAtMs,
  nowMs,
  hasPrivateKey,
  envelopeWellFormed
}) {
  if (!envelopeWellFormed) return 'malformed-envelope';
  if (!hasPrivateKey) return 'missing-key';
  if (!targetDeviceId || !currentDeviceId || targetDeviceId !== currentDeviceId) return 'wrong-device';
  if (grantStatus === 'revoked') return 'revoked-grant';
  if (grantExpiresAtMs && grantExpiresAtMs <= nowMs) return 'expired-grant';
  return null;
}

export function storePriceDisplay(livePrice) {
  if (!livePrice || livePrice.trim() === '') return 'Price unavailable';
  return livePrice;
}

export function storeEntitlementState({
  catalogPresent,
  restoring,
  revoked,
  refunded,
  expired,
  active
}) {
  if (!catalogPresent) return 'missing-catalog';
  if (restoring) return 'restore-pending';
  if (revoked) return 'revoked';
  if (refunded) return 'refunded';
  if (expired) return 'expired';
  if (active) return 'active';
  return 'none';
}

export { rank };
