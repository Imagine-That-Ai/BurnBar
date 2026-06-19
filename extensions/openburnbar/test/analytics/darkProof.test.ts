import { describe, expect, it } from 'vitest';

import { AmplitudeTransport, type FetchLike } from '../../src/analytics/amplitudeTransport';

/**
 * THE load-bearing proof of pre-consent darkness, against the REAL transport (not
 * a fake). Mirrors the macOS guarantee "an un-consented session never builds the
 * client" and the website's "zero Amplitude bytes pre-consent".
 *
 * The transport is a direct HTTP V2 client, so its ONLY egress is a `fetch` POST
 * inside send(), reached only from track() AFTER start(). start() is called by the
 * recorder solely after the consent + key gate passes. We therefore prove darkness
 * at the strongest possible boundary — the NETWORK: not one request fires until
 * start(key) + track(), and stop() (revoke) goes silent again.
 */

function spyFetch(): { fetchImpl: FetchLike; calls: { url: string; body: string }[] } {
  const calls: { url: string; body: string }[] = [];
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push({ url, body: init.body });
    return { ok: true, status: 200 };
  };
  return { fetchImpl, calls };
}

describe('pre-consent darkness — real AmplitudeTransport makes zero network calls until started', () => {
  it('constructing the transport makes no network call', () => {
    const { fetchImpl, calls } = spyFetch();
    new AmplitudeTransport('device-uuid', 'US', fetchImpl);
    expect(calls).toHaveLength(0);
  });

  it('track() BEFORE start() is dark — no network call, not started', () => {
    const { fetchImpl, calls } = spyFetch();
    const t = new AmplitudeTransport('device-uuid', 'US', fetchImpl);
    t.track('vscode.command.invoked', 'primary_action', { command_id: 'refresh' });
    expect(t.isStarted).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it('start() with an EMPTY key stays dark (no request, not started)', () => {
    const { fetchImpl, calls } = spyFetch();
    const t = new AmplitudeTransport('device-uuid', 'US', fetchImpl);
    t.start('');
    t.track('vscode.command.invoked', 'primary_action', {});
    expect(t.isStarted).toBe(false);
    expect(calls).toHaveLength(0);
  });

  it('only start(key) + track() POSTs — to the V2 endpoint, anonymous, no user_id', () => {
    const { fetchImpl, calls } = spyFetch();
    const t = new AmplitudeTransport('device-uuid', 'US', fetchImpl);

    t.start('a-real-looking-key-abcdef0123');
    expect(t.isStarted).toBe(true);
    expect(calls).toHaveLength(0); // start() alone sends nothing

    t.track('vscode.command.invoked', 'primary_action', { command_id: 'refresh' });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('https://api2.amplitude.com/2/httpapi');

    const payload = JSON.parse(calls[0].body);
    expect(payload.api_key).toBe('a-real-looking-key-abcdef0123');
    expect(payload.events[0].device_id).toBe('device-uuid');
    expect(payload.events[0]).not.toHaveProperty('user_id');
    expect(payload.events[0].event_properties.event_category).toBe('primary_action');

    // Revoke: stop() goes dark; a subsequent track sends nothing.
    t.stop();
    expect(t.isStarted).toBe(false);
    t.track('vscode.command.invoked', 'primary_action', {});
    expect(calls).toHaveLength(1); // unchanged
  });

  it('the EU server zone targets the EU endpoint', () => {
    const { fetchImpl, calls } = spyFetch();
    const t = new AmplitudeTransport('device-uuid', 'EU', fetchImpl);
    t.start('a-real-looking-key-eu-0123');
    t.track('vscode.command.invoked', 'primary_action', {});
    expect(calls[0].url).toBe('https://api.eu.amplitude.com/2/httpapi');
  });
});
