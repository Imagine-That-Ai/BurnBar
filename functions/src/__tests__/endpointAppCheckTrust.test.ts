import type { CallableRequest } from "firebase-functions/v2/https";
import { describe, expect, it, vi } from "vitest";

const { config } = vi.hoisted(() => ({
  config: {
    enforceAppCheck: true,
    linuxAppCheckAppID: "1:123456:web:linux-app",
    windowsAppCheckAppID: "1:123456:web:windows-app",
    allowedAppCheckAppIDs: ["1:123456:web:linux-app", "1:123456:web:windows-app", "1:123456:web:retired-desktop-app"],
    standardWebAppCheckAppIDs: ["1:123456:web:browser"],
  },
}));

vi.mock("../config.js", () => ({ getConfig: () => config }));

import { endpointAuthorizationCatalog } from "../security/endpointAuthorizationCatalog.generated.js";
import { enforceEndpointAppCheckTrust } from "../security/endpointAppCheckTrust.js";
import { wrapCallableHandler } from "../logging.js";
import { enforceAuthAndAppCheck } from "../auth.js";

function requestFor(appId?: string): CallableRequest {
  return {
    ...(appId ? { app: { appId } } : {}),
    auth: { uid: "user-a", token: {} },
    data: {},
    rawRequest: { headers: {} },
    acceptsStreaming: false,
  } as unknown as CallableRequest;
}

const requiredCallables = endpointAuthorizationCatalog.filter((entry) => entry.appCheck === "required");

describe("endpoint App Check trust policy", () => {
  it("accepts recognized Apple, Android, and Web identities on every required callable", () => {
    for (const entry of requiredCallables) {
      expect(() => enforceEndpointAppCheckTrust(entry.exportedName, requestFor("1:123456:ios:apple"))).not.toThrow();
      expect(() =>
        enforceEndpointAppCheckTrust(entry.exportedName, requestFor("1:123456:android:android")),
      ).not.toThrow();
      expect(() => enforceEndpointAppCheckTrust(entry.exportedName, requestFor("1:123456:web:browser"))).not.toThrow();
    }
  });

  it("allows Linux only on the 29 low-risk and 16 prerequisite or step-up callables", () => {
    const allowed = requiredCallables.filter((entry) => entry.lowerTrustDesktopPolicy !== "deny");
    const denied = requiredCallables.filter((entry) => entry.lowerTrustDesktopPolicy === "deny");
    expect(allowed).toHaveLength(45);
    expect(denied).toHaveLength(73);

    for (const entry of allowed) {
      expect(() =>
        enforceEndpointAppCheckTrust(entry.exportedName, requestFor(config.linuxAppCheckAppID)),
      ).not.toThrow();
    }
    for (const entry of denied) {
      expect(() => enforceEndpointAppCheckTrust(entry.exportedName, requestFor(config.linuxAppCheckAppID))).toThrow(
        /not authorized/u,
      );
    }
  });

  it("does not let Windows inherit the Linux low-risk allowlist", () => {
    for (const entry of requiredCallables) {
      const desktopShared = entry.lowerTrustDesktopPolicy.startsWith("desktop-");
      const assertion = expect(() =>
        enforceEndpointAppCheckTrust(entry.exportedName, requestFor(config.windowsAppCheckAppID)),
      );
      if (desktopShared) assertion.not.toThrow();
      else assertion.toThrow(/not authorized/u);
    }
  });

  it("rejects missing and unknown App Check identities for every required callable", () => {
    for (const entry of requiredCallables) {
      expect(() => enforceEndpointAppCheckTrust(entry.exportedName, requestFor())).toThrow(/required/u);
      expect(() => enforceEndpointAppCheckTrust(entry.exportedName, requestFor("unclassified-app-id"))).toThrow(
        /not authorized/u,
      );
      expect(() => enforceEndpointAppCheckTrust(entry.exportedName, requestFor("1:123456:web:not-registered"))).toThrow(
        /not authorized/u,
      );
    }
  });

  it("treats allowlisted retired desktop IDs as revoked instead of standard Web", () => {
    const retired = "1:123456:web:retired-desktop-app";
    for (const name of [
      "searchStreams",
      "bindAppCheckAttestation",
      "issueHighRiskActionNonce",
      "connectProviderAccount",
    ]) {
      expect(() => enforceEndpointAppCheckTrust(name, requestFor(retired))).toThrow(/retired_desktop/u);
    }
  });

  it("invalidates cached Linux tokens immediately when the mint allowlist is removed", () => {
    const original = [...config.allowedAppCheckAppIDs];
    config.allowedAppCheckAppIDs = original.filter((appId) => appId !== config.linuxAppCheckAppID);
    try {
      for (const name of [
        "searchStreams",
        "bindAppCheckAttestation",
        "issueHighRiskActionNonce",
        "connectProviderAccount",
      ]) {
        expect(() => enforceEndpointAppCheckTrust(name, requestFor(config.linuxAppCheckAppID))).toThrow(
          /retired_desktop/u,
        );
      }
    } finally {
      config.allowedAppCheckAppIDs = original;
    }
  });

  it("never promotes a rotated Linux Web app ID to standard Web trust", () => {
    const oldLinuxID = config.linuxAppCheckAppID;
    const oldAllowed = [...config.allowedAppCheckAppIDs];
    config.linuxAppCheckAppID = "1:123456:web:new-linux-app";
    config.allowedAppCheckAppIDs = [config.linuxAppCheckAppID, config.windowsAppCheckAppID, oldLinuxID];
    try {
      expect(() => enforceEndpointAppCheckTrust("refreshProviderQuota", requestFor(oldLinuxID))).toThrow(
        /retired_desktop/u,
      );
    } finally {
      config.linuxAppCheckAppID = oldLinuxID;
      config.allowedAppCheckAppIDs = oldAllowed;
    }
  });

  it("fails closed for an unregistered callable name", () => {
    expect(() => enforceEndpointAppCheckTrust("missingCallable", requestFor("1:123456:web:browser"))).toThrow(
      /no endpoint authorization policy/u,
    );
  });

  it("preserves emulator behavior when App Check enforcement is disabled", () => {
    config.enforceAppCheck = false;
    try {
      expect(() => enforceEndpointAppCheckTrust("missingCallable", requestFor())).not.toThrow();
    } finally {
      config.enforceAppCheck = true;
    }
  });

  it("enforces the catalog in the shared callable wrapper before handler execution", async () => {
    const deniedHandler = vi.fn(async () => ({ ok: true }));
    const denied = wrapCallableHandler("refreshProviderQuota", deniedHandler);
    await expect(denied(requestFor(config.linuxAppCheckAppID))).rejects.toThrow(/not authorized/u);
    expect(deniedHandler).not.toHaveBeenCalled();

    const allowedHandler = vi.fn(async (request: CallableRequest) => {
      enforceAuthAndAppCheck(request, "user-a");
      return { ok: true };
    });
    const allowed = wrapCallableHandler("searchStreams", allowedHandler);
    await expect(allowed(requestFor(config.linuxAppCheckAppID))).resolves.toEqual({ ok: true });
    expect(allowedHandler).toHaveBeenCalledOnce();
  });
});
