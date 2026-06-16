import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";

import {
  checkCallableRateLimit,
  checkPublicHttpEndpointRateLimit,
  clientIpFromHttpRequest,
  isPublicRateLimitExceeded,
  RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS,
  type PublicHttpEndpointName,
} from "../callables/publicRateLimit.js";
import { endpointAuthorizationMatrix } from "../security/endpointAuthorizationMatrix.js";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

const mockDb = vi.hoisted(() => {
  const docs = new Map<string, { count: number; windowStartMillis: number }>();
  return {
    doc: (path: string) => ({
      path,
      get: async () => {
        const data = docs.get(path);
        return {
          exists: data !== undefined,
          data: () => data,
        };
      },
    }),
    runTransaction: async (fn: (tx: unknown) => Promise<void>) => {
      const tx = {
        get: async (ref: { path: string }) => {
          const data = docs.get(ref.path);
          return {
            exists: data !== undefined,
            data: () => data,
          };
        },
        set: (ref: { path: string }, data: unknown) => {
          docs.set(ref.path, data as { count: number; windowStartMillis: number });
        },
      };
      await fn(tx);
    },
    __resetRateLimitDocs: () => docs.clear(),
  };
});

vi.mock("../adminRuntime.js", () => ({
  db: mockDb,
  auth: {},
}));

beforeEach(() => {
  mockDb.__resetRateLimitDocs();
});

describe("isPublicRateLimitExceeded", () => {
  it("returns true for a firebase-functions resource-exhausted HttpsError", () => {
    expect(isPublicRateLimitExceeded(new HttpsError("resource-exhausted", "slow down"))).toBe(true);
  });

  it("returns false for other HttpsError codes", () => {
    expect(isPublicRateLimitExceeded(new HttpsError("internal", "boom"))).toBe(false);
  });

  it("returns false for plain errors and non-error values", () => {
    expect(isPublicRateLimitExceeded(new Error("generic"))).toBe(false);
    expect(isPublicRateLimitExceeded("resource-exhausted")).toBe(false);
    expect(isPublicRateLimitExceeded(null)).toBe(false);
  });
});

describe("clientIpFromHttpRequest", () => {
  afterEach(() => {
    delete process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR;
  });

  it("prefers platform-provided req.ip over spoofable x-forwarded-for", () => {
    const ip = clientIpFromHttpRequest({
      headers: { "x-forwarded-for": "203.0.113.10, 10.0.0.1" },
      ip: "10.0.0.1",
    });
    expect(ip).toBe("10.0.0.1");
  });

  it("falls back to socket remoteAddress before x-forwarded-for", () => {
    expect(
      clientIpFromHttpRequest({
        headers: { "x-forwarded-for": "203.0.113.10" },
        socket: { remoteAddress: "198.51.100.2" },
      }),
    ).toBe("198.51.100.2");
  });

  it("uses x-forwarded-for only when explicitly trusted", () => {
    process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR = "1";
    expect(
      clientIpFromHttpRequest({
        headers: { "x-forwarded-for": "203.0.113.10, 10.0.0.1" },
      }),
    ).toBe("203.0.113.10");
  });

  it("returns unknown when no address is present", () => {
    expect(clientIpFromHttpRequest({})).toBe("unknown");
  });
});

describe("public HTTP endpoint rate-limit inventory", () => {
  it("declares a rate limit for every public HTTP endpoint in the authorization catalog", () => {
    const publicHttpNames = endpointAuthorizationMatrix
      .filter((entry) => entry.trigger === "http" || entry.trigger === "provider-webhook")
      .map((entry) => entry.exportedName);

    const limitedSet = new Set<string>(RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS);
    const unbounded = publicHttpNames.filter((name) => !limitedSet.has(name));
    expect(unbounded, `unbounded public HTTP endpoints: ${unbounded.join(", ")}`).toEqual([]);
  });

  it("does not declare rate limits for non-public endpoints", () => {
    const publicSet = new Set(
      endpointAuthorizationMatrix
        .filter((entry) => entry.trigger === "http" || entry.trigger === "provider-webhook")
        .map((entry) => entry.exportedName),
    );
    const unexpected = RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS.filter((name) => !publicSet.has(name));
    expect(unexpected, `rate-limited endpoints not catalogued as public HTTP: ${unexpected.join(", ")}`).toEqual([]);
  });
});

describe("checkPublicHttpEndpointRateLimit", () => {
  it("allows requests under the declared limit and rejects once the limit is reached", async () => {
    const endpoint: PublicHttpEndpointName = "latestRouterRundown";
    const ip = "198.51.100.5";
    for (let i = 0; i < 60; i += 1) {
      await expect(checkPublicHttpEndpointRateLimit(endpoint, ip)).resolves.toBeUndefined();
    }
    await expect(checkPublicHttpEndpointRateLimit(endpoint, ip)).rejects.toThrow(HttpsError);
    await expect(checkPublicHttpEndpointRateLimit(endpoint, ip)).rejects.toThrow(/too many requests/i);
  });

  it("tracks different endpoints independently", async () => {
    const ip = "198.51.100.6";
    await expect(checkPublicHttpEndpointRateLimit("healthCheck" as PublicHttpEndpointName, ip)).resolves.toBeUndefined();
    await expect(checkPublicHttpEndpointRateLimit("healthLive" as PublicHttpEndpointName, ip)).resolves.toBeUndefined();
  });

  it("tracks different IPs independently", async () => {
    const endpoint: PublicHttpEndpointName = "latestRouterRundown";
    for (let i = 0; i < 60; i += 1) {
      await expect(checkPublicHttpEndpointRateLimit(endpoint, "198.51.100.7")).resolves.toBeUndefined();
    }
    await expect(checkPublicHttpEndpointRateLimit(endpoint, "198.51.100.8")).resolves.toBeUndefined();
  });
});

describe("checkCallableRateLimit", () => {
  it("allows requests under the declared limit and rejects once the limit is reached", async () => {
    const limit = { action: "test_callable_action", windowSeconds: 60, maxAttempts: 3 };
    const uid = "testuser1234567890123456789";
    for (let i = 0; i < 3; i += 1) {
      await expect(checkCallableRateLimit(uid, undefined, limit)).resolves.toBeUndefined();
    }
    await expect(checkCallableRateLimit(uid, undefined, limit)).rejects.toThrow(HttpsError);
  });

  it("uses App Check appId as part of the identity when present", async () => {
    const limit = { action: "test_callable_action_appcheck", windowSeconds: 60, maxAttempts: 1 };
    const uid = "testuser2234567890123456789";
    await expect(checkCallableRateLimit(uid, "app-check-id-1", limit)).resolves.toBeUndefined();
    await expect(checkCallableRateLimit(uid, "app-check-id-2", limit)).resolves.toBeUndefined();
  });

  it("falls back to unauthenticated identity when uid is absent", async () => {
    const limit = { action: "test_callable_action_anon", windowSeconds: 60, maxAttempts: 1 };
    await expect(checkCallableRateLimit(undefined, undefined, limit)).resolves.toBeUndefined();
    await expect(checkCallableRateLimit(undefined, undefined, limit)).rejects.toThrow(HttpsError);
  });
});
