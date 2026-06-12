import { describe, expect, it, vi } from "vitest";
import type { ErrorEvent } from "@sentry/core";

describe("sentry sanitization", () => {
  it("strips request bodies, cookies, auth headers, query strings, and nested secret extras", async () => {
    vi.stubEnv("SENTRY_DSN", "");
    const { sanitizeSentryEvent } = await import("../sentry.js");

    const rawEvent = {
      message: "callable failed",
      request: {
        url: "https://functions.example.test/call?token=secret-token&ok=1",
        data: { apiKey: "sk-live-body", harmless: "value" },
        cookies: { session: "cookie-secret" },
        headers: {
          authorization: "Bearer auth-secret",
          cookie: "session=cookie-secret",
          "x-request-id": "request-123"
        },
        query_string: "token=secret-token&ok=1"
      },
      extra: {
        statusCode: 500,
        requestBody: {
          accessToken: "extra-access-token",
          nested: { apiKey: "extra-api-key" }
        },
        nested: {
          credential: "nested-credential",
          url: "https://example.test/path?api_key=query-secret"
        }
      },
      breadcrumbs: [
        {
          type: "http",
          data: {
            url: "https://example.test/path?refresh_token=breadcrumb-secret",
            authorization: "Bearer breadcrumb-secret"
          }
        }
      ]
    } as unknown as ErrorEvent;
    const event = sanitizeSentryEvent(rawEvent);

    expect(event.request?.data).toBeUndefined();
    expect(event.request?.cookies).toBeUndefined();
    expect(event.request?.query_string).toBeUndefined();
    expect(event.request?.headers?.authorization).toBe("[REDACTED]");
    expect(event.request?.headers?.cookie).toBe("[REDACTED]");
    expect(event.request?.headers?.["x-request-id"]).toBe("request-123");
    expect(event.request?.url).toBe("https://functions.example.test/call?token=[REDACTED]&ok=1");
    expect(event.extra?.requestBody).toBe("[REDACTED]");
    expect((event.extra?.nested as Record<string, unknown>).credential).toBe("[REDACTED]");
    expect((event.extra?.nested as Record<string, unknown>).url).toBe(
      "https://example.test/path?api_key=[REDACTED]"
    );
    expect(event.breadcrumbs?.[0]?.data?.authorization).toBe("[REDACTED]");
    expect(event.breadcrumbs?.[0]?.data?.url).toBe("https://example.test/path?refresh_token=[REDACTED]");

    const serialized = JSON.stringify(event);
    expect(serialized).not.toContain("secret-token");
    expect(serialized).not.toContain("sk-live-body");
    expect(serialized).not.toContain("cookie-secret");
    expect(serialized).not.toContain("extra-access-token");
    expect(serialized).not.toContain("extra-api-key");
    expect(serialized).not.toContain("nested-credential");
    expect(serialized).not.toContain("breadcrumb-secret");
  });

  it("hashes Sentry user IDs instead of truncating Firebase UIDs", async () => {
    vi.stubEnv("SENTRY_DSN", "");
    const { sentryUserIdForUID } = await import("../sentry.js");

    const uid = "firebase-user-uid-1234567890";
    const sentryUserId = sentryUserIdForUID(uid);

    expect(sentryUserId).toMatch(/^uid:[a-f0-9]{16}$/);
    expect(sentryUserId).not.toContain(uid.slice(0, 8));
    expect(sentryUserIdForUID(uid)).toBe(sentryUserId);
  });
});
