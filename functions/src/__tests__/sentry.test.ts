import { describe, expect, it, vi } from "vitest";
import { isRecord } from "../guards.js";

function requireRecord(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new Error("expected record");
  }
  return value;
}

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
          "x-request-id": "request-123",
          "x-debug-forwarded-error": "upstream Bearer debug-header-token-1234567890",
        },
        query_string: "token=secret-token&ok=1",
      },
      extra: {
        statusCode: 500,
        requestBody: {
          accessToken: "extra-access-token",
          nested: { apiKey: "extra-api-key" },
        },
        nested: {
          credential: "nested-credential",
          url: "https://example.test/path?api_key=query-secret",
        },
      },
      contexts: {
        runtime: {
          message:
            "failed for alberto@example.test with Bearer nested-context-token-1234567890 at /Users/alberto/private/app.log",
          nested: {
            apiKey: "context-api-key",
            url: "https://example.test/context?access_token=context-query-secret",
          },
        },
        payload: {
          token: "context-payload-token",
        },
      },
      breadcrumbs: [
        {
          type: "http",
          data: {
            url: "https://example.test/path?refresh_token=breadcrumb-secret",
            authorization: "Bearer breadcrumb-secret",
          },
        },
      ],
    };
    // @ts-expect-error reason: partial ErrorEvent fixture for sanitization test
    const event = sanitizeSentryEvent(rawEvent);

    expect(event.request?.data).toBeUndefined();
    expect(event.request?.cookies).toBeUndefined();
    expect(event.request?.query_string).toBeUndefined();
    expect(event.request?.headers?.authorization).toBe("[REDACTED]");
    expect(event.request?.headers?.cookie).toBe("[REDACTED]");
    expect(event.request?.headers?.["x-request-id"]).toBe("request-123");
    expect(event.request?.headers?.["x-debug-forwarded-error"]).toBe("upstream Bearer [REDACTED]");
    expect(event.request?.url).toBe("https://functions.example.test/call?token=[REDACTED]&ok=1");
    expect(event.extra?.requestBody).toBe("[REDACTED]");
    const nestedExtra = requireRecord(event.extra?.nested);
    expect(nestedExtra.credential).toBe("[REDACTED]");
    expect(nestedExtra.url).toBe("https://example.test/path?api_key=[REDACTED]");
    expect(event.breadcrumbs?.[0]?.data?.authorization).toBe("[REDACTED]");
    expect(event.breadcrumbs?.[0]?.data?.url).toBe("https://example.test/path?refresh_token=[REDACTED]");
    const runtimeContext = requireRecord(event.contexts?.runtime);
    const nestedRuntimeContext = requireRecord(runtimeContext.nested);
    expect(runtimeContext.message).toBe("failed for [REDACTED-EMAIL] with Bearer [REDACTED] at [REDACTED-PATH]");
    expect(nestedRuntimeContext.apiKey).toBe("[REDACTED]");
    expect(nestedRuntimeContext.url).toBe("https://example.test/context?access_token=[REDACTED]");
    expect(event.contexts?.payload).toBeUndefined();

    const serialized = JSON.stringify(event);
    expect(serialized).not.toContain("secret-token");
    expect(serialized).not.toContain("sk-live-body");
    expect(serialized).not.toContain("cookie-secret");
    expect(serialized).not.toContain("extra-access-token");
    expect(serialized).not.toContain("extra-api-key");
    expect(serialized).not.toContain("nested-credential");
    expect(serialized).not.toContain("breadcrumb-secret");
    expect(serialized).not.toContain("debug-header-token");
    expect(serialized).not.toContain("alberto@example.test");
    expect(serialized).not.toContain("/Users/alberto");
    expect(serialized).not.toContain("nested-context-token");
    expect(serialized).not.toContain("context-api-key");
    expect(serialized).not.toContain("context-query-secret");
    expect(serialized).not.toContain("context-payload-token");
  });

  it("redacts structured token strings and URL userinfo", async () => {
    vi.stubEnv("SENTRY_DSN", "");
    const { sanitizeSentryEvent } = await import("../sentry.js");
    const stripeToken = ["sk", "live", "12345678901234567890"].join("_");

    const rawEvent = {
      contexts: {
        runtime: {
          nested: {
            stripe: `Stripe token ${stripeToken}`,
            json: '{"access_token":"context-json-secret"}',
          },
        },
      },
      breadcrumbs: [
        {
          data: {
            db: "postgres://sentry_user:db-password-secret@example.test/app",
          },
        },
      ],
    };
    // @ts-expect-error reason: partial ErrorEvent fixture for sanitization test
    const event = sanitizeSentryEvent(rawEvent);
    const runtimeContext = requireRecord(event.contexts?.runtime);
    const nestedRuntimeContext = requireRecord(runtimeContext.nested);

    expect(nestedRuntimeContext.stripe).toBe("Stripe token [REDACTED]");
    expect(nestedRuntimeContext.json).toBe('{"access_token":"[REDACTED]"}');
    expect(event.breadcrumbs?.[0]?.data?.db).toBe("postgres://[REDACTED]@example.test/app");

    const serialized = JSON.stringify(event);
    expect(serialized).not.toContain(stripeToken);
    expect(serialized).not.toContain("context-json-secret");
    expect(serialized).not.toContain("sentry_user");
    expect(serialized).not.toContain("db-password-secret");
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
