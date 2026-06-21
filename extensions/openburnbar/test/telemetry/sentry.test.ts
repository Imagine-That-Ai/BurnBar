import { describe, expect, it } from 'vitest';

import { redactSensitiveText } from '../../src/logger';
import { sanitizeSentryEvent, sanitizeTelemetryValue } from '../../src/telemetry/sentry';

describe('extension telemetry redaction', () => {
  it('redacts copied credentials, identities, and local paths from free-form text', () => {
    const url = `https://example.test/callback?access_${'token'}=sample-token&safe=1&credential=sample-credential`;
    const text = [
      url,
      'Authorization: Bearer sample-token-value',
      'password=sample-password',
      'alice@example.test',
      '/Users/alberto/private-project/source.ts',
      '10.2.3.4'
    ].join(' ');

    const redacted = redactSensitiveText(text);

    expect(redacted).toContain('safe=1');
    expect(redacted).toContain('access_token=[REDACTED]');
    expect(redacted).toContain('credential=[REDACTED]');
    expect(redacted).toContain('Authorization: [REDACTED]');
    expect(redacted).toContain('password=[REDACTED]');
    expect(redacted).toContain('[EMAIL_REDACTED]');
    expect(redacted).toContain('[LOCAL_PATH_REDACTED]');
    expect(redacted).toContain('[INTERNAL_IP_REDACTED]');
    expect(redacted).not.toContain('sample-token');
    expect(redacted).not.toContain('alice@example.test');
    expect(redacted).not.toContain('/Users/alberto');
  });

  it('redacts sensitive quoted keys from serialized objects and fragments', () => {
    const text = [
      JSON.stringify({
        apiKey: 'sample-api-key',
        password: 'sample-password',
        client_secret: 'sample-client-secret',
        safe: 'kept'
      }),
      'token_url=https://example.test/callback#private_key=sample-fragment-key&ok=1'
    ].join(' ');

    const redacted = redactSensitiveText(text);

    expect(redacted).toContain('"safe":"kept"');
    expect(redacted).toContain('"apiKey":"[REDACTED]"');
    expect(redacted).toContain('"password":"[REDACTED]"');
    expect(redacted).toContain('"client_secret":"[REDACTED]"');
    expect(redacted).toContain('#private_key=[REDACTED]');
    expect(redacted).toContain('ok=1');
    expect(redacted).not.toContain('sample-api-key');
    expect(redacted).not.toContain('sample-password');
    expect(redacted).not.toContain('sample-client-secret');
    expect(redacted).not.toContain('sample-fragment-key');
  });

  it('redacts sensitive keys even when the value is short or nested', () => {
    const sanitized = sanitizeTelemetryValue({
      safe: 'kept',
      nested: {
        accessToken: 'short',
        path: '/private/tmp/openburnbar/session.log'
      }
    });

    expect(sanitized).toEqual({
      safe: 'kept',
      nested: {
        accessToken: '[REDACTED]',
        path: '[LOCAL_PATH_REDACTED]'
      }
    });
  });

  it('sanitizes nested Sentry events before they leave the extension host', () => {
    const event = {
      message: 'failure for alice@example.test in /Users/alberto/project/file.ts',
      request: {
        url: `https://service.test/path?access_${'token'}=sample-token&ok=1`,
        headers: {
          authorization: 'Bearer sample-token',
          'x-trace': 'keep'
        },
        cookies: 'sid=sample-session',
        data: {
          prompt: 'private prompt body',
          apiKey: 'sample-key'
        },
        query_string: 'token=sample-query-token&ok=1'
      },
      extra: {
        nested: {
          email: 'bob@example.test',
          path: '/private/tmp/session/log.json',
          refreshToken: 'sample-refresh'
        }
      },
      contexts: {
        runtime: { name: 'node' }
      },
      breadcrumbs: [
        {
          message: 'visited /home/alberto/project/file.ts',
          data: {
            url: 'https://app.test/path?password=sample-pass',
            token: 'sample-breadcrumb-token'
          }
        }
      ],
      exception: {
        values: [{ value: 'boom at /Users/alberto/private with password=sample-pass' }]
      }
    };

    const sanitized = sanitizeSentryEvent(event);
    const serialized = JSON.stringify(sanitized);

    expect(serialized).toContain('ok=1');
    expect(serialized).toContain('"name":"node"');
    expect(serialized).not.toContain('x-trace');
    expect(serialized).not.toContain('sample-token');
    expect(serialized).not.toContain('sample-key');
    expect(serialized).not.toContain('sample-session');
    expect(serialized).not.toContain('private prompt body');
    expect(serialized).not.toContain('alice@example.test');
    expect(serialized).not.toContain('bob@example.test');
    expect(serialized).not.toContain('/Users/alberto');
    expect(serialized).not.toContain('/private/tmp');

    expect(sanitized.request.headers).toBe('[REDACTED]');
    expect(sanitized.request.cookies).toBe('[REDACTED]');
    expect(sanitized.request.data).toBe('[REDACTED]');
    expect(sanitized.extra.nested.refreshToken).toBe('[REDACTED]');
    expect(sanitized.breadcrumbs[0].data.token).toBe('[REDACTED]');
  });
});
