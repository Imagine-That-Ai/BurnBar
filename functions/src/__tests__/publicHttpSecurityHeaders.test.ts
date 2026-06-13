import { describe, expect, it } from "vitest";

import { setPublicJsonSecurityHeaders } from "../publicHttpSecurityHeaders.js";

describe("setPublicJsonSecurityHeaders", () => {
  it("sets the security headers expected by the public JSON DAST lane", () => {
    const headers = new Map<string, string>();

    setPublicJsonSecurityHeaders({
      setHeader(name, value) {
        headers.set(name.toLowerCase(), value);
      },
    });

    expect(headers.get("cache-control")).toBe("no-store");
    expect(headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
    expect(headers.get("permissions-policy")).toContain("camera=()");
    expect(headers.get("referrer-policy")).toBe("no-referrer");
    expect(headers.get("x-content-type-options")).toBe("nosniff");
  });
});
