import { describe, expect, it } from "vitest";
import type { Breadcrumb, ErrorEvent } from "@sentry/core";

describe("Sentry telemetry redaction", () => {
  it("scrubs request headers, request body, and extra error data", async () => {
    const { sanitizeSentryEventForTesting } = await import("../sentry.js");
    const event = {
      message:
        "upstream failed Authorization: Bearer eyJrequestMessageSecretValue123456 https://example.test/cb?token=query-secret",
      request: {
        method: "POST",
        url: "https://example.test/path?access_token=url-secret&safe=1",
        headers: {
          authorization: "Bearer header-secret-value",
          cookie: "sid=cookie-secret-value",
        },
        data: {
          prompt: "private user prompt",
          password: "body-password-value",
          redisURL: "redis://:redis-secret@example.local:6379/0",
          nested: [{ accessToken: "nested-token-value" }],
        },
      },
      extra: {
        errorData: {
          refreshToken: "extra-refresh-token-value",
          stack: "password=extra-password-value",
        },
      },
    } as unknown as ErrorEvent;

    const sanitized = sanitizeSentryEventForTesting(event);
    const json = JSON.stringify(sanitized);

    expect(json).not.toContain("eyJrequestMessageSecretValue123456");
    expect(json).not.toContain("query-secret");
    expect(json).not.toContain("url-secret");
    expect(json).not.toContain("header-secret-value");
    expect(json).not.toContain("cookie-secret-value");
    expect(json).not.toContain("private user prompt");
    expect(json).not.toContain("body-password-value");
    expect(json).not.toContain("redis-secret");
    expect(json).not.toContain("nested-token-value");
    expect(json).not.toContain("extra-refresh-token-value");
    expect(json).not.toContain("extra-password-value");
    expect(json).toContain("[REDACTED]");
    expect(sanitized.request).toEqual({ method: "POST" });
  });

  it("scrubs breadcrumb data and URLs", async () => {
    const { sanitizeSentryBreadcrumbForTesting } = await import("../sentry.js");
    const breadcrumb = {
      category: "fetch",
      data: {
        url: "https://example.test/path?secret=breadcrumb-secret",
        requestHeaders: {
          authorization: "Bearer breadcrumb-token-value",
        },
      },
    } satisfies Breadcrumb;

    const sanitized = sanitizeSentryBreadcrumbForTesting(breadcrumb);
    const json = JSON.stringify(sanitized);

    expect(json).not.toContain("breadcrumb-secret");
    expect(json).not.toContain("breadcrumb-token-value");
    expect(json).toContain("[REDACTED]");
  });
});
