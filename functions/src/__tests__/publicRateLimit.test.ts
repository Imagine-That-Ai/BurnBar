import { afterEach, describe, expect, it } from "vitest";

import { clientIpFromHttpRequest } from "../callables/publicRateLimit.js";

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
