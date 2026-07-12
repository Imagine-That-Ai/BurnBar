import { describe, expect, it } from "vitest";
import type { ErrorEvent } from "@sentry/core";

import {
  beforeSend,
  sanitizeSentryEvent,
  sanitizeBreadcrumb,
  __testing,
} from "../lib/sentry/scrub";

const { redactSensitiveText, redactURLSecrets } = __testing;

function errorEvent(event: Partial<ErrorEvent>): ErrorEvent {
  return { type: undefined, ...event } as ErrorEvent;
}

/**
 * The console is a private member surface. These tests pin the invariant that
 * a Sentry crash report can never carry credentials, emails, local paths, or
 * request bodies out of the member's browser — mirroring the server-side
 * discipline proven in functions/src/sentry.ts.
 */
describe("sentry scrub — value redaction", () => {
  it("redacts bearer tokens and secret-shaped values in free text", () => {
    // Assembled at runtime so no literal token string exists in source (defeats
    // secret-scanning push protection on fake fixtures) while still exercising
    // the real redaction regexes on a realistically-shaped value.
    const openaiish = "sk-" + "abcdef1234567890ABCDEF";
    const out = redactSensitiveText(
      `Authorization: Bearer ${openaiish} and api_key=supersecretvalue`,
    );
    expect(out).not.toContain(openaiish);
    expect(out).not.toContain("supersecretvalue");
    expect(out).toContain("[REDACTED]");
  });

  it("redacts provider token formats (gh_, AIza, xox)", () => {
    // Runtime-assembled (see note above): keeps realistic shapes out of source literals.
    const github = "ghp_" + "0123456789abcdefghijABCDEFGHIJ0123";
    const google = "AIza" + "SyABCDEFGHIJKLMNOPQRSTUVWXYZ012345";
    const slack = "xoxb-" + "1234567890-abcdefghijklmnop";
    expect(redactSensitiveText(github)).toContain("[REDACTED]");
    expect(redactSensitiveText(google)).toContain("[REDACTED]");
    expect(redactSensitiveText(slack)).toContain("[REDACTED]");
  });

  it("redacts emails and local filesystem paths", () => {
    const out = redactSensitiveText("member alberto@example.com at /Users/alberto/secret/file.txt");
    expect(out).not.toContain("alberto@example.com");
    expect(out).toContain("[REDACTED-EMAIL]");
    expect(out).not.toContain("/Users/alberto/secret");
    expect(out).toContain("[REDACTED-PATH]");
  });

  it("redacts Windows user paths (browser stack frames)", () => {
    const out = redactSensitiveText("at C:\\Users\\alberto\\AppData\\thing.js");
    expect(out).toContain("[REDACTED-PATH]");
    expect(out).not.toContain("alberto\\AppData");
  });

  it("redacts sensitive query params but keeps benign ones", () => {
    const out = redactURLSecrets("https://app.burnbar.ai/x?token=abc123&page=2&access_token=zzz");
    expect(out).toContain("token=[REDACTED]");
    expect(out).toContain("access_token=[REDACTED]");
    expect(out).toContain("page=2");
    expect(out).not.toContain("abc123");
    expect(out).not.toContain("zzz");
  });

  it("redacts URL userinfo and fragment tokens", () => {
    const out = redactURLSecrets(
      "https://member:secret@app.burnbar.ai/#access_token=frag&page=2",
    );
    expect(out).toContain("https://[REDACTED]@app.burnbar.ai/");
    expect(out).toContain("access_token=[REDACTED]");
    expect(out).toContain("page=2");
    expect(out).not.toContain("member:secret");
    expect(out).not.toContain("frag");
  });
});

describe("sentry scrub — event sanitization", () => {
  it("strips request body/cookies/env and redacts URL secrets", () => {
    const event = errorEvent({
      request: {
        url: "https://app.burnbar.ai/api?token=leakme",
        data: { password: "hunter2" },
        cookies: { session: "abc" },
        env: { SECRET: "x" },
        query_string: "token=leakme",
        headers: { authorization: "Bearer leaked", "x-trace": "ok" },
      },
    });

    const out = sanitizeSentryEvent(event);
    expect(out.request?.data).toBeUndefined();
    expect(out.request?.cookies).toBeUndefined();
    expect(out.request?.env).toBeUndefined();
    expect(out.request?.query_string).toBeUndefined();
    expect(out.request?.url).toContain("token=[REDACTED]");
    // Sensitive header key is redacted wholesale; benign header survives.
    expect(out.request?.headers?.authorization).toBe("[REDACTED]");
    expect(out.request?.headers?.["x-trace"]).toBe("ok");
  });

  it("redacts secret-shaped keys and body-shaped keys in extra", () => {
    const event = errorEvent({
      extra: {
        accessToken: "abc",
        nested: { api_key: "def", note: "fine" },
        payload: { anything: "here" },
      },
    });

    const out = sanitizeSentryEvent(event);
    const extra = out.extra as Record<string, unknown>;
    expect(extra.accessToken).toBe("[REDACTED]");
    expect(extra.payload).toBe("[REDACTED]");
    expect((extra.nested as Record<string, unknown>).api_key).toBe("[REDACTED]");
    expect((extra.nested as Record<string, unknown>).note).toBe("fine");
  });

  it("scrubs breadcrumb urls, data, and messages", () => {
    const out = sanitizeBreadcrumb({
      message: "sent api_key=leaked to server",
      data: { url: "https://x.test/y?secret=zzz", token: "raw" },
    });
    expect(out.message).toContain("[REDACTED]");
    expect(out.message).not.toContain("leaked");
    expect((out.data as Record<string, unknown>).url).toContain("secret=[REDACTED]");
    expect((out.data as Record<string, unknown>).token).toBe("[REDACTED]");
  });

  it("redacts top-level event and exception text", () => {
    const event = errorEvent({
      message: "member alberto@example.com opened /Users/alberto/private with api_key=raw",
      exception: {
        values: [
          {
            type: "Error",
            value: "failed for https://member:secret@app.burnbar.ai/#access_token=frag",
          },
        ],
      },
    });

    const out = sanitizeSentryEvent(event);
    expect(out.message).toContain("[REDACTED-EMAIL]");
    expect(out.message).toContain("[REDACTED-PATH]");
    expect(out.message).toContain("api_key=[REDACTED]");
    expect(out.exception?.values?.[0]?.value).toContain("https://[REDACTED]@");
    expect(out.exception?.values?.[0]?.value).toContain("access_token=[REDACTED]");
  });
});

describe("sentry scrub — beforeSend noise filtering", () => {
  it("drops ResizeObserver loop noise", () => {
    const event = errorEvent({
      message: "ResizeObserver loop completed with undelivered notifications.",
    });
    expect(beforeSend(event)).toBeNull();
  });

  it("drops rate-limit / RESOURCE_EXHAUSTED noise", () => {
    expect(beforeSend(errorEvent({ message: "hit rate limit" }))).toBeNull();
    expect(beforeSend(errorEvent({ message: "RESOURCE_EXHAUSTED" }))).toBeNull();
  });

  it("passes real errors through, sanitized", () => {
    const event = errorEvent({
      message: "TypeError: cannot read x",
      extra: { secret: "keepout" },
    });
    const out = beforeSend(event);
    expect(out).not.toBeNull();
    expect((out!.extra as Record<string, unknown>).secret).toBe("[REDACTED]");
  });
});
