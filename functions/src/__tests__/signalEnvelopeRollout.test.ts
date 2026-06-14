/**
 * remediation(B3): proves the two signal-envelope-v4 kill levers actually gate v4
 * activation at runtime, fail-closed, with the documented precedence:
 *   ENV-disable (SIGNAL_ENVELOPE_V4_DISABLED) wins over everything; then the
 *   Remote Config flag (signal_envelope_v4_enabled) can keep an already-eligible
 *   v4; missing/false/errored RC => v4 disabled (default-closed). A lever can
 *   never ADD a version the read path would reject.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Mock Remote Config so the test stays hermetic and never touches a live RC API.
const { getTemplateMock } = vi.hoisted(() => ({ getTemplateMock: vi.fn() }));
vi.mock("firebase-admin/remote-config", () => ({
  getRemoteConfig: () => ({ getTemplate: getTemplateMock }),
}));

import {
  HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL,
  HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV,
  HERMES_GATEWAY_SIGNAL_REQUIRED_ENV,
  gatewaySignalEnvelopeV4Disabled,
  productionGatewaySignalEnvelopeVersions,
} from "../hermesGateway.js";
import {
  SIGNAL_ENVELOPE_V4_ENABLED_PARAM,
  isSignalEnvelopeV4RemoteConfigEnabled,
  resolveActiveSignalEnvelopeVersions,
} from "../signalEnvelopeRollout.js";

const V4 = HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL;

function rcTemplate(enabledValue: string | undefined) {
  if (enabledValue === undefined) return { parameters: {} };
  return { parameters: { [SIGNAL_ENVELOPE_V4_ENABLED_PARAM]: { defaultValue: { value: enabledValue } } } };
}

describe("B3 — SIGNAL_ENVELOPE_V4_DISABLED env hard kill", () => {
  const savedDisabled = process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
  const savedRequired = process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV];

  beforeEach(() => {
    getTemplateMock.mockReset();
    delete process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
    delete process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV];
  });
  afterEach(() => {
    if (savedDisabled === undefined) delete process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
    else process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = savedDisabled;
    if (savedRequired === undefined) delete process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV];
    else process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = savedRequired;
  });

  it("parses truthy values ('1'/'true', case-insensitive) and nothing else", () => {
    for (const v of ["1", "true", "TRUE", " True "]) {
      process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = v;
      expect(gatewaySignalEnvelopeV4Disabled()).toBe(true);
    }
    for (const v of ["0", "false", "", "yes", "no", "2"]) {
      process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = v;
      expect(gatewaySignalEnvelopeV4Disabled()).toBe(false);
    }
    delete process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
    expect(gatewaySignalEnvelopeV4Disabled()).toBe(false);
  });

  it("forces the production set to EXCLUDE v4 even in Signal-required mode", () => {
    // Required mode alone would advertise v4...
    process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = "true";
    expect(productionGatewaySignalEnvelopeVersions().has(V4)).toBe(true);
    // ...but the env hard kill overrides it.
    process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = "1";
    expect(productionGatewaySignalEnvelopeVersions().has(V4)).toBe(false);
    expect([...productionGatewaySignalEnvelopeVersions()]).toEqual([]);
  });

  it("forces the resolved set to EXCLUDE v4 even when RC would enable it (env wins)", async () => {
    process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = "true";
    process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = "true";
    getTemplateMock.mockResolvedValue(rcTemplate("true"));

    const active = await resolveActiveSignalEnvelopeVersions();
    expect(active.has(V4)).toBe(false);
    // ENV-disable short-circuits before any RC read.
    expect(getTemplateMock).not.toHaveBeenCalled();
  });
});

describe("B3 — signal_envelope_v4_enabled Remote Config flag (fail-closed)", () => {
  const savedDisabled = process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
  const savedRequired = process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV];

  beforeEach(() => {
    getTemplateMock.mockReset();
    delete process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
    delete process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV];
  });
  afterEach(() => {
    if (savedDisabled === undefined) delete process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV];
    else process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = savedDisabled;
    if (savedRequired === undefined) delete process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV];
    else process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = savedRequired;
  });

  it("isSignalEnvelopeV4RemoteConfigEnabled: true ONLY for literal 'true'", async () => {
    getTemplateMock.mockResolvedValue(rcTemplate("true"));
    expect(await isSignalEnvelopeV4RemoteConfigEnabled()).toBe(true);

    for (const v of ["false", "1", "TRUE", "yes", ""]) {
      getTemplateMock.mockResolvedValue(rcTemplate(v));
      expect(await isSignalEnvelopeV4RemoteConfigEnabled()).toBe(false);
    }
  });

  it("missing param => disabled (fail-closed)", async () => {
    getTemplateMock.mockResolvedValue(rcTemplate(undefined));
    expect(await isSignalEnvelopeV4RemoteConfigEnabled()).toBe(false);
  });

  it("RC fetch error => disabled (fail-closed)", async () => {
    getTemplateMock.mockRejectedValue(new Error("PERMISSION_DENIED reading Remote Config template"));
    expect(await isSignalEnvelopeV4RemoteConfigEnabled()).toBe(false);
  });

  it("RC absent/false/error => resolved set excludes v4 even in Signal-required mode", async () => {
    process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = "true"; // env baseline eligibility-gates v4

    getTemplateMock.mockResolvedValue(rcTemplate(undefined));
    expect((await resolveActiveSignalEnvelopeVersions()).has(V4)).toBe(false);

    getTemplateMock.mockResolvedValue(rcTemplate("false"));
    expect((await resolveActiveSignalEnvelopeVersions()).has(V4)).toBe(false);

    getTemplateMock.mockRejectedValue(new Error("RC down"));
    expect((await resolveActiveSignalEnvelopeVersions()).has(V4)).toBe(false);
  });

  it("RC 'true' enables v4 ONLY when env-not-disabled AND v4 is env-eligible+supported", async () => {
    getTemplateMock.mockResolvedValue(rcTemplate("true"));

    // No env baseline eligibility (not required-mode, production set empty) => RC
    // alone cannot turn v4 on; stays closed.
    expect((await resolveActiveSignalEnvelopeVersions()).has(V4)).toBe(false);

    // Env baseline eligibility-gates v4 (required-mode) AND RC says true => enabled.
    process.env[HERMES_GATEWAY_SIGNAL_REQUIRED_ENV] = "true";
    expect((await resolveActiveSignalEnvelopeVersions()).has(V4)).toBe(true);

    // Env hard kill still overrides the RC enable.
    process.env[HERMES_GATEWAY_SIGNAL_ENVELOPE_V4_DISABLED_ENV] = "1";
    expect((await resolveActiveSignalEnvelopeVersions()).has(V4)).toBe(false);
  });
});
