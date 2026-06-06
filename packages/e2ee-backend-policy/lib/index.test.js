import assert from "node:assert/strict";
import test from "node:test";

import {
  CHANNELS,
  CRYPTO_BACKENDS,
  CRYPTO_MODELS,
  CryptoBackendSelectionError,
  LIBSIGNAL_BEARING_MODELS,
  PLATFORM_CRYPTO_CAPABILITIES,
  PLATFORMS,
  PRODUCT_MODES,
  REQUIRED_BACKENDS,
  isBurnBarSignalAllowed,
  isLibsignalBearing,
  normalizeRegisteredBackends,
  resolveCryptoBackend,
  resolvePlatformCryptoModel,
} from "./index.js";

test("MIT upstream mode uses the gateway v5 backend without Signal packages", () => {
  const selected = resolveCryptoBackend({
    productMode: PRODUCT_MODES.MIT_UPSTREAM,
    registeredBackends: [CRYPTO_BACKENDS.MIT_GATEWAY_V5],
  });

  assert.deepEqual(selected, {
    backend: CRYPTO_BACKENDS.MIT_GATEWAY_V5,
    productMode: PRODUCT_MODES.MIT_UPSTREAM,
    reason: "auto",
    degraded: false,
  });
});

test("MIT upstream mode never selects the BurnBar Signal backend", () => {
  assert.equal(isBurnBarSignalAllowed(PRODUCT_MODES.MIT_UPSTREAM), false);

  const selected = resolveCryptoBackend({
    productMode: PRODUCT_MODES.MIT_UPSTREAM,
    registeredBackends: [
      CRYPTO_BACKENDS.MIT_GATEWAY_V5,
      CRYPTO_BACKENDS.BURNBAR_SIGNAL,
    ],
  });
  assert.equal(selected.backend, CRYPTO_BACKENDS.MIT_GATEWAY_V5);

  assert.throws(
    () =>
      resolveCryptoBackend({
        productMode: PRODUCT_MODES.MIT_UPSTREAM,
        registeredBackends: [
          CRYPTO_BACKENDS.MIT_GATEWAY_V5,
          CRYPTO_BACKENDS.BURNBAR_SIGNAL,
        ],
        requiredBackend: REQUIRED_BACKENDS.BURNBAR_SIGNAL,
      }),
    (error) =>
      error instanceof CryptoBackendSelectionError &&
      error.code === "burnbar-signal-product-only",
  );
});

test("BurnBar mode selects the BurnBar Signal backend when registered", () => {
  const selected = resolveCryptoBackend({
    productMode: PRODUCT_MODES.BURNBAR,
    registeredBackends: [
      CRYPTO_BACKENDS.MIT_GATEWAY_V5,
      CRYPTO_BACKENDS.BURNBAR_SIGNAL,
    ],
  });

  assert.deepEqual(selected, {
    backend: CRYPTO_BACKENDS.BURNBAR_SIGNAL,
    productMode: PRODUCT_MODES.BURNBAR,
    reason: "auto",
    degraded: false,
  });
});

test("Signal-required mode refuses fallback when the BurnBar Signal backend is missing", () => {
  assert.throws(
    () =>
      resolveCryptoBackend({
        productMode: PRODUCT_MODES.BURNBAR,
        registeredBackends: [CRYPTO_BACKENDS.MIT_GATEWAY_V5],
        requiredBackend: REQUIRED_BACKENDS.BURNBAR_SIGNAL,
      }),
    (error) =>
      error instanceof CryptoBackendSelectionError &&
      error.code === "backend-unavailable" &&
      error.details.backend === CRYPTO_BACKENDS.BURNBAR_SIGNAL,
  );
});

test("BurnBar auto mode fails closed without Signal unless fallback is explicit", () => {
  assert.throws(
    () =>
      resolveCryptoBackend({
        productMode: PRODUCT_MODES.BURNBAR,
        registeredBackends: [CRYPTO_BACKENDS.MIT_GATEWAY_V5],
      }),
    (error) =>
      error instanceof CryptoBackendSelectionError &&
      error.code === "burnbar-signal-unavailable",
  );

  const selected = resolveCryptoBackend({
    productMode: PRODUCT_MODES.BURNBAR,
    registeredBackends: [CRYPTO_BACKENDS.MIT_GATEWAY_V5],
    allowClassicalFallback: true,
  });

  assert.deepEqual(selected, {
    backend: CRYPTO_BACKENDS.MIT_GATEWAY_V5,
    productMode: PRODUCT_MODES.BURNBAR,
    reason: "explicit-fallback",
    degraded: true,
  });
});

test("registered backend normalization accepts arrays, sets, and boolean maps", () => {
  assert.deepEqual(
    normalizeRegisteredBackends([CRYPTO_BACKENDS.MIT_GATEWAY_V5]),
    new Set([CRYPTO_BACKENDS.MIT_GATEWAY_V5]),
  );
  assert.deepEqual(
    normalizeRegisteredBackends(new Set([CRYPTO_BACKENDS.BURNBAR_SIGNAL])),
    new Set([CRYPTO_BACKENDS.BURNBAR_SIGNAL]),
  );
  assert.deepEqual(
    normalizeRegisteredBackends({
      [CRYPTO_BACKENDS.MIT_GATEWAY_V5]: true,
      [CRYPTO_BACKENDS.BURNBAR_SIGNAL]: false,
    }),
    new Set([CRYPTO_BACKENDS.MIT_GATEWAY_V5]),
  );
});

test("LIBSIGNAL_BEARING_MODELS is exactly the two libsignal-linking models", () => {
  assert.deepEqual(LIBSIGNAL_BEARING_MODELS, [
    "libsignal-double-ratchet",
    "libsignal-hpke-seal",
  ]);
  assert.ok(Object.isFrozen(LIBSIGNAL_BEARING_MODELS));

  assert.equal(isLibsignalBearing(CRYPTO_MODELS.LIBSIGNAL_DOUBLE_RATCHET), true);
  assert.equal(isLibsignalBearing(CRYPTO_MODELS.LIBSIGNAL_HPKE_SEAL), true);
  assert.equal(isLibsignalBearing(CRYPTO_MODELS.CRYPTOKIT_HPKE_ATREST), false);
  assert.equal(
    isLibsignalBearing(CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET),
    false,
  );
  assert.equal(isLibsignalBearing(CRYPTO_MODELS.NONE_SATELLITE), false);
  assert.equal(isLibsignalBearing(undefined), false);
});

test("iOS resolves to no libsignal-bearing model on any channel (App-Store-clean)", () => {
  for (const channel of Object.values(CHANNELS)) {
    const model = resolvePlatformCryptoModel(PLATFORMS.IOS, channel);
    assert.equal(
      isLibsignalBearing(model),
      false,
      `iOS ${channel} must not be libsignal-bearing, got ${model}`,
    );
  }

  assert.equal(
    resolvePlatformCryptoModel(PLATFORMS.IOS, CHANNELS.AT_REST),
    CRYPTO_MODELS.CRYPTOKIT_HPKE_ATREST,
  );
});

test("device_to_device on macOS/Android/daemon is libsignal-double-ratchet (Signal Protocol)", () => {
  for (const platform of [
    PLATFORMS.MACOS,
    PLATFORMS.ANDROID,
    PLATFORMS.DAEMON,
  ]) {
    assert.equal(
      resolvePlatformCryptoModel(platform, CHANNELS.DEVICE_TO_DEVICE),
      CRYPTO_MODELS.LIBSIGNAL_DOUBLE_RATCHET,
    );
  }
});

test("iOS device_to_device is none-satellite", () => {
  assert.equal(
    resolvePlatformCryptoModel(PLATFORMS.IOS, CHANNELS.DEVICE_TO_DEVICE),
    CRYPTO_MODELS.NONE_SATELLITE,
  );
});

test("ai_gateway is homegrown-double-ratchet on every platform", () => {
  for (const platform of Object.values(PLATFORMS)) {
    assert.equal(
      resolvePlatformCryptoModel(platform, CHANNELS.AI_GATEWAY),
      CRYPTO_MODELS.HOMEGROWN_DOUBLE_RATCHET,
      `ai_gateway must be homegrown-double-ratchet for ${platform}`,
    );
    assert.equal(
      isLibsignalBearing(
        resolvePlatformCryptoModel(platform, CHANNELS.AI_GATEWAY),
      ),
      false,
    );
  }
});

test("resolvePlatformCryptoModel throws on backend device_to_device", () => {
  assert.throws(
    () =>
      resolvePlatformCryptoModel(
        PLATFORMS.BACKEND,
        CHANNELS.DEVICE_TO_DEVICE,
      ),
    (error) =>
      error instanceof CryptoBackendSelectionError &&
      error.code === "unsupported-channel-for-platform" &&
      error.details.platform === PLATFORMS.BACKEND &&
      error.details.channel === CHANNELS.DEVICE_TO_DEVICE,
  );
});

test("resolvePlatformCryptoModel throws on unknown platform and unknown channel", () => {
  assert.throws(
    () => resolvePlatformCryptoModel("windows", CHANNELS.AT_REST),
    (error) =>
      error instanceof CryptoBackendSelectionError &&
      error.code === "unknown-platform",
  );

  assert.throws(
    () => resolvePlatformCryptoModel(PLATFORMS.MACOS, "carrier-pigeon"),
    (error) =>
      error instanceof CryptoBackendSelectionError &&
      error.code === "unknown-channel",
  );
});

test("PLATFORM_CRYPTO_CAPABILITIES equals the canonical matrix and is deeply frozen", () => {
  assert.deepEqual(PLATFORM_CRYPTO_CAPABILITIES, {
    macos: {
      device_to_device: "libsignal-double-ratchet",
      at_rest: "libsignal-hpke-seal",
      ai_gateway: "homegrown-double-ratchet",
    },
    android: {
      device_to_device: "libsignal-double-ratchet",
      at_rest: "libsignal-hpke-seal",
      ai_gateway: "homegrown-double-ratchet",
    },
    daemon: {
      device_to_device: "libsignal-double-ratchet",
      at_rest: "libsignal-hpke-seal",
      ai_gateway: "homegrown-double-ratchet",
    },
    backend: {
      at_rest: "libsignal-hpke-seal",
      ai_gateway: "homegrown-double-ratchet",
    },
    ios: {
      device_to_device: "none-satellite",
      at_rest: "cryptokit-hpke-atrest",
      ai_gateway: "homegrown-double-ratchet",
    },
  });

  assert.ok(Object.isFrozen(PLATFORM_CRYPTO_CAPABILITIES));
  assert.ok(Object.isFrozen(PLATFORM_CRYPTO_CAPABILITIES.ios));
  assert.ok(Object.isFrozen(PLATFORMS));
  assert.ok(Object.isFrozen(CHANNELS));
  assert.ok(Object.isFrozen(CRYPTO_MODELS));
});
