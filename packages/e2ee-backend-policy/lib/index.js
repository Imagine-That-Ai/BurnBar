export const PRODUCT_MODES = Object.freeze({
  MIT_UPSTREAM: "mit-upstream",
  BURNBAR: "burnbar",
});

export const CRYPTO_BACKENDS = Object.freeze({
  MIT_GATEWAY_V5: "mit-gateway-v5",
  BURNBAR_SIGNAL: "burnbar-signal",
});

export const REQUIRED_BACKENDS = Object.freeze({
  AUTO: "auto",
  MIT_GATEWAY_V5: CRYPTO_BACKENDS.MIT_GATEWAY_V5,
  BURNBAR_SIGNAL: CRYPTO_BACKENDS.BURNBAR_SIGNAL,
});

export class CryptoBackendSelectionError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "CryptoBackendSelectionError";
    this.code = code;
    this.details = details;
  }
}

export function normalizeRegisteredBackends(registeredBackends = []) {
  if (registeredBackends instanceof Set) {
    return new Set(registeredBackends);
  }
  if (Array.isArray(registeredBackends)) {
    return new Set(registeredBackends);
  }
  if (registeredBackends && typeof registeredBackends === "object") {
    return new Set(
      Object.entries(registeredBackends)
        .filter(([, enabled]) => enabled === true)
        .map(([backend]) => backend),
    );
  }
  throw new CryptoBackendSelectionError(
    "invalid-registered-backends",
    "registeredBackends must be an array, set, or object map",
  );
}

export function isBurnBarSignalAllowed(productMode) {
  return productMode === PRODUCT_MODES.BURNBAR;
}

export function resolveCryptoBackend(options = {}) {
  const {
    productMode = PRODUCT_MODES.MIT_UPSTREAM,
    registeredBackends = [CRYPTO_BACKENDS.MIT_GATEWAY_V5],
    requiredBackend = REQUIRED_BACKENDS.AUTO,
    allowClassicalFallback = false,
  } = options;
  const registered = normalizeRegisteredBackends(registeredBackends);

  assertKnownProductMode(productMode);
  assertKnownRequiredBackend(requiredBackend);

  if (requiredBackend === CRYPTO_BACKENDS.BURNBAR_SIGNAL) {
    requireBurnBarMode(productMode, requiredBackend);
    requireRegistered(
      registered,
      CRYPTO_BACKENDS.BURNBAR_SIGNAL,
      requiredBackend,
    );
    return selection(CRYPTO_BACKENDS.BURNBAR_SIGNAL, productMode, "required");
  }

  if (requiredBackend === CRYPTO_BACKENDS.MIT_GATEWAY_V5) {
    requireRegistered(
      registered,
      CRYPTO_BACKENDS.MIT_GATEWAY_V5,
      requiredBackend,
    );
    return selection(CRYPTO_BACKENDS.MIT_GATEWAY_V5, productMode, "required");
  }

  if (productMode === PRODUCT_MODES.MIT_UPSTREAM) {
    requireRegistered(
      registered,
      CRYPTO_BACKENDS.MIT_GATEWAY_V5,
      requiredBackend,
    );
    return selection(CRYPTO_BACKENDS.MIT_GATEWAY_V5, productMode, "auto");
  }

  if (registered.has(CRYPTO_BACKENDS.BURNBAR_SIGNAL)) {
    return selection(CRYPTO_BACKENDS.BURNBAR_SIGNAL, productMode, "auto");
  }

  if (allowClassicalFallback === true) {
    requireRegistered(
      registered,
      CRYPTO_BACKENDS.MIT_GATEWAY_V5,
      requiredBackend,
    );
    return selection(
      CRYPTO_BACKENDS.MIT_GATEWAY_V5,
      productMode,
      "explicit-fallback",
      true,
    );
  }

  throw new CryptoBackendSelectionError(
    "burnbar-signal-unavailable",
    "BurnBar mode requires the BurnBar Signal backend unless a classical fallback is explicitly allowed",
    {
      productMode,
      requiredBackend,
      registeredBackends: [...registered],
    },
  );
}

function assertKnownProductMode(productMode) {
  if (!Object.values(PRODUCT_MODES).includes(productMode)) {
    throw new CryptoBackendSelectionError(
      "unknown-product-mode",
      `unknown product mode: ${productMode}`,
      {
        productMode,
      },
    );
  }
}

function assertKnownRequiredBackend(requiredBackend) {
  if (!Object.values(REQUIRED_BACKENDS).includes(requiredBackend)) {
    throw new CryptoBackendSelectionError(
      "unknown-required-backend",
      `unknown required backend: ${requiredBackend}`,
      {
        requiredBackend,
      },
    );
  }
}

function requireBurnBarMode(productMode, requiredBackend) {
  if (!isBurnBarSignalAllowed(productMode)) {
    throw new CryptoBackendSelectionError(
      "burnbar-signal-product-only",
      "the BurnBar Signal backend can only be selected in BurnBar product mode",
      { productMode, requiredBackend },
    );
  }
}

function requireRegistered(registered, backend, requiredBackend) {
  if (!registered.has(backend)) {
    throw new CryptoBackendSelectionError(
      "backend-unavailable",
      `required backend is unavailable: ${backend}`,
      {
        backend,
        requiredBackend,
        registeredBackends: [...registered],
      },
    );
  }
}

function selection(backend, productMode, reason, degraded = false) {
  return Object.freeze({
    backend,
    productMode,
    reason,
    degraded,
  });
}

export const PLATFORMS = Object.freeze({
  MACOS: "macos",
  ANDROID: "android",
  DAEMON: "daemon",
  BACKEND: "backend",
  IOS: "ios",
});

export const CHANNELS = Object.freeze({
  DEVICE_TO_DEVICE: "device_to_device",
  AT_REST: "at_rest",
  AI_GATEWAY: "ai_gateway",
});

export const CRYPTO_MODELS = Object.freeze({
  LIBSIGNAL_DOUBLE_RATCHET: "libsignal-double-ratchet",
  LIBSIGNAL_HPKE_SEAL: "libsignal-hpke-seal",
  CRYPTOKIT_HPKE_ATREST: "cryptokit-hpke-atrest",
  HOMEGROWN_DOUBLE_RATCHET: "homegrown-double-ratchet",
  NONE_SATELLITE: "none-satellite",
});

export const LIBSIGNAL_BEARING_MODELS = Object.freeze([
  CRYPTO_MODELS.LIBSIGNAL_DOUBLE_RATCHET,
  CRYPTO_MODELS.LIBSIGNAL_HPKE_SEAL,
]);

function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    for (const key of Object.keys(value)) {
      deepFreeze(value[key]);
    }
    Object.freeze(value);
  }
  return value;
}

export const PLATFORM_CRYPTO_CAPABILITIES = deepFreeze({
  [PLATFORMS.MACOS]: {
    [CHANNELS.DEVICE_TO_DEVICE]: CRYPTO_MODELS.LIBSIGNAL_DOUBLE_RATCHET,
    [CHANNELS.AT_REST]: CRYPTO_MODELS.LIBSIGNAL_HPKE_SEAL,
    [CHANNELS.AI_GATEWAY]: CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET,
  },
  [PLATFORMS.ANDROID]: {
    [CHANNELS.DEVICE_TO_DEVICE]: CRYPTO_MODELS.LIBSIGNAL_DOUBLE_RATCHET,
    [CHANNELS.AT_REST]: CRYPTO_MODELS.LIBSIGNAL_HPKE_SEAL,
    [CHANNELS.AI_GATEWAY]: CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET,
  },
  [PLATFORMS.DAEMON]: {
    [CHANNELS.DEVICE_TO_DEVICE]: CRYPTO_MODELS.LIBSIGNAL_DOUBLE_RATCHET,
    [CHANNELS.AT_REST]: CRYPTO_MODELS.LIBSIGNAL_HPKE_SEAL,
    [CHANNELS.AI_GATEWAY]: CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET,
  },
  [PLATFORMS.BACKEND]: {
    [CHANNELS.AT_REST]: CRYPTO_MODELS.LIBSIGNAL_HPKE_SEAL,
    [CHANNELS.AI_GATEWAY]: CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET,
  },
  [PLATFORMS.IOS]: {
    [CHANNELS.DEVICE_TO_DEVICE]: CRYPTO_MODELS.NONE_SATELLITE,
    [CHANNELS.AT_REST]: CRYPTO_MODELS.CRYPTOKIT_HPKE_ATREST,
    [CHANNELS.AI_GATEWAY]: CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET,
  },
});

export function isLibsignalBearing(model) {
  return LIBSIGNAL_BEARING_MODELS.includes(model);
}

export function resolvePlatformCryptoModel(platform, channel) {
  const platformCapabilities = PLATFORM_CRYPTO_CAPABILITIES[platform];
  if (platformCapabilities === undefined) {
    throw new CryptoBackendSelectionError(
      "unknown-platform",
      `unknown platform: ${platform}`,
      { platform, channel },
    );
  }

  if (!Object.values(CHANNELS).includes(channel)) {
    throw new CryptoBackendSelectionError(
      "unknown-channel",
      `unknown channel: ${channel}`,
      { platform, channel },
    );
  }

  const model = platformCapabilities[channel];
  if (model === undefined) {
    throw new CryptoBackendSelectionError(
      "unsupported-channel-for-platform",
      `platform ${platform} does not support channel: ${channel}`,
      { platform, channel },
    );
  }

  return model;
}
